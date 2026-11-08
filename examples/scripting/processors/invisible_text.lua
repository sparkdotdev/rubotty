-- Strips invisible characters people use to sneak past word filters.
-- trigger: always  {}
--
-- Removes zero width spaces and the stacked accents that make text unreadable.
-- A message that was nothing but those is removed instead.
local out = rubotty.text()

-- Zero width space, ZWNJ, ZWJ, word joiner, and the RTL/LTR overrides.
local INVISIBLE = { "\226\128\139", "\226\128\140", "\226\128\141", "\226\129\160",
                    "\226\128\174", "\226\128\173" }
for _, seq in ipairs(INVISIBLE) do
  out = string.gsub(out, seq, "")
end

-- Combining marks stacked more than twice on one base character are the zalgo
-- shape. Anything legitimate (accents, most Indic scripts) stays well under it.
local stripped = string.gsub(out, "([\204\205][\128-\191])([\204\205][\128-\191])([\204\205][\128-\191])+", "%1%2")

if stripped == rubotty.text() then
  return { action = "allow" }
end
if string.gsub(stripped, "%s", "") == "" then
  return { action = "reject", reason = "That message was only invisible characters." }
end
return { action = "rewrite", text = stripped }
