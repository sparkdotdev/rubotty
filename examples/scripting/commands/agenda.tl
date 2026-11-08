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

local function when(seconds: integer): string
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

-- Shorten this to what the smallest platform here allows.
return rubotty.truncate(rubotty.blockquote(table.concat(lines, "\n")))
