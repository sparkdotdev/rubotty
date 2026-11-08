-- A shared note for the room: /note, /note <text>, /note clear.
-- trigger: command  { name = "note" }
--
-- Shows how a script remembers something between messages. Anything it keeps
-- expires on its own, a day from now unless you say otherwise.
KEY = "note:" .. rubotty.room_key!
WEEK = 7 * 24 * 60 * 60

if rubotty.args! == ""
  -- Read back what we kept, or nil if it has gone.
  existing = rubotty.recall { key: KEY }
  return if existing then "Note: #{existing}" else "No note set. Try /note <something>."

if rubotty.args! == "clear"
  -- Drop what we kept.
  rubotty.forget { key: KEY }
  return "Note cleared."

-- remember returns false at the key cap rather than evicting something older,
-- so a rule can see the write failed instead of silently losing it.
unless rubotty.remember { key: KEY, value: rubotty.args!, ttl: WEEK }
  return "I am holding as many notes as I can. Clear one first."

"Noted, for a week."
