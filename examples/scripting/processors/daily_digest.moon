-- Posts a short roundup every morning.
-- trigger: recurring  { every = "day", at = "09:00" }
--
-- Nobody has to speak for this to run. There is no message behind it, so
-- rubotty.text! and rubotty.author! answer nil, and rubotty.kind! says which
-- wake it was.

-- What this community has counted so far. Read only.
numbers = rubotty.community_stats!
people = numbers and numbers.members_active or 0

-- Recorded so tomorrow's digest can show a trend.
rubotty.increment_stat "digests", "posted"

{
  action: "allow"
  reply: rubotty.bold("Good morning.") .. " Active people lately: " .. tostring(people) .. "."
}
