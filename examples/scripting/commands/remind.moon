-- Reminds you later: /remind 30 stand up.
-- trigger: command  { name = "remind" }
--
-- Runs twice: once when you type it, and again when the timer fires. The
-- second run has no message behind it, so check rubotty.kind! to tell them
-- apart.

-- A wake, rather than somebody typing the command.
if rubotty.kind! == "scheduled_function"
  -- Read once: a getter that answers a table hands back a fresh copy.
  booked = rubotty.invocation_data!
  -- Turn a name into a real ping.
  return "#{rubotty.mention booked.who}, you asked me to remind you: #{booked.what}"

minutes, what = string.match rubotty.args!, "^(%d+)%s+(.+)$"
return "Usage: /remind <minutes> <what>" unless minutes

-- Come back and run this again later.
who = rubotty.author!
rubotty.schedule
  after: tonumber(minutes) * 60
  data: { who: who, what: what }

-- Turn a name into a real ping.
"Right you are, #{rubotty.mention who}, in #{minutes} minutes."
