-- The Lua half of the operator scripting runtime: the whole of what a
-- child process runs. It reads length-prefixed MessagePack frames on
-- stdin, runs operator authored chunks inside a sandbox built here, and
-- writes frames back on stdout. It never opens a file, never touches the
-- network, and has no access to anything the parent did not hand it,
-- because the environment a chunk runs in is built from an empty table
-- below and only the names the parent asks for are ever put into it.

-- Unbuffered, or the parent blocks forever waiting for a frame this process has
-- already written. Lua buffers stdout when it is a pipe rather than a tty, so
-- without this the whole protocol deadlocks on the first host call.
io.stdout:setvbuf("no")

-- MessagePack comes from lua-messagepack, installed through LuaRocks by the
-- deploy (see railpack.json, or the vendored copy under vendor/lua for a
-- buildpack build). Required here at the top level, where require still
-- exists; a script never sees it, since the sandbox env is built empty.
local ok, mp = pcall(require, "MessagePack")
if not ok then
  -- Hand encoded: a MessagePack fixmap of {t="error", m=message}, str8 for
  -- the message since it is longer than fixstr's 31 byte ceiling. #body
  -- rather than counted arithmetic, so a longer message here cannot desync
  -- its own length prefix.
  local message = "the MessagePack rock is missing: run luarocks install lua-messagepack"
  local body = "\x82\xa1t\xa5error\xa1m\xd9" .. string.char(#message) .. message
  io.stdout:write(string.pack(">I4", #body), body)
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

-- Strip a script's value down to plain data before it is packed, dropping any
-- metatable in the process. Iterated with next rather than pairs so a
-- __pairs metatable cannot steer the walk, and depth limited because a
-- script can build a cycle.
local MAX_DEPTH = 32

local function plain(value, depth)
  if type(value) ~= "table" then return value end
  if depth > MAX_DEPTH then return nil end

  local copy = {}
  for k, v in next, value do
    local kind = type(k)
    if kind == "string" or kind == "number" then
      copy[k] = plain(v, depth + 1)
    end
  end
  return copy
end

-- A copy of a value, for a getter to hand back (issue #372).
--
-- Without this a script that sorted, cleared or appended to what a getter
-- gave it would be changing the payload itself, so the next call would
-- answer something the host never sent.
--
-- Iterated with next rather than pairs, and depth limited, for the same
-- reasons plain() above gives: it can set a metatable, or build a cycle.
local function copied(value, depth)
  if type(value) ~= "table" then return value end
  if depth > MAX_DEPTH then return nil end

  local out = {}
  for k, v in next, value do out[k] = copied(v, depth + 1) end
  return out
end

local function write(frame)
  local body = mp.pack(frame)
  io.stdout:write(string.pack(">I4", #body), body)
end

-- A 4 byte big endian length, then that many bytes of MessagePack. mp.unpack
-- raises rather than returning an error value, so it is pcall'd; a short read
-- on either part means the parent's pipe closed mid frame.
local function read_frame()
  local header = io.read(4)
  if not header or #header < 4 then return nil end
  local length = string.unpack(">I4", header)
  local body = length > 0 and io.read(length) or ""
  if not body or #body < length then return nil end

  local ok, frame = pcall(mp.unpack, body)
  if not ok or type(frame) ~= "table" then
    write({ t = "error", m = "the child could not decode a frame: " .. tostring(not ok and frame or "not an object") })
    return nil
  end
  return frame
end

-- The sandbox: built fresh for every invocation from an empty table, so
-- nothing a previous script left behind can be reached by the next one.
-- That matters more than it looks: the child is pooled across many
-- communities, so a shared environment would be a cross tenant leak.

-- setmetatable and rawget are exposed (MoonScript's compiled classes need
-- them), but getmetatable is not: it returns the metatable every string in
-- the process shares, so a script holding it could rewrite string.upper for
-- every later script in this pooled child, including another community's.
local DENIED = {
  io = true, os = true, package = true, require = true, dofile = true,
  loadfile = true, debug = true, load = true, loadstring = true,
  getmetatable = true, rawset = true, collectgarbage = true
}

-- Point the shared string metatable at the filtered copy, so `s:sub(1,2)`
-- and `("x").dump` see exactly what the allow list offers. mp itself
-- resolves `s:byte()`, `s:sub()` and `s:gsub()` through this same
-- metatable, so those three must stay in Sandbox::MODULES' string list.
local STRING_META = getmetatable("")

local function narrow_string_methods(copy)
  if STRING_META then STRING_META.__index = copy or {} end
end

-- setmetatable, with __gc refused. A finalizer is owned by the Lua state,
-- not the per invocation env, and this child is pooled across communities,
-- so a pending finalizer could run its host calls against the WRONG
-- community's registry. Checked raw, since the marking check is raw too.
local REAL_SETMETATABLE = setmetatable

local function guarded_setmetatable(target, meta)
  if type(meta) == "table" and rawget(meta, "__gc") ~= nil then
    error("__gc is not available to scripts", 2)
  end
  return REAL_SETMETATABLE(target, meta)
end

local function build_env(spec, call_host, payload)
  local env = {}
  spec = spec or {}

  for _, name in ipairs(spec.globals or {}) do
    if not DENIED[name] then env[name] = _G[name] end
  end

  for module_name, members in pairs(spec.modules or {}) do
    if not DENIED[module_name] and _G[module_name] then
      local source, copy = _G[module_name], {}
      for _, member in ipairs(members) do copy[member] = source[member] end
      env[module_name] = copy
    end
  end

  -- Host functions go under one table rather than as bare globals, so a script
  -- writing `local rooms = {}` cannot shadow one by accident and a reader can
  -- tell which calls are ours.
  local host = {}
  for _, name in ipairs(spec.hosts or {}) do
    host[name] = function(...) return call_host(name, table.pack(...)) end
  end

  -- What this invocation was handed, and the getters that read it back
  -- (issue #372). The payload used to arrive as the chunk's vararg, so
  -- whether answering a field cost a query depended on which one it was;
  -- that split is hidden now, since everything here is a call instead.
  host.__internal = payload or {}
  for _, name in ipairs(spec.getters or {}) do
    host[name] = function() return copied(host.__internal[name], 0) end
  end

  env[spec.namespace or "rubotty"] = host

  -- Swapped in after the globals copy, so a spec that offers setmetatable gets
  -- the guarded one and a spec that does not still gets nothing.
  if env.setmetatable then env.setmetatable = guarded_setmetatable end

  narrow_string_methods(env.string)

  env._G = env
  return env
end

-- A host call is written out and then this blocks reading the reply, so to the
-- script it looks like an ordinary synchronous function call. Nothing else is
-- in flight on the pipe, so the next frame is always this call's answer.
local function call_host(name, args)
  args.n = nil
  write({ t = "call", fn = name, args = plain(args, 0) })
  local frame = read_frame()
  if frame == nil then error("the host went away mid call", 0) end
  if frame.t == "err" then error(frame.m or "the host call failed", 0) end
  if frame.t ~= "ret" then error("the host answered a " .. tostring(frame.t) .. " frame", 0) end
  -- Several return values, when the host said so. Only then: the list
  -- returning functions answer with one table and must keep doing so.
  if frame.multi then return table.unpack(frame.v) end
  return frame.v
end

local function invoke(frame)
  local env = build_env(frame.sandbox, call_host, frame.arg)
  -- "t" refuses a precompiled binary chunk. Passing env as the fourth argument
  -- is what makes the sandbox the chunk's _ENV rather than the real globals.
  local chunk, compile_error = load(frame.src or "", "=script", "t", env)
  if not chunk then
    write({ t = "error", m = "the script would not compile: " .. tostring(compile_error) })
    return
  end

  -- Called with nothing. The payload used to be the chunk's vararg, which is
  -- what `local m = ...` read; it goes in through the sandbox now, and passing
  -- it here as well would leave the old shape working as an alias nobody
  -- maintains.
  local ok, result = pcall(chunk)
  -- Belt and braces behind the setmetatable guard: run anything still pending
  -- here, where this invocation's own registry is still the one answering, and
  -- before the done frame lets the parent check the child back in. Twice,
  -- because a finalizer can make more garbage.
  collectgarbage("collect")
  collectgarbage("collect")
  if ok then
    write({ t = "done", v = plain(result, 0) })
  else
    write({ t = "error", m = tostring(result) })
  end
end

while true do
  local frame = read_frame()
  if frame == nil then break end
  if frame.t == "invoke" then
    local ok, failure = pcall(invoke, frame)
    if not ok then write({ t = "error", m = tostring(failure) }) end
  end
end
