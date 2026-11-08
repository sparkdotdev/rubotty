-- Closes whichever round is open, pays for it, and posts the result.
-- trigger: always
--
-- Booked by trivia's own open_round, so this wakes with no message behind
-- it: no author, no text. What a right answer is worth travelled here in
-- the round's own data, so this never has to go read a data file of its
-- own. Whoever got it right was already added to a bucket named for this
-- very round while they were answering, so paying and reporting cost the
-- same five host calls whatever the room holds.
local round = rubotty.round()
if not round then
  -- Cast, because Teal infers the return type from the first table it sees and
  -- the answer below carries a field this one does not.
  return { action = "allow" } as Verdict
end

local right = rubotty.entries("round-" .. round.id, "", 200)

local awards: {string:integer} = {}
local names: {string} = {}
for _, entry in ipairs(right) do
  awards[entry.key] = (round.data.points as integer) or 10
  table.insert(names, entry.key)
end

if #names > 0 then
  rubotty.add({ bucket = "scores", by = awards })
end
rubotty.close_round({ data = round.data })

local lines: {string} = { "Round " .. round.position .. " is closed." }
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
