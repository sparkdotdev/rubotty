-- Lists what is coming up: /agenda.
-- trigger: command  { name = "agenda" }
--
-- Events are asked for rather than sent with every message, because almost no
-- script needs them. Each one says how many seconds until it starts.

-- Ask for the upcoming events.
events = rubotty.events!

return "Nothing scheduled." if #events == 0

-- Sixty seconds either way does not matter here, so integer hours read better
-- than a timestamp somebody has to convert out of UTC.
when_in = (seconds) ->
  return "#{math.floor seconds / 60} minutes" if seconds < 3600
  "#{math.floor seconds / 3600} hours"

lines = [ "#{rubotty.bold event.title}, in #{when_in event.starts_in} (#{event.rsvp_count} coming)" for event in *events ]

-- Truncated because a busy community can have more events than the narrowest
-- platform in the room will accept in one message.
rubotty.truncate rubotty.blockquote table.concat lines, "\n"
