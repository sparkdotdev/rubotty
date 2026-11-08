-- Mentions today's events when somebody asks what is on.
-- trigger: contains  { words = {"what's on", "whats on", "any events"} }
--
-- Only answers when something is actually close, because replying "nothing
-- scheduled" every time is noise.
local HOUR = 3600
local soon = {}

-- Ask for the upcoming events.
for _, event in ipairs(rubotty.events()) do
  if event.starts_in > 0 and event.starts_in < 24 * HOUR then
    table.insert(soon, event.title)
  end
end

if #soon == 0 then
  return { action = "allow" } as Verdict
end

-- Post a message into this room, as the bot.
rubotty.notify("Coming up today: " .. rubotty.bold(table.concat(soon, ", ")))
return { action = "allow" } as Verdict
