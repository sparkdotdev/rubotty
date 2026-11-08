-- Rejects a message holding any phrase from this script's own data file.
-- trigger: always
--
-- The list lives under Data beside this code rather than inside it. That is
-- the whole point: somebody who wants to add a phrase edits a YAML file, and
-- the Teal never changes. It is read with rubotty.yaml_data(), which hands
-- back the parsed document, and a script can only read it.
--
-- A data file is a set of keys or a list, and Teal cannot say "either", so the
-- declaration is the map shape and a list inside it is cast where it is used.
--
-- Written to survive having no data at all, because that is what it gets
-- before anybody fills the Data tab in, and a rule that fell over there could
-- never pass its check.

-- Annotated rather than inferred: `x or {}` on its own leaves Teal with the
-- empty table's type, and every field read off it is then an unknown field.
local data: {string:any} = rubotty.yaml_data() or {}
local words = data.words as {string}
if not words then
  -- Cast, because Teal infers the return type from the first table it sees and
  -- the reject below carries a field this one does not.
  return { action = "allow" } as Verdict
end

local text = string.lower(rubotty.text() or "")
for _, word in ipairs(words) do
  if string.find(text, string.lower(word), 1, true) then
    return { action = "reject", reason = (data.reason as string) or "That is not allowed here." }
  end
end

return { action = "allow" }
