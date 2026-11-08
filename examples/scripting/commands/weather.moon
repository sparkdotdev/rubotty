-- Looks up the weather: /weather Lisbon.
-- trigger: command  { name = "weather" }
--
-- Posts twice: once to say it is asking, once when the answer arrives. The
-- call never blocks, so a slow service cannot hold up the room.

-- The callback. response! is what came back and invocation_data! is whatever
-- the first half passed through, both read once because a getter that
-- answers a table hands back a fresh copy. ok is false for a refusal or a
-- timeout, so this branch is what stops a dead endpoint being silence.
if rubotty.kind! == "http_callback"
  answer = rubotty.response!
  unless answer.ok and answer.data
    return "I could not reach the weather service just now."
  return "#{rubotty.bold rubotty.invocation_data!.city}: #{tostring answer.data.summary}"

city = rubotty.args!
return "Usage: /weather <city>" if city == ""

-- Call the endpoint, and wake this script with the answer.
rubotty.async_http
  endpoint: "weather"
  query: { city: city }
  then_call: "weather"
  data: { city: city }

"Asking about #{city}..."
