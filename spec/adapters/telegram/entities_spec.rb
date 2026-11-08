# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Telegram::Entities do
  subject(:entities) { described_class }

  def entity(type, offset, length, extra = {})
    { "type" => type, "offset" => offset, "length" => length }.merge(extra)
  end

  describe ".to_rich_text" do
    it "returns plain text when there are no entities" do
      rich = entities.to_rich_text("plain", nil)
      expect(rich.text).to eq("plain")
      expect(rich.spans).to be_empty
    end

    it "converts a simple bold entity" do
      rich = entities.to_rich_text("hello world", [entity("bold", 0, 5)])
      expect(rich.spans.map { |s| [s.kind, s.begin_index, s.end_index] }).to eq([[:bold, 0, 5]])
      expect(rich.text[0...5]).to eq("hello")
    end

    # The regression this whole module exists for.
    context "when the text contains an emoji before the formatted run" do
      let(:text) { "🎉 party time" }

      it "resolves the entity to the characters Telegram meant" do
        # Telegram counts UTF-16, so "party" is offset 3 length 5 even though
        # it starts at character index 2.
        rich = entities.to_rich_text(text, [entity("bold", 3, 5)])
        span = rich.spans.first
        expect(text[span.begin_index...span.end_index]).to eq("party")
      end

      it "would have been wrong under naive character slicing" do
        expect(text[3, 5]).to eq("arty ")
      end
    end

    it "handles several astral characters accumulating offset drift" do
      text = "🎉🎊 double 🎈 trouble"
      rich = entities.to_rich_text(text, [entity("italic", 15, 7)])
      span = rich.spans.first
      expect(text[span.begin_index...span.end_index]).to eq("trouble")
    end

    it "handles an entity that covers an emoji itself" do
      text = "wow 🎉 wow"
      # "🎉" is at character 4, UTF-16 offset 4, length 2 units.
      rich = entities.to_rich_text(text, [entity("bold", 4, 2)])
      span = rich.spans.first
      expect(text[span.begin_index...span.end_index]).to eq("🎉")
    end

    it "handles a ZWJ family sequence preceding the entity" do
      text = "👨‍👩‍👧‍👦 family"
      # The sequence is 11 UTF-16 units, then a space, so "family" starts at 12.
      rich = entities.to_rich_text(text, [entity("bold", 12, 6)])
      span = rich.spans.first
      expect(text[span.begin_index...span.end_index]).to eq("family")
    end

    it "keeps a text_link target" do
      rich = entities.to_rich_text("see docs", [entity("text_link", 4, 4, "url" => "https://example.com")])
      span = rich.spans.first
      expect(span.kind).to eq(:link)
      expect(span.attributes[:url]).to eq("https://example.com")
    end

    it "uses the covered text as the target of a bare url entity" do
      text = "go to https://example.com now"
      rich = entities.to_rich_text(text, [entity("url", 6, 19)])
      expect(rich.spans.first.attributes[:url]).to eq("https://example.com")
    end

    it "keeps the language of a pre entity" do
      rich = entities.to_rich_text("puts 1", [entity("pre", 0, 6, "language" => "ruby")])
      expect(rich.spans.first.attributes[:language]).to eq("ruby")
    end

    it "records the Telegram user id of a text_mention" do
      rich = entities.to_rich_text(
        "hi Ada", [entity("text_mention", 3, 3, "user" => { "id" => 42, "first_name" => "Ada" })]
      )
      span = rich.spans.first
      expect(span.kind).to eq(:mention)
      expect(span.attributes[:tg_user_id]).to eq("42")
    end

    it "records the handle of a plain mention" do
      rich = entities.to_rich_text("hi @ada", [entity("mention", 3, 4)])
      expect(rich.spans.first.attributes[:username]).to eq("ada")
    end

    it "ignores entity types that carry no formatting" do
      rich = entities.to_rich_text("/start now", [entity("bot_command", 0, 6)])
      expect(rich.spans).to be_empty
    end

    it "ignores a zero length entity" do
      expect(entities.to_rich_text("x", [entity("bold", 0, 0)]).spans).to be_empty
    end

    it "clips an entity that runs past the end of the text" do
      rich = entities.to_rich_text("abc", [entity("bold", 0, 99)])
      expect(rich.spans.first.end_index).to eq(3)
    end

    it "handles overlapping entities without dropping either" do
      rich = entities.to_rich_text("abcdef", [entity("bold", 0, 4), entity("italic", 2, 4)])
      expect(rich.spans.map(&:kind)).to contain_exactly(:bold, :italic)
    end
  end

  describe ".from_rich_text" do
    it "converts character offsets back into UTF-16 offsets" do
      text = "🎉 party time"
      rich = rich(text, span(:bold, 2, 7))
      converted = entities.from_rich_text(rich).first
      expect(converted["offset"]).to eq(3)
      expect(converted["length"]).to eq(5)
    end

    it "round trips well formed entities through to_rich_text" do
      text = "🎉🎊 double 🎈 trouble"
      original = [entity("bold", 15, 7), entity("italic", 5, 6)]
      rebuilt = entities.from_rich_text(entities.to_rich_text(text, original))
      expect(rebuilt.map { |e| [e["offset"], e["length"]] })
        .to contain_exactly([15, 7], [5, 6])
    end

    it "widens an entity whose offset lands inside a surrogate pair" do
      # Offset 3 is the low surrogate of the second emoji, so the span snaps out
      # to cover the whole character.
      text = "🎉🎊 double"
      rebuilt = entities.from_rich_text(entities.to_rich_text(text, [entity("bold", 3, 6)])).first
      expect(rebuilt["offset"]).to eq(2)
      expect(rebuilt["length"]).to eq(7)
    end

    it "carries a link target through" do
      converted = entities.from_rich_text(rich("docs", span(:link, 0, 4, url: "https://example.com"))).first
      expect(converted["type"]).to eq("text_link")
      expect(converted["url"]).to eq("https://example.com")
    end
  end
end
