-- Shows a shared tally: /scoreboard.
-- trigger: command  { name = "scoreboard" }
--
-- Reads a kept bucket, which any script in this community can add to with
-- rubotty.add. Kept totals are whole numbers that never expire, so a score is
-- still there next month, and rubotty sorts them so a leaderboard is one call.

-- Highest first, already in order. Sorting this in Lua would mean reading every
-- key in the bucket to show five of them.
local leaders = rubotty.top("scores", 5)

if #leaders == 0 then
  return "Nobody has scored yet."
end

local lines = {}
for place, entry in ipairs(leaders) do
  lines[#lines + 1] = place .. ". " .. rubotty.bold(entry.key) .. " " .. entry.value
end

return table.concat(lines, "\n")
