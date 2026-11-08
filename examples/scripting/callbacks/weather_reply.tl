-- Posts a weather answer once it comes back.
-- trigger: always
--
-- A callback never runs because somebody spoke. Another script calls an
-- endpoint and names this one, and rubotty runs it when the reply arrives.

-- A getter that answers a table hands back a fresh copy every time, so read it
-- once and work from that rather than calling it on every line.
local passed = rubotty.invocation_data()
local answer = rubotty.response()

-- Nothing was passed, which is how the save check runs it. Guard, or the
-- script breaks the first time it is woken without data.
local city: string = "there"
if passed ~= nil and passed.city ~= nil then
  city = passed.city as string
end

-- The call failed or timed out. Saying so beats silence.
if answer == nil or not answer.ok then
  return { action = "allow", reply = "I could not reach the weather service for " .. city .. "." } as Verdict
end

local summary: string = "no idea, sorry"
if answer.data ~= nil and answer.data.summary ~= nil then
  summary = answer.data.summary as string
end

-- Any action can carry a reply, and rubotty posts it into the room.
return { action = "allow", reply = rubotty.bold(city) .. ": " .. summary } as Verdict
