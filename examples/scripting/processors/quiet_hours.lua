-- Nudges somebody to a thread when they are dominating the room.
-- trigger: author_repeat  { window = 10, count = 5 }
--
-- Says something and lets the message stand, which is usually the right call
-- for somebody who is just talkative.

local nudge = rubotty.author() .. ", you have sent " .. rubotty.count() ..
  " of the last " .. rubotty.window() ..
  " here. Worth taking it to a thread so the room can breathe?"

-- Post a message into this room, as the bot.
rubotty.notify(nudge)
return { action = "allow" }
