-- The same idea as company_of_heroes, in its simplest form.
-- trigger: always  {}
--
-- Asks rubotty what matched and where, then slices those words out of its own
-- copy of the message. The word list never reaches the script.

local text = rubotty.text()

-- Ask rubotty whether the room's word filter minds this text.
local verdict = rubotty.classify(text)
if verdict == "clean" then
  return { action = "allow" }
end

-- A slur is not something to make a joke out of. Everything else gets swapped.
if verdict == "slur" then
  return { action = "reject", reason = "That one is not up for a rewrite." }
end

local REPLACEMENTS = { "pudding", "bicycle", "deep fried", "kerfuffle" }

local out, last, index = "", 1, 0
-- Ask where the matches are, so we can cut them out ourselves.
for _, span in ipairs(rubotty.offending_spans(text)) do
  index = index + 1
  local swap = REPLACEMENTS[(index - 1) % #REPLACEMENTS + 1]
  out = out .. string.sub(text, last, span.from) .. swap
  last = span.to + 1
end

-- Write a line to the bot log, for debugging.
rubotty.log("filter_replace swapped " .. index .. " word(s)")
return { action = "rewrite", text = out .. string.sub(text, last) }
