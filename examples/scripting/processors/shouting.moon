-- Turns a long SHOUTED message down instead of removing it.
-- trigger: always  {}
--
-- Counts capital letters and rewrites when most of them are. Short bursts
-- like "OK GREAT" are left alone.
text = rubotty.text!
if string.len(text) < 15
  return { action: "allow" }

letters, capitals = 0, 0
for i = 1, string.len text
  c = string.sub text, i, i
  if string.match c, "%a"
    letters += 1
    capitals += 1 if string.match c, "%u"

if letters == 0 or (capitals / letters) < 0.7
  return { action: "allow" }

calmed = string.upper(string.sub text, 1, 1) .. string.lower string.sub text, 2
{ action: "rewrite", text: calmed }
