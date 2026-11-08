-- Rejects a message holding any phrase from this script's own data file.
-- trigger: always
--
-- The list lives under Data beside this code, not inside it: somebody who
-- wants to add a phrase edits a YAML file, and the Lua never changes, read
-- with rubotty.yaml_data(), which a script can only read from. Written to
-- survive having no data at all, since that is what it gets before anybody
-- fills the Data tab in.
local data = rubotty.yaml_data() or {}
local words = data.words
if not words then
  return { action = "allow" }
end

local text = string.lower(rubotty.text() or "")
for _, word in ipairs(words) do
  if string.find(text, string.lower(word), 1, true) then
    return { action = "reject", reason = data.reason or "That is not allowed here." }
  end
end

return { action = "allow" }
