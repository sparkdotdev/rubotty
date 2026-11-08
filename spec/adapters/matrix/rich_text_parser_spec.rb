# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Matrix::RichTextParser do
  def parse(html) = described_class.parse(html)

  it "reads a bold span with the right offsets" do
    result = parse("hello <b>world</b>!")
    expect(result.text).to eq("hello world!")
    span = result.spans.first
    expect(span.kind).to eq(:bold)
    expect(result.text[span.begin_index...span.end_index]).to eq("world")
  end

  it "reads nested spans" do
    result = parse("<b>bold <i>and italic</i></b>")
    expect(result.text).to eq("bold and italic")
    expect(result.spans.map(&:kind)).to contain_exactly(:bold, :italic)
  end

  it "reads a link with its href as the url attribute" do
    result = parse('<a href="https://example.org">a link</a>')
    span = result.spans.first
    expect(span.kind).to eq(:link)
    expect(span.attributes[:url]).to eq("https://example.org")
  end

  it "carries no span for a link with no href" do
    result = parse("<a>a link</a>")
    expect(result.text).to eq("a link")
    expect(result.spans).to be_empty
  end

  describe "a matrix.to user permalink" do
    it "reads it as a mention span, not a link, carrying the Matrix id and localpart" do
      result = parse('<a href="https://matrix.to/#/@ada:example.org">Ada</a>')
      span = result.spans.first
      expect(span.kind).to eq(:mention)
      expect(span.attributes[:matrix_id]).to eq("@ada:example.org")
      expect(span.attributes[:username]).to eq("ada")
    end

    it "decodes a percent-encoded sigil the same way" do
      result = parse('<a href="https://matrix.to/#/%40ada%3Aexample.org">Ada</a>')
      expect(result.spans.first.attributes[:matrix_id]).to eq("@ada:example.org")
    end

    it "leaves a room permalink as an ordinary link" do
      result = parse('<a href="https://matrix.to/#/!room:example.org">the room</a>')
      expect(result.spans.first.kind).to eq(:link)
    end

    it "leaves an unrelated link as an ordinary link" do
      result = parse('<a href="https://example.org">a link</a>')
      expect(result.spans.first.kind).to eq(:link)
    end
  end

  it "reads a fenced pre block, keeping the language" do
    result = parse('<pre><code class="language-ruby">puts 1</code></pre>')
    span = result.spans.first
    expect(span.kind).to eq(:pre)
    expect(span.attributes[:language]).to eq("ruby")
    expect(result.text).to eq("puts 1")
  end

  it "reads a bare data-mx-spoiler span, which XML has no syntax for on its own" do
    result = parse("<span data-mx-spoiler>secret</span>")
    expect(result.spans.first.kind).to eq(:spoiler)
    expect(result.text).to eq("secret")
  end

  it "turns <br/> into a newline" do
    expect(parse("line1<br/>line2").text).to eq("line1\nline2")
  end

  it "drops the mx-reply quote wrapper, keeping the real reply text" do
    result = parse("<mx-reply><blockquote>the parent</blockquote></mx-reply>my reply")
    expect(result.text).to eq("my reply")
  end

  it "keeps the text of a tag it does not recognise, without a span for it" do
    result = parse("<marquee>retro</marquee> text")
    expect(result.text).to eq("retro text")
    expect(result.spans).to be_empty
  end

  it "decodes HTML entities" do
    expect(parse("&amp;&lt;&gt;").text).to eq("&<>")
  end

  it "returns nil for markup that is not well formed, so the caller falls back to plain text" do
    expect(parse("<b>unclosed")).to be_nil
  end

  it "repairs a bare ampersand rather than falling back to plain text over it" do
    expect(parse("Tom & Jerry").text).to eq("Tom & Jerry")
    expect(parse("<b>Fish & Chips</b>").text).to eq("Fish & Chips")
  end

  it "still decodes a real entity reference once a bare ampersand elsewhere is repaired" do
    expect(parse("Q & A: &amp;lt;").text).to eq("Q & A: &lt;")
  end

  it "repairs an unclosed <br>, <hr> or <img> the same way it already accepts the self-closed form" do
    expect(parse("line1<br>line2").text).to eq("line1\nline2")
    expect(parse('<img src="x.png">after').text).to eq("after")
    expect(parse("before<hr>after").text).to eq("beforeafter")
  end

  it "returns nil for a blank or absent body" do
    expect(parse("")).to be_nil
    expect(parse(nil)).to be_nil
  end
end
