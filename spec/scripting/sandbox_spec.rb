# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# What an operator's script can and cannot reach. These run real Lua in the real
# child rather than asserting on the allow lists, so every one is a probe somebody
# could type into the editor.
RSpec.describe "the sandbox a script runs in" do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  let(:registry) { Rubotty::Scripting::Registry.new }

  after { pool.close }

  def run(source) = pool.run(source: source, arg: {}, registry: registry, timeout: 5)

  describe "the dangerous libraries" do
    # Named directly, which is the first thing anybody tries.
    %w[os io package require load loadstring dofile loadfile debug
       getmetatable rawset collectgarbage coroutine print].each do |name|
      it "does not offer #{name}" do
        expect(run("return tostring(#{name})")).to eq("nil")
      end
    end

    # _G is the sandbox itself, so walking it finds nothing the env does not
    # already hold.
    it "points _G at the sandbox rather than the real globals" do
      expect(run("return tostring(_G.os)")).to eq("nil")
      expect(run("return tostring(_G.io)")).to eq("nil")
    end

    it "lists only what was allowed when a script walks its own globals" do
      names = run('local k = {} for n in pairs(_G) do k[#k+1] = n end table.sort(k) return table.concat(k, " ")')

      expect(names.split).to match_array(%w[_G assert error ipairs math next pairs pcall rawget
                                            rubotty select setmetatable string table tonumber
                                            tostring type xpcall])
    end
  end

  # A string literal resolves methods through the metatable Lua shares process wide,
  # whose __index is the real string table, so `("x").dump` used to hand over a
  # function the allow list never mentions. It needs no getmetatable to reach.
  describe "string methods" do
    it "offers the whitelisted ones through method syntax" do
      expect(run('return ("ab"):rep(2)')).to eq("abab")
      expect(run('return ("AB"):lower()')).to eq("ab")
    end

    it "does not leak an unlisted one through the shared metatable" do
      expect(run('return tostring(("x").dump)')).to eq("nil")
    end

    it "keeps the module copy and the method route offering the same set" do
      answer = run('return tostring(string.dump) .. " " .. tostring(("x").dump)')

      expect(answer).to eq("nil nil")
    end
  end

  describe "reaching out of the environment" do
    it "cannot borrow the real globals through a metatable of its own" do
      expect(run('local t = setmetatable({}, {__index = _G}); return tostring(t.os)')).to eq("nil")
    end

    it "cannot read the filesystem, since there is nothing to read it with" do
      expect(run('local ok = pcall(function() return io.open("/etc/hosts") end); return tostring(ok)'))
        .to eq("false")
    end
  end

  # Every host call encodes and decodes MessagePack in the child, through the
  # very metatable this narrows, so getting the allow list wrong could break
  # the whole harness rather than just a script.
  describe "the host call path" do
    it "still round trips a call after the string metatable is narrowed" do
      registry.register("classify") { |text| "seen:#{text}" }

      expect(run('return rubotty.classify("hello")')).to eq("seen:hello")
    end
  end

  # What the invocation was handed, read back through calls built inside the child. None of
  # these crosses the pipe, so the properties worth pinning are that they answer at all,
  # that they answer a copy, and that they are free.
  describe "reading what you were handed" do
    def handed(source, payload)
      pool.run(source: source, arg: payload, registry: registry, timeout: 5)
    end

    it "answers what the payload carried" do
      expect(handed("return rubotty.text()", { "text" => "hello" })).to eq("hello")
    end

    it "answers nil for anything the payload did not carry" do
      expect(handed("return tostring(rubotty.window())", { "text" => "hello" })).to eq("nil")
    end

    # The trap the whole thing turns on. A script that sorts, clears or appends
    # to what it got would otherwise be editing the payload, so the next call
    # would answer something the host never sent.
    it "answers a copy, so mutating what you got cannot change what comes next" do
      source = <<~LUA
        local first = rubotty.attachments()
        first[1] = nil
        first.injected = true
        local second = rubotty.attachments()
        return #second .. "/" .. tostring(second.injected)
      LUA

      expect(handed(source, { "attachments" => [{ "filename" => "a.png" }] })).to eq("1/nil")
    end

    it "copies a nested table too, rather than only the outer one" do
      source = <<~LUA
        rubotty.reply_to().nested.text = "changed"
        return rubotty.reply_to().nested.text
      LUA

      expect(handed(source, { "reply_to" => { "nested" => { "text" => "original" } } }))
        .to eq("original")
    end

    # Never counted, because none of these reaches the pipe at all. Well past
    # Registry::DEFAULT_MAX_CALLS, so a getter that were charged would end the
    # invocation rather than answering.
    it "costs nothing against the call budget, however many times it is read" do
      source = <<~LUA
        local seen = 0
        for _ = 1, 5000 do
          if rubotty.text() == "hello" then seen = seen + 1 end
        end
        return seen
      LUA

      expect(handed(source, { "text" => "hello" })).to eq(5000)
    end

    # The payload itself is reachable, and that is deliberate: it is the
    # delivery mechanism, and naming it __internal says whose it is.
    it "keeps the payload on __internal, where the getters read it from" do
      expect(handed("return rubotty.__internal.text", { "text" => "hello" })).to eq("hello")
    end

    # No alias, which is the point of the change: a script written against the
    # old vararg fails at the save gate rather than reading nil forever.
    it "hands the chunk nothing, so the old vararg is gone rather than aliased" do
      expect(handed("return tostring((...))", { "text" => "hello" })).to eq("nil")
    end
  end
end

# A handler returning [false, "why"] used to arrive as a Lua table, which is truthy, so
# `if not ok then` never fired and every script written the documented way ignored every
# refusal. Unpacking any array cannot be the fix, because the list returning functions
# answer with one table.
RSpec.describe "how a host function answers", :control_plane do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }

  after { pool.close }

  def run(source, handlers)
    registry = Rubotty::Scripting::HostFunctions.registry(handlers: handlers)
    pool.run(source: source, arg: {}, registry: registry, timeout: 5)
  end

  it "gives a refusal as false and a reason, so `if not ok` fires" do
    answer = run(<<~LUA, { "remember" => ->(*) { Rubotty::Scripting::Answer.refuse("nope") } })
      local ok, err = rubotty.remember("k", "v")
      if not ok then return "refused: " .. tostring(err) end
      return "wrongly looked fine"
    LUA

    expect(answer).to eq("refused: nope")
  end

  it "gives a plain success as a single true" do
    answer = run(<<~LUA, { "remember" => ->(*) { Rubotty::Scripting::Answer.ok } })
      local ok, err = rubotty.remember("k", "v")
      return tostring(ok) .. "/" .. tostring(err)
    LUA

    expect(answer).to eq("true/nil")
  end

  # The reason the fix is a marker rather than "unpack any array".
  it "still hands a list back as one table" do
    answer = run(<<~LUA, { "rooms" => -> { %w[general lobby] } })
      local list = rubotty.rooms()
      return type(list) .. ":" .. tostring(#list) .. ":" .. tostring(list[1])
    LUA

    expect(answer).to eq("table:2:general")
  end
end
