-- Says so when a rule cannot do its job, instead of failing quietly.
-- trigger: always
--
-- A script that depends on the word filter does nothing at all when the filter
-- is off, and nobody would know. This notices and tells the operators once.

-- Check whether a feature is switched on for this room.
return { action: "allow" } if rubotty.feature_enabled "word_filter"

-- Read back what we kept, or nil if it has gone.
unless rubotty.recall { key: "told-them" }
  -- Keep this until it expires.
  rubotty.remember { key: "told-them", value: true, ttl: 24 * 60 * 60 }
  -- Write a line to the bot log, for debugging.
  rubotty.log "the word filter is off in #{rubotty.room_key!}, so the swap rule is inert"
  -- Tell the operators, without the room seeing it.
  rubotty.alert "The word filter is off in #{rubotty.room_key!}, so scripts relying on it do nothing."

{ action: "allow" }
