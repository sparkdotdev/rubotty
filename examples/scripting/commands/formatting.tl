-- Shows every style rubotty can render: /formatting.
-- trigger: command  { name = "formatting" }
--
-- These return ordinary text, so you can join and nest them freely. A
-- platform that cannot show a style just drops it.

local samples = {
  rubotty.bold("bold"),
  rubotty.italic("italic"),
  rubotty.underline("underline"),
  rubotty.strikethrough("strikethrough"),
  rubotty.spoiler("spoiler"),
  rubotty.code("inline code"),
  rubotty.blockquote("a quote"),
  -- format() applies several at once, in a stable order whatever order the
  -- table happened to be written in.
  rubotty.format("bold and italic", { bold = true, italic = true }),
  rubotty.pre("a code block"),
}

return table.concat(samples, "\n")
