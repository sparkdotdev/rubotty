-- Rolls dice: /roll 2d6.
-- trigger: command  { name = "roll" }
--
-- Whatever a command returns is what rubotty posts. This one only does
-- arithmetic on its own argument.
local count, sides = string.match(rubotty.args(), "^(%d*)d(%d+)$")
if not sides then
  return "Usage: /roll 2d6"
end

count = tonumber(count) or 1
sides = tonumber(sides)
if count < 1 or count > 20 or sides < 2 or sides > 1000 then
  return "I roll between 1 and 20 dice, of 2 to 1000 sides."
end

-- One call for the whole handful: the host seeds it, so results are
-- genuinely unpredictable yet a smoke test can still repeat a run. This
-- example used to derive numbers from the message text instead, which made
-- every result predictable and is not a dice roll; do not reintroduce that.
local rolls = rubotty.random{ count = count, min = 1, max = sides }

local total, parts = 0, {}
for i = 1, #rolls do
  total = total + rolls[i]
  parts[#parts + 1] = tostring(rolls[i])
end

return rubotty.author() .. " rolled " .. table.concat(parts, ", ") .. "  (total " .. total .. ")"
