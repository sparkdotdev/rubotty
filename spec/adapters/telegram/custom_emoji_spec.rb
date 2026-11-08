# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A reaction update names a custom emoji by id alone, and an id in a sentence reads as a
# fault. getCustomEmojiStickers answers with the sticker behind each id, and every sticker
# names the ordinary emoji it is drawn from.
RSpec.describe Rubotty::Adapters::Telegram::CustomEmoji do
  let(:calls) { [] }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }

  def sticker(id, emoji) = { "custom_emoji_id" => id, "emoji" => emoji }

  def resolver(&answer)
    described_class.new(
      stickers: lambda { |ids|
        calls << ids
        answer.call(ids)
      },
      logger: logger
    )
  end

  it "answers with the emoji each custom one is drawn from" do
    emoji = resolver { [sticker("1", "😄"), sticker("2", "🔥")] }
    expect(emoji.bases_for(%w[1 2])).to eq("1" => "😄", "2" => "🔥")
  end

  it "takes the whole batch in one call" do
    emoji = resolver { [sticker("1", "😄"), sticker("2", "🔥")] }
    emoji.bases_for(%w[1 2])
    expect(calls).to eq([%w[1 2]])
  end

  it "asks once for an id, since an id names one sticker for good" do
    emoji = resolver { [sticker("1", "😄")] }
    3.times { emoji.base_for("1") }
    expect(calls).to eq([["1"]])
  end

  it "asks only about the ids it has not heard of yet" do
    emoji = resolver { |ids| ids.map { |id| sticker(id, "😄") } }
    emoji.bases_for(["1"])
    emoji.bases_for(%w[1 2])
    expect(calls).to eq([["1"], ["2"]])
  end

  it "remembers that an id has no base emoji rather than asking again" do
    emoji = resolver { [] }
    expect(emoji.base_for("1")).to be_nil
    expect(emoji.base_for("1")).to be_nil
    expect(calls.size).to eq(1)
  end

  it "leaves a sticker carrying no emoji unresolved" do
    emoji = resolver { [sticker("1", "")] }
    expect(emoji.base_for("1")).to be_nil
  end

  # A network blip is not an answer, so writing it down would cost that emoji for the life
  # of the process.
  it "asks again after a call that failed" do
    emoji = resolver { raise Rubotty::AdapterError.new("Telegram is down", adapter: :telegram) }
    2.times { emoji.base_for("1") }
    expect(calls.size).to eq(2)
    expect(logs.string).to include("could not resolve a Telegram custom emoji")
  end

  it "splits a batch bigger than Telegram will take" do
    ids = (1..250).map(&:to_s)
    emoji = resolver { |batch| batch.map { |id| sticker(id, "😄") } }
    emoji.bases_for(ids)
    expect(calls.map(&:size)).to eq([200, 50])
  end

  it "asks nothing at all for an empty list" do
    emoji = resolver { [] }
    expect(emoji.bases_for([])).to be_empty
    expect(calls).to be_empty
  end

  it "ignores an answer that is not the shape the Bot API documents" do
    emoji = resolver { ["nonsense", { "emoji" => "😄" }] }
    expect(emoji.base_for("1")).to be_nil
  end
end
