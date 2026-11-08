# frozen_string_literal: true

require "spec_helper"

# The bounded, per-endpoint memory a reply-less /delete uses to name its target:
# "my last message" and "the message that said X".
RSpec.describe Rubotty::Core::RecentMessages do
  subject(:recent) { described_class.new(limit: 3) }

  def add(endpoint, native_id, author, text)
    recent.record(endpoint_id: endpoint, native_id: native_id, author_id: author, text: text)
  end

  describe "#last_by" do
    it "returns the author's most recent message on that endpoint" do
      add("tg", "1", "ada", "first")
      add("tg", "2", "bob", "other")
      add("tg", "3", "ada", "second")

      expect(recent.last_by(endpoint_id: "tg", author_id: "ada").native_id).to eq("3")
    end

    it "is scoped per endpoint" do
      add("tg", "1", "ada", "here")
      expect(recent.last_by(endpoint_id: "dc", author_id: "ada")).to be_nil
    end

    it "is nil for an author who has said nothing, or a nil author" do
      add("tg", "1", "ada", "here")
      expect(recent.last_by(endpoint_id: "tg", author_id: "zoe")).to be_nil
      expect(recent.last_by(endpoint_id: "tg", author_id: nil)).to be_nil
    end
  end

  describe "#match_text" do
    it "finds the most recent message whose text matches exactly" do
      add("tg", "1", "ada", "spam")
      add("tg", "2", "bob", "spam")
      expect(recent.match_text(endpoint_id: "tg", text: "spam").native_id).to eq("2")
    end

    it "matches the whole text, not a substring, so a mod names one message" do
      add("tg", "1", "ada", "please stop spamming")
      expect(recent.match_text(endpoint_id: "tg", text: "spam")).to be_nil
    end

    it "is nil for a blank query" do
      add("tg", "1", "ada", "")
      expect(recent.match_text(endpoint_id: "tg", text: "  ")).to be_nil
    end
  end

  describe "bounding and recording" do
    it "keeps only the last #limit entries per endpoint" do
      add("tg", "1", "ada", "one")
      add("tg", "2", "ada", "two")
      add("tg", "3", "ada", "three")
      add("tg", "4", "ada", "four")

      expect(recent.match_text(endpoint_id: "tg", text: "one")).to be_nil
      expect(recent.last_by(endpoint_id: "tg", author_id: "ada").native_id).to eq("4")
    end

    it "ignores a message with no native id, which nothing could later delete" do
      expect(recent.record(endpoint_id: "tg", native_id: nil, author_id: "ada", text: "x")).to be_nil
      expect(recent.last_by(endpoint_id: "tg", author_id: "ada")).to be_nil
    end
  end

  # The run lookup redirection reads back when /end closes a window, where an
  # empty answer and no answer at all mean different things.
  describe "#between" do
    subject(:recent) { described_class.new(limit: 10) }

    it "returns the run from one end to the other, both included" do
      %w[1 2 3 4].each { |id| add("tg", id, "ada", "m#{id}") }

      run = recent.between(endpoint_id: "tg", from_native_id: "2", to_native_id: "4")

      expect(run.map(&:native_id)).to eq(%w[2 3 4])
    end

    it "answers with nothing rather than a subset when the first end has fallen off" do
      subject = described_class.new(limit: 2)
      %w[1 2 3].each do |id|
        subject.record(endpoint_id: "tg", native_id: id, author_id: "ada", text: "m#{id}")
      end

      expect(subject.between(endpoint_id: "tg", from_native_id: "1", to_native_id: "3")).to be_nil
    end

    it "answers with nothing when the far end is not there either" do
      add("tg", "1", "ada", "one")

      expect(recent.between(endpoint_id: "tg", from_native_id: "1", to_native_id: "9")).to be_nil
    end

    it "refuses a pair given the wrong way round rather than reading it as empty" do
      %w[1 2].each { |id| add("tg", id, "ada", "m#{id}") }

      expect(recent.between(endpoint_id: "tg", from_native_id: "2", to_native_id: "1")).to be_nil
    end

    it "never reaches across endpoints" do
      add("tg", "1", "ada", "one")
      add("dc", "2", "ada", "two")

      expect(recent.between(endpoint_id: "tg", from_native_id: "1", to_native_id: "2")).to be_nil
    end

    it "carries the styled body and the author's name, which a repost needs and a delete does not" do
      recent.record(endpoint_id: "tg", native_id: "1", author_id: "ada", text: "hi",
                    author_handle: "ada", author_name: "Ada L", body: rich("hi", span(:bold, 0, 2)))

      entry = recent.between(endpoint_id: "tg", from_native_id: "1", to_native_id: "1").first

      expect(entry.author_handle).to eq("ada")
      expect(entry.author_name).to eq("Ada L")
      expect(entry.body.spans.map(&:kind)).to eq([:bold])
    end
  end
end
