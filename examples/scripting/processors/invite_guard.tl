-- Checks any link against the room's own link filter.
-- trigger: contains  { words = {"http://", "https://"} }
--
-- A blocked link is removed. A domain nobody has ruled on yet is allowed, but
-- the operators hear about it.

-- Ask what the room's link filter thinks of this link.
local verdict = rubotty.link_verdict(rubotty.text())

if verdict == "blocked" then
  return { action = "reject", reason = "That link is not allowed here." } as Verdict
end

if verdict == "unknown_domain" and not rubotty.author_is_operator() then
  -- Post a message into this room, as the bot.
  rubotty.notify("A link to somewhere I do not recognise was posted. Worth a look.")
end

return { action = "allow" } as Verdict
