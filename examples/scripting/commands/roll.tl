-- Rolls dice: /roll 2d6.
-- trigger: command  { name = "roll" }
--
-- Whatever a command returns is what rubotty posts. This one only does
-- arithmetic on its own argument.
local count_text, sides_text = string.match(rubotty.args(), "^(%d*)d(%d+)$")
if not sides_text then
  return "Usage: /roll 2d6"
end

local count = math.tointeger(tonumber(count_text) or 1)
local sides = math.tointeger(tonumber(sides_text))
if count < 1 or count > 20 or sides < 2 or sides > 1000 then
  return "I roll between 1 and 20 dice, of 2 to 1000 sides."
end

-- One call for the whole handful. The host seeds it, so the numbers are
-- genuinely unpredictable and the smoke test can still repeat a run. Asking for
-- one number at a time would spend the call budget on a big roll.
--
-- This example used to derive the numbers from the message text instead, which
-- made every result predictable from the message that asked for it. That is not
-- a dice roll, and anybody who copied it inherited the problem.
--
-- The cast is because random answers one number positionally and a list from a
-- table, and Teal has no way to declare both.
local rolls = rubotty.random{ count = count, min = 1, max = sides } as {integer}

local total = 0
local parts = {}
for i = 1, #rolls do
  total = total + rolls[i]
  parts[#parts + 1] = tostring(rolls[i])
end

return rubotty.author() .. " rolled " .. table.concat(parts, ", ") .. "  (total " .. total .. ")"
