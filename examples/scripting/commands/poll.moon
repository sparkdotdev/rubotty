-- Runs a poll anybody can vote in: /poll ask, vote, close.
-- trigger: command  { name = "poll" }
--
-- The same session and round a quiz uses, with the question and choices kept
-- in the round's own data instead of an answer to score against, which is
-- the whole difference between a poll and a question somebody is scored on.
-- Each choice's tally lives in a kept bucket named for the round, so closing
-- needs no per-voter walk; who voted for what is remembered per person, so a
-- second vote moves their count rather than adding a second one.
verb = string.lower(string.match(rubotty.args! or "", "^(%S+)") or "")
rest = string.match(rubotty.args! or "", "^%S+%s+(.*)$") or ""

open = rubotty.round!

-- The question and its choices, written as one line separated by pipes.
split = (text) ->
  parts = {}
  for piece in string.gmatch text, "[^|]+"
    trimmed = string.match piece, "^%s*(.-)%s*$"
    table.insert parts, trimmed if trimmed != ""
  parts

if verb == "ask"
  parts = split rest
  question = table.remove parts, 1
  if not question or #parts < 2
    return "Usage: /poll ask Which night? | Tuesday | Wednesday"

  ok, err = rubotty.open_session { kind: "poll", label: question }
  if not ok
    return "I could not start one: " .. err

  rubotty.open_round { data: { prompt: question, options: parts } }
  return question .. "\n" .. table.concat(parts, " / ") .. "\nVote with /poll vote <choice>."

if not open
  return "No poll is running here. /poll ask starts one."

tallies = "poll-" .. open.id
voters = "poll-voters-" .. open.id

if verb == "vote"
  choice = string.lower rest
  previous = rubotty.recall { bucket: voters, key: rubotty.author! }
  if previous != choice
    if previous
      rubotty.add { bucket: tallies, key: previous, by: -1, floor: 0 }
    rubotty.add { bucket: tallies, key: choice, by: 1 }
    rubotty.remember { bucket: voters, key: rubotty.author!, value: choice, ttl: 3600 }
  return "Vote recorded. Change it by voting again."

-- A round's data is opaque to rubotty, so a poll started some other way, or
-- nothing at all, leaves neither field here: fall back rather than index
-- into what open_round never set.
payload = open.data or {}
counts = {}
for entry in *rubotty.entries tallies, "", 200
  counts[entry.key] = entry.value

lines = {}
for option in *(payload.options or {})
  table.insert lines, option .. ": " .. (counts[string.lower option] or 0)

prompt = payload.prompt or ""

if verb == "close"
  rubotty.close_session!
  return "Poll closed. " .. prompt .. "\n" .. table.concat lines, "\n"

prompt .. "\n" .. table.concat lines, "\n"
