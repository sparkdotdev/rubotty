-- Rolls dice: /roll 2d6.
-- trigger: command  { name = "roll" }
--
-- Whatever a command returns is what rubotty posts. This one only does
-- arithmetic on its own argument.
count, sides = string.match rubotty.args!, "^(%d*)d(%d+)$"
if not sides
  return "Usage: /roll 2d6"

count = tonumber(count) or 1
sides = tonumber sides
if count < 1 or count > 10 or sides < 2 or sides > 1000
  return "I roll between 1 and 10 dice, of 2 to 1000 sides."

-- One call for the whole handful. The host seeds it, so a test can repeat it,
-- and asking for one number at a time would spend the call budget on a big roll.
rolls = rubotty.random{ count: count, min: 1, max: sides }

total, parts = 0, {}
for i = 1, #rolls
  total += rolls[i]
  parts[#parts + 1] = tostring rolls[i]

"#{rubotty.author!} rolled #{table.concat parts, ', '}  (total #{total})"
