# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Translation::Segmenter do
  include Builders

  let(:segmenter) { described_class.new }

  # A translator that reorders words, the way a real language pair often
  # does, so a round trip is not just append-only. Placeholders travel
  # wherever it puts them.
  def reorder(protected_text)
    protected_text.split(" ").reverse.join(" ")
  end

  describe "plain text with nothing to protect" do
    it "sends the text through unchanged and restores it verbatim" do
      protected_body = segmenter.protect(rich("hello there"))

      expect(protected_body.text).to eq("hello there")
      expect(protected_body).to be_translatable

      restored = segmenter.restore("ola ai", protected_body.placeholders)

      expect(restored.text).to eq("ola ai")
      expect(restored.spans).to be_empty
    end
  end

  describe "a URL" do
    it "keeps it out of what is sent, and puts it back verbatim wherever the translation put the marker" do
      body = rich("check out https://example.com/path?x=1 it's great")
      protected_body = segmenter.protect(body)

      expect(protected_body.text).not_to include("https://example.com")

      translated = reorder(protected_body.text)
      restored = segmenter.restore(translated, protected_body.placeholders)

      expect(restored.text).to include("https://example.com/path?x=1")
    end

    it "is not translatable on its own, a bare link with nothing else to say" do
      protected_body = segmenter.protect(rich("https://example.com/a"))

      expect(protected_body).not_to be_translatable
    end
  end

  describe "code" do
    it "protects a fenced block" do
      body = rich("run this:\n```\nputs 1\n```\nplease")
      protected_body = segmenter.protect(body)

      expect(protected_body.text).not_to include("puts 1")

      restored = segmenter.restore(reorder(protected_body.text), protected_body.placeholders)

      expect(restored.text).to include("puts 1")
    end

    it "protects inline code" do
      body = rich("set `debug = true` first")
      protected_body = segmenter.protect(body)

      expect(protected_body.text).not_to include("debug = true")

      restored = segmenter.restore(reorder(protected_body.text), protected_body.placeholders)

      expect(restored.text).to include("`debug = true`")
    end
  end

  describe "custom emoji" do
    it "protects a Discord style token" do
      body = rich("nice <a:party:123456789012345678> work")
      protected_body = segmenter.protect(body)

      expect(protected_body.text).not_to include("party:123456789012345678")

      restored = segmenter.restore(reorder(protected_body.text), protected_body.placeholders)

      expect(restored.text).to include("<a:party:123456789012345678>")
    end
  end

  describe "a mention" do
    it "keeps the span's attributes, moved to wherever the translation put the marker" do
      body = rich("ping @ada please", span(:mention, 5, 9, username: "ada", user_id: "42"))
      protected_body = segmenter.protect(body)
      token = protected_body.placeholders.first.token

      translated = "please #{token} first" # the target language moved the mention to a new position
      restored = segmenter.restore(translated, protected_body.placeholders)

      mention = restored.spans.find { |s| s.kind == :mention }
      expect(mention).not_to be_nil
      expect(restored.text[mention.begin_index...mention.end_index]).to eq("@ada")
      expect(mention.attributes[:user_id]).to eq("42")
    end
  end

  describe "several protected regions in one message" do
    it "restores every one of them at its own new position" do
      body = rich("see https://a.example and `code()` too")
      protected_body = segmenter.protect(body)

      expect(protected_body.placeholders.length).to eq(2)

      restored = segmenter.restore(reorder(protected_body.text), protected_body.placeholders)

      expect(restored.text).to include("https://a.example")
      expect(restored.text).to include("`code()`")
    end
  end

  describe "reconstruction safety" do
    it "returns nil when the translated text is missing a placeholder" do
      protected_body = segmenter.protect(rich("look at https://a.example now"))

      expect(segmenter.restore("a mangled answer with nothing kept", protected_body.placeholders)).to be_nil
    end

    it "returns nil when a placeholder appears twice and something else vanished" do
      body = rich("https://a.example and https://b.example")
      protected_body = segmenter.protect(body)
      token = protected_body.placeholders.first.token

      expect(segmenter.restore("#{token} #{token}", protected_body.placeholders)).to be_nil
    end
  end
end
