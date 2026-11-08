# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Discord::Markdown do
  subject(:markdown) { described_class }

  def parse(source, resolver: nil)
    markdown.parse(source, resolver: resolver)
  end

  # Convenience: the covered text plus kind for each span.
  def spans_of(rich)
    rich.spans.map { |s| [s.kind, rich.text[s.begin_index...s.end_index]] }
  end

  describe "plain text" do
    it "passes prose through unchanged" do
      rich = parse("just some words")
      expect(rich.text).to eq("just some words")
      expect(rich.spans).to be_empty
    end

    it "returns empty rich text for nil and empty input" do
      expect(parse(nil).text).to eq("")
      expect(parse("").text).to eq("")
    end

    it "leaves snake_case identifiers alone" do
      rich = parse("call some_method_name now")
      expect(rich.text).to eq("call some_method_name now")
      expect(rich.spans).to be_empty
    end

    it "leaves arithmetic alone" do
      rich = parse("2 * 3 * 4")
      expect(rich.spans).to be_empty
    end
  end

  describe "emphasis" do
    it "parses bold" do
      rich = parse("a **bold** word")
      expect(rich.text).to eq("a bold word")
      expect(spans_of(rich)).to eq([[:bold, "bold"]])
    end

    it "parses italic with asterisks and with underscores" do
      expect(spans_of(parse("*one*"))).to eq([[:italic, "one"]])
      expect(spans_of(parse("_one_"))).to eq([[:italic, "one"]])
    end

    it "parses underline" do
      expect(spans_of(parse("__under__"))).to eq([[:underline, "under"]])
    end

    it "parses strikethrough" do
      expect(spans_of(parse("~~gone~~"))).to eq([[:strikethrough, "gone"]])
    end

    it "parses spoilers" do
      expect(spans_of(parse("||secret||"))).to eq([[:spoiler, "secret"]])
    end

    # Delimiter ordering: the whole reason PAIRED is not alphabetical.
    it "does not mistake bold for two italics" do
      expect(spans_of(parse("**x**"))).to eq([[:bold, "x"]])
    end

    it "does not mistake underline for two italics" do
      expect(spans_of(parse("__x__"))).to eq([[:underline, "x"]])
    end

    it "parses bold italic" do
      rich = parse("***both***")
      expect(rich.text).to eq("both")
      expect(rich.spans.map(&:kind)).to contain_exactly(:bold, :italic)
    end

    it "nests emphasis" do
      rich = parse("**bold and *italic* inside**")
      expect(rich.text).to eq("bold and italic inside")
      expect(spans_of(rich)).to contain_exactly(
        [:bold, "bold and italic inside"], [:italic, "italic"]
      )
    end

    it "does not let single character emphasis span a newline" do
      rich = parse("a *b\nc* d")
      expect(rich.spans).to be_empty
      expect(rich.text).to eq("a *b\nc* d")
    end

    it "treats an unmatched delimiter as literal" do
      rich = parse("half **open")
      expect(rich.text).to eq("half **open")
      expect(rich.spans).to be_empty
    end
  end

  describe "escapes" do
    it "makes an escaped asterisk literal" do
      rich = parse('not \\*italic\\* here')
      expect(rich.text).to eq("not *italic* here")
      expect(rich.spans).to be_empty
    end

    it "leaves a backslash before an ordinary character alone" do
      expect(parse('C:\\Users\\me').text).to eq('C:\\Users\\me')
    end
  end

  describe "code" do
    it "parses inline code" do
      expect(spans_of(parse("run `ls -la` now"))).to eq([[:code, "ls -la"]])
    end

    it "does not parse markup inside inline code" do
      rich = parse("`**not bold**`")
      expect(rich.text).to eq("**not bold**")
      expect(spans_of(rich)).to eq([[:code, "**not bold**"]])
    end

    it "parses a fenced block with a language" do
      rich = parse("```ruby\nputs 1\n```")
      expect(rich.text).to eq("puts 1")
      span = rich.spans.first
      expect(span.kind).to eq(:pre)
      expect(span.attributes[:language]).to eq("ruby")
    end

    it "parses a fenced block without a language" do
      rich = parse("```\nplain\n```")
      expect(rich.text).to eq("plain")
      expect(rich.spans.first.attributes[:language]).to be_nil
    end

    it "keeps newlines inside a fenced block" do
      expect(parse("```\na\nb\n```").text).to eq("a\nb")
    end

    it "treats an empty backtick pair as literal text" do
      expect(parse("a `` b").text).to eq("a `` b")
    end

    it "prefers a fenced block over inline code" do
      expect(parse("```\n`x`\n```").spans.first.kind).to eq(:pre)
    end
  end

  describe "links" do
    it "parses a masked link" do
      rich = parse("see [the docs](https://example.com/a)")
      expect(rich.text).to eq("see the docs")
      span = rich.spans.first
      expect(span.kind).to eq(:link)
      expect(span.attributes[:url]).to eq("https://example.com/a")
    end

    it "parses emphasis inside a link label" do
      rich = parse("[**bold** label](https://e.com)")
      expect(rich.text).to eq("bold label")
      expect(rich.spans.map(&:kind)).to contain_exactly(:link, :bold)
    end

    it "parses a bare URL" do
      rich = parse("go to https://example.com now")
      expect(spans_of(rich)).to eq([[:link, "https://example.com"]])
    end

    it "strips the angle brackets from a suppressed embed link" do
      rich = parse("<https://example.com>")
      expect(rich.text).to eq("https://example.com")
      expect(rich.spans.first.attributes[:url]).to eq("https://example.com")
    end

    it "handles a link target wrapped in angle brackets" do
      rich = parse("[x](<https://example.com/a(b)>)")
      expect(rich.spans.first.attributes[:url]).to eq("https://example.com/a(b)")
    end
  end

  describe "mentions and emoji" do
    let(:resolver) do
      lambda do |type, id|
        { %i[user 111].hash => "Ada" }
        case [type, id]
        in [:user, "111"] then "Ada"
        in [:role, "222"] then "admins"
        in [:channel, "333"] then "general"
        else nil
        end
      end
    end

    it "resolves a user mention to a display name" do
      rich = parse("hi <@111>", resolver: resolver)
      expect(rich.text).to eq("hi Ada")
      expect(rich.spans.first.kind).to eq(:mention)
      expect(rich.spans.first.attributes[:discord_id]).to eq("111")
    end

    it "resolves the nickname form with an exclamation mark" do
      expect(parse("hi <@!111>", resolver: resolver).text).to eq("hi Ada")
    end

    it "resolves a role mention" do
      expect(parse("<@&222>", resolver: resolver).text).to eq("admins")
    end

    it "renders a channel reference as plain text, not a mention" do
      rich = parse("see <#333>", resolver: resolver)
      expect(rich.text).to eq("see general")
      expect(rich.spans).to be_empty
    end

    it "falls back to an honest marker when a mention cannot be resolved" do
      expect(parse("<@999>").text).to eq("@unknown-user")
    end

    it "turns a custom emoji into its shortcode" do
      expect(parse("nice <:partyparrot:12345>").text).to eq("nice :partyparrot:")
    end

    it "handles an animated custom emoji" do
      expect(parse("<a:spin:999>").text).to eq(":spin:")
    end

    it "leaves a Discord timestamp alone, since nothing else can render it" do
      expect(parse("at <t:1700000000:F>").text).to eq("at <t:1700000000:F>")
    end

    it "removes the zero width space Discord inserts after an at sign" do
      expect(parse("@​everyone").text).to eq("@everyone")
    end
  end

  describe "block quotes" do
    it "parses a single quoted line" do
      rich = parse("> quoted")
      expect(rich.text).to eq("quoted")
      expect(rich.spans.map(&:kind)).to eq([:blockquote])
    end

    it "parses a multi line block quote" do
      rich = parse(">>> one\ntwo")
      expect(rich.text).to eq("one\ntwo")
      expect(rich.spans.map(&:kind)).to eq([:blockquote])
    end

    it "does not treat a partially quoted message as a quote" do
      rich = parse("> quoted\nnot quoted")
      expect(rich.text).to eq("> quoted\nnot quoted")
      expect(rich.spans).to be_empty
    end

    it "parses emphasis inside a quote" do
      rich = parse("> **shouted**")
      expect(rich.text).to eq("shouted")
      expect(rich.spans.map(&:kind)).to contain_exactly(:blockquote, :bold)
    end
  end

  describe "unsupported constructs" do
    it "leaves headings as literal text" do
      expect(parse("# Heading").text).to eq("# Heading")
    end

    it "leaves list markers as literal text" do
      expect(parse("- one\n- two").text).to eq("- one\n- two")
    end
  end

  describe "robustness" do
    it "does not exhaust the stack on deeply nested delimiters" do
      source = ("*" * 40) + "x" + ("*" * 40)
      expect { parse(source) }.not_to raise_error
    end

    it "handles emoji in the source without disturbing span offsets" do
      rich = parse("🎉 **party** time")
      span = rich.spans.first
      expect(rich.text[span.begin_index...span.end_index]).to eq("party")
    end

    it "handles an astral character inside an emphasised run" do
      rich = parse("**🎉 party**")
      span = rich.spans.first
      expect(rich.text[span.begin_index...span.end_index]).to eq("🎉 party")
    end
  end

  # Anything DiscordMarkdown renders should parse back to the same canonical form.
  describe "round trip through the renderer" do
    let(:renderer) { Rubotty::Rendering::DiscordMarkdown.new }

    [
      "plain words",
      "a **bold** word",
      "an *italic* word",
      "a ~~struck~~ word",
      "a ||spoiler|| word",
      "some `code` inline"
    ].each do |sample|
      it "round trips #{sample.inspect}" do
        first = markdown.parse(sample)
        second = markdown.parse(renderer.render(first))
        expect(second.text).to eq(first.text)
        expect(second.spans.map { |s| [s.kind, s.begin_index, s.end_index] })
          .to eq(first.spans.map { |s| [s.kind, s.begin_index, s.end_index] })
      end
    end
  end
end
