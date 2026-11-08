-- Swaps a few blunt phrases for gentler ones.
-- trigger: always  {}
--
-- A rewrite replaces the message everywhere it was relayed, so the room only
-- ever sees the softened version.

PAIRS = {
  { "shut up", "let us hear them out" },
  { "that's stupid", "I do not follow that" },
  { "nobody cares", "I am not sure that lands" },
}

out = rubotty.text!
for pair in *PAIRS
  out = out\gsub pair[1], pair[2]

if out == rubotty.text! then { action: "allow" } else { action: "rewrite", text: out }
