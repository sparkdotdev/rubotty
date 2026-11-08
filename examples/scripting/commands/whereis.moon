-- Finds a room by name: /whereis banking.
-- trigger: command  { name = "whereis" }
--
-- Shows how to ask rubotty for something. The script never sees a database,
-- only the list it is handed back.
wanted = string.lower rubotty.args!
if wanted == ""
  return "Usage: /whereis <topic>"

-- Ask rubotty for the rooms in this community.
matches = [room for room in *rubotty.rooms() when string.find string.lower(room), wanted, 1, true]

if #matches == 0
  "Nothing here matches " .. wanted .. ". Try /rules for the room list."
else
  "Try: " .. table.concat matches, ", "
