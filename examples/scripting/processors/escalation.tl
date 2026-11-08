-- Warns once, then involves a person on the third strike.
-- trigger: recent_contains  { words = {"scam", "airdrop", "dm me"}, window = 20, count = 3 }
--
-- Counting per person needs a memory, because the trigger only knows the
-- phrase came up, not who kept saying it.
local KEY = "strikes:" .. rubotty.author()
-- Read back what we kept, or nil if it has gone.
local strikes = (tonumber(rubotty.recall({ key = KEY })) or 0) + 1

-- Keep this until it expires.
rubotty.remember({ key = KEY, value = strikes, ttl = 7 * 24 * 60 * 60 })
-- Record a warning against this person.
rubotty.warn("Repeated scam phrasing (" .. strikes .. ")")

if strikes < 3 then
  return { action = "allow" } as Verdict
end

-- Tell the operators, without the room seeing it.
rubotty.alert(rubotty.author() .. " has hit " .. strikes ..
              " strikes for scam phrasing in " .. rubotty.room_key() .. ".")
return { action = "reject", reason = "This has come up before. An operator will pick it up." } as Verdict
