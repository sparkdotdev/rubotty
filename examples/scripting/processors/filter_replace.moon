-- The same idea as company_of_heroes, in its simplest form.
-- trigger: always  {}
--
-- Asks rubotty what matched and where, then slices those words out of its own
-- copy of the message. The word list never reaches the script.

text = rubotty.text!

-- Ask rubotty whether the room's word filter minds this text.
verdict = rubotty.classify text
if verdict == "clean"
  return { action: "allow" }

-- A slur is not something to make a joke out of.
if verdict == "slur"
  return { action: "reject", reason: "That one is not up for a rewrite." }

REPLACEMENTS = { "pudding", "bicycle", "deep fried", "kerfuffle" }

out, last, index = "", 1, 0
-- Ask where the matches are, so we can cut them out ourselves.
for span in *rubotty.offending_spans text
  index += 1
  swap = REPLACEMENTS[(index - 1) % #REPLACEMENTS + 1]
  out ..= string.sub(text, last, span.from) .. swap
  last = span.to + 1

-- Write a line to the bot log, for debugging.
rubotty.log "filter_replace swapped #{index} word(s)"
{ action: "rewrite", text: out .. string.sub text, last }
