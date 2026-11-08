-- Wakes an operator for a slur, and quietly notes ordinary swearing.
-- trigger: always  {}
--
-- Two problems arrive through the same filter and they are not the same size.
-- A slur is aimed at somebody and wants a person in the room tonight, so it is
-- loud: recorded on the alerts page and DMed to the operators. Swearing wants
-- writing down and nothing more, so it is quiet: recorded, and read whenever
-- somebody next opens the page.

-- Ask rubotty what the room's own filter makes of this, so the answer follows
-- whatever the operator configured rather than a list carried in here.
verdict = rubotty.classify rubotty.text!

if verdict == "slur"
  rubotty.alert "#{rubotty.author!} used a slur in #{rubotty.room_key!}.", "loud"
  return { action: "reject", reason: "Not here. An operator has been told." }

if verdict != "clean"
  rubotty.alert "#{rubotty.author!} tripped the word filter in #{rubotty.room_key!}."

{ action: "allow" }
