-- Runs a poll anybody can vote in: /poll ask, vote, close.
-- trigger: command  { name = "poll" }
--
-- The same session and round a quiz uses, with the question and choices kept
-- in the round's own data instead of an answer to score against: that is the
-- whole difference between a poll and a scored question. Each choice's tally
-- lives in a kept bucket named for the round, so closing needs no per-voter
-- walk; a second vote moves that voter's count rather than adding a new one.
local verb = string.lower(string.match(rubotty.args() or "", "^(%S+)") or "")
local rest = string.match(rubotty.args() or "", "^%S+%s+(.*)$") or ""

local open = rubotty.round()

-- The question and its choices, written as one line separated by pipes.
local function split(text)
  local parts = {}
  for piece in string.gmatch(text, "[^|]+") do
    local trimmed = string.match(piece, "^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(parts, trimmed)
    end
  end
  return parts
end

if verb == "ask" then
  local parts = split(rest)
  local question = table.remove(parts, 1)
  if not question or #parts < 2 then
    return "Usage: /poll ask Which night? | Tuesday | Wednesday"
  end

  local ok, err = rubotty.open_session{ kind = "poll", label = question }
  if not ok then
    return "I could not start one: " .. err
  end

  rubotty.open_round{ data = { prompt = question, options = parts } }
  return question .. "\n" .. table.concat(parts, " / ") .. "\nVote with /poll vote <choice>."
end

if not open then
  return "No poll is running here. /poll ask starts one."
end

local tallies = "poll-" .. open.id
local voters = "poll-voters-" .. open.id

if verb == "vote" then
  local choice = string.lower(rest)
  local previous = rubotty.recall{ bucket = voters, key = rubotty.author() }
  if previous ~= choice then
    if previous then
      rubotty.add{ bucket = tallies, key = previous, by = -1, floor = 0 }
    end
    rubotty.add{ bucket = tallies, key = choice, by = 1 }
    rubotty.remember{ bucket = voters, key = rubotty.author(), value = choice, ttl = 3600 }
  end
  return "Vote recorded. Change it by voting again."
end

-- A round's data is opaque to rubotty, so a poll started some other way, or
-- nothing at all, leaves neither field here: fall back rather than index
-- into what open_round never set.
local payload = open.data or {}
local counts = {}
for _, entry in ipairs(rubotty.entries(tallies, "", 200)) do
  counts[entry.key] = entry.value
end

local lines = {}
for _, option in ipairs(payload.options or {}) do
  table.insert(lines, option .. ": " .. (counts[string.lower(option)] or 0))
end

if verb == "close" then
  rubotty.close_session()
  return "Poll closed. " .. (payload.prompt or "") .. "\n" .. table.concat(lines, "\n")
end

return (payload.prompt or "") .. "\n" .. table.concat(lines, "\n")
