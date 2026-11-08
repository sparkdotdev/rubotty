-- Reminds you later: /remind 30 stand up.
-- trigger: command  { name = "remind" }
--
-- Runs twice: once when you type it, and again when the timer fires. The
-- second run has no message behind it, so check rubotty.kind() to tell them
-- apart.

-- A wake, rather than somebody typing the command.
if rubotty.kind() == "scheduled_function" then
  -- Read once: a getter that answers a table hands back a fresh copy.
  local booked = rubotty.invocation_data()
  -- Turn a name into a real ping.
  return rubotty.mention(booked.who) .. ", you asked me to remind you: " .. booked.what
end

local minutes, what = string.match(rubotty.args(), "^(%d+)%s+(.+)$")
if not minutes then
  return "Usage: /remind <minutes> <what>"
end

-- Come back and run this again later.
local who = rubotty.author()
rubotty.schedule({
  after = tonumber(minutes) * 60,
  data = { who = who, what = what },
})

-- Turn a name into a real ping.
return "Right you are, " .. rubotty.mention(who) .. ", in " .. minutes .. " minutes."
