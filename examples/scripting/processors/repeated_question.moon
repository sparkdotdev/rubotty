-- Points at the FAQ when the same question keeps coming up.
-- trigger: recent_contains  { words = {"visa", "d7", "d8", "ari"}, window = 30, count = 3 }
--
-- Lets the question through and adds a pointer, rather than removing it.
matched = rubotty.matched! or { "it" }
-- Post a message into this room, as the bot.
rubotty.notify "This comes up a lot. The pinned FAQ in #welcome covers #{table.concat matched, ', '}."
{ action: "allow" }
