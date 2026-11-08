-- Scores a first message on several spam signals at once.
-- trigger: new_voice  { window = 200 }
--
-- One signal on its own is usually innocent, so nothing happens until several fire.
class Score
  new: => @points = 0
  add: (condition, weight) =>
    @points += weight if condition
  over: (limit) => @points >= limit

text = string.lower rubotty.text!

score = Score!
score\add (string.find text, "https?://") != nil, 2
score\add (string.find text, "t%.me/") != nil, 3
score\add (string.find text, "airdrop") != nil, 3
score\add (string.len rubotty.text!) > 400, 1
score\add (string.find text, "dm me") != nil, 2

if score\over 4
  { action: "reject", reason: "That first message tripped several spam signals at once." }
else
  { action: "allow" }
