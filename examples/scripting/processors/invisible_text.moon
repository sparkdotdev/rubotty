-- Strips invisible characters people use to sneak past word filters.
-- trigger: always  {}
--
-- Removes zero width spaces and the stacked accents that make text unreadable.
-- A message that was nothing but those is removed instead.
out = rubotty.text!

-- Zero width space, ZWNJ, ZWJ, word joiner, and the RTL/LTR overrides.
INVISIBLE = { "\226\128\139", "\226\128\140", "\226\128\141", "\226\129\160", "\226\128\174", "\226\128\173" }
for seq in *INVISIBLE
  out = out\gsub seq, ""

-- Combining marks stacked more than twice on one base character are the zalgo
-- shape. Accents and most Indic scripts stay well under it.
stripped = out\gsub "([\204\205][\128-\191])([\204\205][\128-\191])([\204\205][\128-\191])+", "%1%2"

if stripped == rubotty.text!
  { action: "allow" }
elseif stripped\gsub("%s", "") == ""
  { action: "reject", reason: "That message was only invisible characters." }
else
  { action: "rewrite", text: stripped }
