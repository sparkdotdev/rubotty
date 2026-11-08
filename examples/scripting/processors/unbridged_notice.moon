-- Warns that a screenshot will not reach every platform.
-- trigger: contains  { words = {"screenshot", "see the image", "as attached"} }
--
-- Only says anything in a room that bridges IRC, which carries no images.

-- Ask which platforms this room is bridged to.
platforms = rubotty.platforms!

return { action: "allow" } if #platforms < 2

-- IRC carries no images, so a room bridging it is the case worth mentioning.
for platform in *platforms
  if platform == "irc"
    -- Post a message into this room, as the bot.
    rubotty.notify rubotty.italic "Heads up: this room bridges IRC, so images do not cross. Describe it in words too."
    return { action: "allow" }

{ action: "allow" }
