-- Replaces swearing with something daft instead of deleting the message.
-- trigger: always
--
-- Named after the Company of Heroes 2 chat filter. It swaps words using the
-- room's own word list, and picks a replacement that fits the sentence, so a
-- noun becomes a noun. Slurs are removed rather than made funny.

-- Grouped by part of speech, so the sentence still parses. Swapping a verb for
-- a noun would produce word salad.
local SWAPS = {
  noun = { "pudding", "bicycle", "hedgehog", "kerfuffle", "trombone", "biscuit" },
  plural = { "puddings", "bicycles", "hedgehogs", "trombones", "biscuits" },
  verb = { "frolic", "yodel", "juggle", "bake" },
  gerund = { "frolicking", "yodelling", "juggling", "baking" },
  past = { "frolicked", "yodelled", "juggled", "baked" },
  adjective = { "delightful", "splendid", "fluffy", "marvellous" },
}

-- Match the shape of what was written, so a word that opened a sentence still
-- opens it with a capital.
local function like(original, replacement)
  local first = string.sub(original, 1, 1)
  if first ~= string.upper(first) then
    return replacement
  end
  return string.upper(string.sub(replacement, 1, 1)) .. string.sub(replacement, 2)
end

local text = rubotty.text()

-- Ask where the matches are, so we can cut them out ourselves.
local spans = rubotty.offending_spans(text)
if #spans == 0 then
  return { action = "allow" }
end

-- A slur is not funny, so it is removed rather than dressed up.
for _, span in ipairs(spans) do
  if span.category == "slur" then
    return { action = "reject", reason = "That word is not welcome here." }
  end
end

-- Right to left, because replacing a word moves every offset after it. The
-- offsets are bytes, which is what string.sub counts.
local out = text
for i = #spans, 1, -1 do
  local span = spans[i]
  local pool = SWAPS[span.part_of_speech] or SWAPS.noun
  local original = string.sub(out, span.from + 1, span.to)
  -- Ask rubotty for a random number, so a test can repeat it.
  local picked = pool[rubotty.random(1, #pool)]
  out = string.sub(out, 1, span.from) .. like(original, picked) .. string.sub(out, span.to + 1)
end

if out == text then
  return { action = "allow" }
end
return { action = "rewrite", text = out }
