-- Closes whichever round is open, pays for it, and posts the result.
-- trigger: always
--
-- Booked by trivia's own open_round, so this wakes with no message behind
-- it: no author, no text. What a right answer is worth travelled here in
-- the round's own data, so this never has to read a data file of its own.
-- Whoever got it right was already added to a bucket named for this round
-- while they were answering, so paying and reporting cost is cheap.
local round = rubotty.round()
if not round then
  return { action = "allow" }
end

local right = rubotty.entries("round-" .. round.id, "", 200)

local awards = {}
local names = {}
for _, entry in ipairs(right) do
  awards[entry.key] = round.data.points or 10
  table.insert(names, entry.key)
end

if #names > 0 then
  rubotty.add{ bucket = "scores", by = awards }
end
rubotty.close_round()

local lines = { "Round " .. round.position .. " is closed." }
if #names == 0 then
  table.insert(lines, "Nobody got that one.")
else
  table.insert(lines, "Right: " .. table.concat(names, ", "))
end

local leader = rubotty.top("scores", 1)[1]
if leader then
  table.insert(lines, "Leading: " .. leader.key .. " on " .. leader.value .. ".")
end

-- Any action can carry a reply, and a woken script's reply is posted into the
-- room it was booked from.
return { action = "allow", reply = table.concat(lines, "\n") }
