-- Turns a long SHOUTED message down instead of removing it.
-- trigger: always  {}
--
-- Counts capital letters and rewrites when most of them are. Short bursts
-- like "OK GREAT" are left alone.
local text = rubotty.text()
if string.len(text) < 15 then
  return { action = "allow" }
end

local letters, capitals = 0, 0
for i = 1, string.len(text) do
  local c = string.sub(text, i, i)
  if string.match(c, "%a") then
    letters = letters + 1
    if string.match(c, "%u") then capitals = capitals + 1 end
  end
end

if letters == 0 or (capitals / letters) < 0.7 then
  return { action = "allow" }
end

local calmed = string.upper(string.sub(text, 1, 1)) .. string.lower(string.sub(text, 2))
return { action = "rewrite", text = calmed }
