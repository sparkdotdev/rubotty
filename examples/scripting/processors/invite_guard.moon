-- Checks any link against the room's own link filter.
-- trigger: contains  { words = {"http://", "https://"} }
--
-- A blocked link is removed. A domain nobody has ruled on yet is allowed, but
-- the operators hear about it.

-- Ask what the room's link filter thinks of this link.
verdict = rubotty.link_verdict rubotty.text!

if verdict == "blocked"
  return { action: "reject", reason: "That link is not allowed here." }

if verdict == "unknown_domain" and not rubotty.author_is_operator!
  -- Post a message into this room, as the bot.
  rubotty.notify "A link to somewhere I do not recognise was posted. Worth a look."

{ action: "allow" }
