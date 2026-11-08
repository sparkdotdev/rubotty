-- Replaces swearing with something daft instead of deleting the message.
-- trigger: always
--
-- Named after the Company of Heroes 2 chat filter. It swaps words using the
-- room's own word list, and picks a replacement that fits the sentence, so a
-- noun becomes a noun. Slurs are removed rather than made funny.

-- Grouped by part of speech, so the sentence still parses. Swapping a verb for
-- a noun would produce word salad.
SWAPS =
  noun: { "pudding", "bicycle", "hedgehog", "kerfuffle", "trombone", "biscuit" }
  plural: { "puddings", "bicycles", "hedgehogs", "trombones", "biscuits" }
  verb: { "frolic", "yodel", "juggle", "bake" }
  gerund: { "frolicking", "yodelling", "juggling", "baking" }
  past: { "frolicked", "yodelled", "juggled", "baked" }
  adjective: { "delightful", "splendid", "fluffy", "marvellous" }

-- Match the shape of what was written, so a word that opened a sentence still
-- opens it with a capital.
like = (original, replacement) ->
  first = string.sub original, 1, 1
  return replacement if first != string.upper first
  string.upper(string.sub replacement, 1, 1) .. string.sub replacement, 2

text = rubotty.text!

-- Ask where the matches are, so we can cut them out ourselves.
spans = rubotty.offending_spans text
return { action: "allow" } if #spans == 0

-- A slur is not funny, so it is removed rather than dressed up.
for span in *spans
  if span.category == "slur"
    return { action: "reject", reason: "That word is not welcome here." }

-- Right to left, because replacing a word moves every offset after it. The
-- offsets are bytes, which is what string.sub counts.
out = text
for i = #spans, 1, -1
  span = spans[i]
  pool = SWAPS[span.part_of_speech] or SWAPS.noun
  original = string.sub out, span.from + 1, span.to
  -- Ask rubotty for a random number, so a test can repeat it.
  picked = pool[rubotty.random 1, #pool]
  out = string.sub(out, 1, span.from) .. like(original, picked) .. string.sub out, span.to + 1

if out == text then { action: "allow" } else { action: "rewrite", text: out }
