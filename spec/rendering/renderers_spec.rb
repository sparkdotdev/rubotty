# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Rendering::TelegramHtml do
  subject(:renderer) { described_class.new }

  it "renders plain text unchanged" do
    expect(renderer.render(rich("hello"))).to eq("hello")
  end

  it "escapes the characters Telegram treats as markup" do
    expect(renderer.render(rich("a < b & c > d"))).to eq("a &lt; b &amp; c &gt; d")
  end

  it "wraps a bold span" do
    expect(renderer.render(rich("hello world", span(:bold, 0, 5)))).to eq("<b>hello</b> world")
  end

  it "nests properly nested spans" do
    result = renderer.render(rich("abcdef", span(:bold, 0, 6), span(:italic, 2, 4)))
    expect(result).to eq("<b>ab<i>cd</i>ef</b>")
  end

  # Telegram happily sends entities that overlap without nesting. Every markup
  # target needs well nested output, so the walker splits them.
  it "produces well nested output from overlapping spans" do
    result = renderer.render(rich("abcdef", span(:bold, 0, 4), span(:italic, 2, 6)))
    expect(result).to eq("<b>ab<i>cd</i></b><i>ef</i>")
  end

  it "renders a link with an escaped target" do
    result = renderer.render(rich("docs", span(:link, 0, 4, url: 'https://e.com/?a=1&b="2"')))
    expect(result).to eq(%(<a href="https://e.com/?a=1&amp;b=&quot;2&quot;">docs</a>))
  end

  it "renders a self labelled link as a bare URL, with no anchor" do
    url = "https://flighty.app/f/abc123"
    result = renderer.render(rich(url, span(:link, 0, url.length, url: url)))
    expect(result).to eq(url)
  end

  it "still wraps a link in an anchor when the label only differs by a trailing slash" do
    text = "https://flighty.app/f/abc123"
    url = "#{text}/"
    result = renderer.render(rich(text, span(:link, 0, text.length, url: url)))
    expect(result).to eq(%(<a href="#{url}">#{text}</a>))
  end

  it "renders a code block with its language" do
    result = renderer.render(rich("puts 1", span(:pre, 0, 6, language: "ruby")))
    expect(result).to eq(%(<pre><code class="language-ruby">puts 1</code></pre>))
  end

  it "does not apply formatting inside a code span" do
    result = renderer.render(rich("a*b*c", span(:code, 0, 5), span(:bold, 1, 4)))
    expect(result).to eq("<code>a*b*c</code>")
  end

  it "still escapes HTML inside a code span" do
    expect(renderer.render(rich("<b>", span(:code, 0, 3)))).to eq("<code>&lt;b&gt;</code>")
  end

  it "renders a spoiler" do
    expect(renderer.render(rich("shh", span(:spoiler, 0, 3)))).to eq("<tg-spoiler>shh</tg-spoiler>")
  end

  it "renders a mention as a link only when the Telegram user id is known" do
    known = renderer.render(rich("Ada", span(:mention, 0, 3, tg_user_id: "42")))
    unknown = renderer.render(rich("@ada", span(:mention, 0, 4, username: "ada")))
    expect(known).to eq(%(<a href="tg://user?id=42">Ada</a>))
    expect(unknown).to eq("@ada")
  end

  it "keeps spans attached to the right characters when emoji are present" do
    text = "🎉 party time"
    # Character offsets 2...7 are "party" regardless of UTF-16 arithmetic.
    expect(renderer.render(rich(text, span(:bold, 2, 7)))).to eq("🎉 <b>party</b> time")
  end
end

RSpec.describe Rubotty::Rendering::DiscordMarkdown do
  subject(:renderer) { described_class.new }

  it "escapes Discord markup characters in plain text" do
    expect(renderer.render(rich("a *b* c"))).to eq("a \\*b\\* c")
  end

  it "renders bold and italic" do
    expect(renderer.render(rich("hi", span(:bold, 0, 2)))).to eq("**hi**")
    expect(renderer.render(rich("hi", span(:italic, 0, 2)))).to eq("*hi*")
  end

  it "renders a link" do
    result = renderer.render(rich("docs", span(:link, 0, 4, url: "https://e.com/a(b)")))
    expect(result).to eq("[docs](https://e.com/a%28b%29)")
  end

  # A bare URL that Telegram auto-linked arrives with a link span whose label
  # is the URL itself. Bracketing it produces a self labelled masked link
  # that is redundant at best, so it renders as a plain URL instead.
  it "renders a self labelled link as a bare URL, with no brackets" do
    url = "https://flighty.app/f/abc123"
    result = renderer.render(rich(url, span(:link, 0, url.length, url: url)))
    expect(result).to eq(url)
  end

  it "still brackets a link when the label only differs by a trailing slash" do
    text = "https://flighty.app/f/abc123"
    url = "#{text}/"
    result = renderer.render(rich(text, span(:link, 0, text.length, url: url)))
    expect(result).to eq("[#{text}](#{url})")
  end

  it "renders a fenced code block" do
    result = renderer.render(rich("puts 1", span(:pre, 0, 6, language: "ruby")))
    expect(result).to eq("```ruby\nputs 1\n```")
  end

  it "does not escape inside a code span" do
    expect(renderer.render(rich("a*b", span(:code, 0, 3)))).to eq("`a*b`")
  end

  it "drops a span kind it cannot express rather than leaking markup" do
    # :mention is not in the supported set for this renderer.
    expect(renderer.render(rich("Ada", span(:mention, 0, 3, tg_user_id: "42")))).to eq("Ada")
  end

  # Fluxer and Stoat are Discord shaped and share this renderer, but each is
  # its own identity space in the router: a mention resolved for one of them
  # carries that platform's own `..._id_for_target` key, never Discord's.
  describe "mention_key, for a Discord shaped platform that is not Discord" do
    it "renders off the key it was built with, not Discord's own" do
      fluxer = described_class.new(mention_key: :fluxer_id_for_target)
      body = rich("hi Alex", span(:mention, 3, 7, fluxer_id_for_target: "900"))
      expect(fluxer.render(body)).to eq("hi <@900>")
    end

    it "leaves Discord's own key inert when built for a different platform" do
      fluxer = described_class.new(mention_key: :fluxer_id_for_target)
      body = rich("hi Alex", span(:mention, 3, 7, discord_id_for_target: "900"))
      expect(fluxer.render(body)).to eq("hi Alex")
    end

    it "defaults to Discord's own key with no argument" do
      body = rich("hi Alex", span(:mention, 3, 7, discord_id_for_target: "900"))
      expect(described_class.new.render(body)).to eq("hi <@900>")
    end
  end

  # Overlapping spans are where a delimiter-based target is weaker than a
  # tag-based one: closing italic then bold then reopening italic yields four
  # asterisks in a row, which Discord's parser may read either way. Recorded as
  # known behaviour rather than fixed, since the fix trades ambiguity for invisible characters.
  it "produces well nested output from overlapping spans" do
    result = renderer.render(rich("abcdef", span(:bold, 0, 4), span(:italic, 2, 6)))
    expect(result).to eq("**ab*cd****ef*")
  end
end

RSpec.describe Rubotty::Core::RichText do
  it "clips spans that run past the end of the text" do
    text = described_class.new("abc", [span(:bold, 0, 99)])
    expect(text.spans.first.end_index).to eq(3)
  end

  it "drops spans that are entirely out of range" do
    expect(described_class.new("abc", [span(:bold, 5, 9)]).spans).to be_empty
  end

  it "shifts span offsets when concatenated" do
    combined = described_class.plain("ab").concat(described_class.new("cd", [span(:bold, 0, 2)]))
    expect(combined.text).to eq("abcd")
    expect(combined.spans.first.begin_index).to eq(2)
  end

  it "truncates and trims spans" do
    truncated = described_class.new("abcdefghij", [span(:bold, 0, 10)]).truncate(5)
    expect(truncated.text).to eq("abcd…")
    expect(truncated.spans.first.end_index).to eq(4)
  end
end
