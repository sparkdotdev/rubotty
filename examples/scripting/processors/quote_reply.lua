-- Quotes a question back with a pointer to the pinned guide.
-- trigger: contains  { words = {"how do i", "how do you"} }
--
-- Always clean member text before putting it inside a styled reply, or
-- somebody can paste characters that change how your message renders.

-- Post a message into this room, as the bot.
rubotty.notify(
  -- Clean member text before putting it in a styled reply.
  rubotty.blockquote(rubotty.escape(rubotty.text())) ..
  "\n" .. rubotty.bold("Try the pinned guide first, then ask again if it is still unclear.")
)
return { action = "allow" }
