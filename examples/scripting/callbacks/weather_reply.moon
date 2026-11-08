-- Posts a weather answer once it comes back.
-- trigger: always
--
-- A callback never runs because somebody spoke. Another script calls an
-- endpoint and names this one, and rubotty runs it when the reply arrives.

-- A getter that answers a table hands back a fresh copy every time, so read it
-- once and work from that rather than calling it on every line.
passed = rubotty.invocation_data!
answer = rubotty.response!

-- Nothing was passed, which is how the save check runs it. Guard, or the
-- script breaks the first time it is woken without data.
city = passed and passed.city or "there"

-- The call failed or timed out. Saying so beats silence.
unless answer and answer.ok
  return { action: "allow", reply: "I could not reach the weather service for " .. city .. "." }

summary = answer.data and answer.data.summary or "no idea, sorry"

-- Any action can carry a reply, and rubotty posts it into the room.
{ action: "allow", reply: rubotty.bold(city) .. ": " .. tostring(summary) }
