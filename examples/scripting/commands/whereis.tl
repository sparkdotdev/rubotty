-- Finds a room by name: /whereis banking.
-- trigger: command  { name = "whereis" }
--
-- Shows how to ask rubotty for something. The script never sees a database,
-- only the list it is handed back.
local wanted = string.lower(rubotty.args())
if wanted == "" then
  return "Usage: /whereis <topic>"
end

local matches = {}
-- Ask rubotty for the rooms in this community.
for _, room in ipairs(rubotty.rooms() as {string}) do
  if string.find(string.lower(room), wanted, 1, true) then
    matches[#matches + 1] = room
  end
end

if #matches == 0 then
  return "Nothing here matches " .. wanted .. ". Try /rules for the room list."
end
return "Try: " .. table.concat(matches, ", ")
