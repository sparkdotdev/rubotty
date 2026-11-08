-- Warns somebody for shouting, but only once a day.
-- trigger: always
--
-- Without the memory it would warn on every message in a bad afternoon, which
-- is how a warning ladder stops meaning anything.
letters = string.gsub rubotty.text!, "[^%a]", ""

return { action: "allow" } if #letters < 12 or letters != string.upper letters

-- Keyed per person, so one member having a bad day does not use up everybody
-- else's quiet.
KEY = "warned:" .. rubotty.author!
-- Read back what we kept, or nil if it has gone.
return { action: "allow" } if rubotty.recall { key: KEY }

-- Record a warning against this person.
rubotty.warn "Shouting in #{rubotty.room_key!}"
-- Keep this until it expires.
rubotty.remember { key: KEY, value: true, ttl: 24 * 60 * 60 }
{ action: "allow" }
