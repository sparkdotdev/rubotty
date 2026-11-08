-- Looks up the weather: /weather Lisbon.
-- trigger: command  { name = "weather" }
--
-- Posts twice: once to say it is asking, once when the answer arrives. The
-- call never blocks, so a slow service cannot hold up the room.

if rubotty.kind() == "http_callback" then
  -- The callback. response() is what came back and invocation_data() is
  -- whatever the first half passed through, both read once because a getter
  -- that answers a table hands back a fresh copy. ok is false for a refusal
  -- or a timeout, so this branch is what stops a dead endpoint being silence.
  local answer = rubotty.response()
  if not answer.ok or not answer.data then
    return "I could not reach the weather service just now."
  end
  return rubotty.bold(rubotty.invocation_data().city) .. ": " .. tostring(answer.data.summary)
end

local city = rubotty.args()
if city == "" then
  return "Usage: /weather <city>"
end

-- Call the endpoint, and wake this script with the answer.
rubotty.async_http({
  endpoint = "weather",
  query = { city = city },
  then_call = "weather",
  data = { city = city },
})

return "Asking about " .. city .. "..."
