-- Scores a first message on several spam signals at once.
-- trigger: new_voice  { window = 200 }
--
-- One signal on its own is usually innocent, so nothing happens until enough
-- of them fire together.
local text = string.lower(rubotty.text())

local function score(condition: boolean, weight: integer): integer
  return condition and weight or 0
end

local points: integer =
  score(string.find(text, "https?://") ~= nil, 2) +
  score(string.find(text, "t%.me/") ~= nil, 3) +
  score(string.find(text, "airdrop") ~= nil, 3) +
  score(string.len(rubotty.text()) > 400, 1) +
  score(string.find(text, "dm me") ~= nil, 2)

if points >= 4 then
  return { action = "reject", reason = "That first message tripped several spam signals at once." } as Verdict
end
return { action = "allow" } as Verdict
