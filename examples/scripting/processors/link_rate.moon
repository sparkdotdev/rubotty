-- Speaks up when links start arriving quickly.
-- trigger: contains_rate  { words = {"http://", "https://"}, count = 3, minutes = 10 }
--
-- Counts in real time rather than in messages. Twenty messages is a minute in
-- a busy room and a week in a quiet one, so a rule about pace wants minutes.

-- The trigger only wakes this once the third link inside the window lands.
{
  action: "allow"
  reply: "That is " .. rubotty.count! .. " links in " .. rubotty.minutes! .. " minutes, easy now."
}
