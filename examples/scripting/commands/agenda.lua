-- Lists what is coming up: /agenda.
-- trigger: command  { name = "agenda" }
--
-- Events are asked for rather than sent with every message, because almost no
-- script needs them. Each one says how many seconds until it starts.

-- Ask for the upcoming events.
local events = rubotty.events()

if #events == 0 then
  return "Nothing scheduled."
end

-- Sixty seconds either way does not matter here, so integer hours read better
-- than a timestamp somebody has to convert out of UTC.
local function when(seconds)
  if seconds < 3600 then
    return math.floor(seconds / 60) .. " minutes"
  end
  return math.floor(seconds / 3600) .. " hours"
end

local lines = {}
for _, event in ipairs(events) do
  table.insert(lines, rubotty.bold(event.title) .. ", in " .. when(event.starts_in) ..
    " (" .. event.rsvp_count .. " coming)")
end

-- Truncated because a busy community can have more events than the narrowest
-- platform in the room will accept in one message.
return rubotty.truncate(rubotty.blockquote(table.concat(lines, "\n")))
