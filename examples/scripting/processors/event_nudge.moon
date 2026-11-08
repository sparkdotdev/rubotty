-- Mentions today's events when somebody asks what is on.
-- trigger: contains  { words = {"what's on", "whats on", "any events"} }
--
-- Only answers when something is actually close, because replying "nothing
-- scheduled" every time is noise.
HOUR = 3600
-- Ask for the upcoming events.
soon = [ event.title for event in *rubotty.events! when event.starts_in > 0 and event.starts_in < 24 * HOUR ]

return { action: "allow" } if #soon == 0

-- Post a message into this room, as the bot.
rubotty.notify "Coming up today: #{rubotty.bold table.concat soon, ', '}"
{ action: "allow" }
