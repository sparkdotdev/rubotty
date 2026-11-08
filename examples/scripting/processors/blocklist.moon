-- Rejects a message holding any phrase from this script's own data file.
-- trigger: always
--
-- The list lives under Data beside this code rather than inside it. That is
-- the whole point: somebody who wants to add a phrase edits a YAML file, and
-- the MoonScript never changes. It is read with rubotty.yaml_data(), which
-- hands back the parsed document, and a script can only read it.
--
-- Written to survive having no data at all, because that is what it gets
-- before anybody fills the Data tab in, and a rule that fell over there could
-- never pass its check.
data = rubotty.yaml_data! or {}
words = data.words

if not words
  { action: "allow" }
else
  text = string.lower rubotty.text! or ""
  hit = nil
  for word in *words
    if string.find text, string.lower(word), 1, true
      hit = word
      break

  if hit
    { action: "reject", reason: data.reason or "That is not allowed here." }
  else
    { action: "allow" }
