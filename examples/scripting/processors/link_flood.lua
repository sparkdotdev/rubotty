-- Stops somebody dumping links: three in the last ten messages.
-- trigger: recent_contains  { words = {"http://", "https://"}, window = 10, count = 3 }
--
-- Rubotty did the counting before the script ran. The script is only told that
-- it happened, never what the other messages were.
return {
  action = "reject",
  reason = "That is " .. rubotty.hits() .. " links in the last " .. rubotty.window() ..
           " messages. Give the room a moment before posting another.",
}
