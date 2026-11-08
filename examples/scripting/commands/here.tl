-- Says what this room is connected to: /here.
-- trigger: command  { name = "here" }
--
-- Handy for checking whether a room really does bridge the platforms you
-- think it does.

-- Ask which platforms this room is bridged to.
local platforms = rubotty.platforms()
-- Ask which features are on in this room.
local features = rubotty.features()

local answer = rubotty.bold(rubotty.room_key()) .. " bridges " .. table.concat(platforms, ", ") ..
  ".\nRunning: " .. table.concat(features, ", ")

-- Check whether a feature is switched on for this room.
if rubotty.feature_enabled("word_filter") then
  answer = answer .. "\nThe word filter is on in here."
end

return answer
