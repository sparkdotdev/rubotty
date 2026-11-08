-- A shared note for the room: /note, /note <text>, /note clear.
-- trigger: command  { name = "note" }
--
-- Shows how a script remembers something between messages. Anything it keeps
-- expires on its own, a day from now unless you say otherwise.
local KEY = "note:" .. rubotty.room_key()
local WEEK = 7 * 24 * 60 * 60

if rubotty.args() == "" then
  -- Read back what we kept, or nil if it has gone.
  local existing = rubotty.recall{ key = KEY }
  return existing and ("Note: " .. existing) or "No note set. Try /note <something>."
end

if rubotty.args() == "clear" then
  -- Drop what we kept.
  rubotty.forget{ key = KEY }
  return "Note cleared."
end

-- remember returns false at the key cap rather than evicting something older,
-- so a rule can see the write failed instead of silently losing it.
if not rubotty.remember{ key = KEY, value = rubotty.args(), ttl = WEEK } then
  return "I am holding as many notes as I can. Clear one first."
end
return "Noted, for a week."
