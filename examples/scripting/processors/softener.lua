-- Swaps a few blunt phrases for gentler ones.
-- trigger: always  {}
--
-- A rewrite replaces the message everywhere it was relayed, so the room only
-- ever sees the softened version.

local PAIRS = {
  { "shut up", "let us hear them out" },
  { "that's stupid", "I do not follow that" },
  { "nobody cares", "I am not sure that lands" },
}

local out = rubotty.text()
for _, pair in ipairs(PAIRS) do
  out = string.gsub(out, pair[1], pair[2])
end

if out == rubotty.text() then
  return { action = "allow" }
end
return { action = "rewrite", text = out }
