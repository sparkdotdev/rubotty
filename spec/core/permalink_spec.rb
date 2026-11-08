# frozen_string_literal: true

require "spec_helper"

# The inverse of an adapter's message_permalink. There was no way to read a
# link back at all, which is what stopped a member reporting a message by
# pasting one.
RSpec.describe Rubotty::Core::Permalink do
  describe ".parse" do
    it "reads a Telegram supergroup link back to the chat it names" do
      target = described_class.parse("https://t.me/c/1234567890/42")

      expect(target.adapter).to eq(:telegram)
      expect(target.settings).to eq(chat_id: "-1001234567890")
      expect(target.native_id).to eq("42")
    end

    # A forum topic sits between the chat and the message, the same order
    # message_permalink writes the pair in.
    it "reads the topic out of a forum link" do
      target = described_class.parse("https://t.me/c/1234567890/27/42")

      expect(target.settings).to eq(chat_id: "-1001234567890", thread_id: "27")
      expect(target.native_id).to eq("42")
    end

    it "reads a Discord link back to its guild and channel" do
      target = described_class.parse("https://discord.com/channels/111/222/333")

      expect(target.adapter).to eq(:discord)
      expect(target.settings).to eq(guild_id: "111", channel_id: "222")
      expect(target.native_id).to eq("333")
    end

    it "takes the older discordapp.com host too" do
      expect(described_class.parse("https://discordapp.com/channels/111/222/333").native_id).to eq("333")
    end

    it "reads a matrix.to link, unescaping the room and event" do
      target = described_class.parse("https://matrix.to/#/%21abc%3Aexample.org/%24evt?via=example.org")

      expect(target.adapter).to eq(:matrix)
      expect(target.settings).to eq(room_id: "!abc:example.org")
      expect(target.native_id).to eq("$evt")
    end

    it "is nil for anything that is not a message link" do
      expect(described_class.parse("not a link")).to be_nil
      expect(described_class.parse("")).to be_nil
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("https://t.me/c/123")).to be_nil
    end

    # A report has to name one message exactly, and guessing which of two links
    # in a paragraph was meant is worse than asking.
    it "takes only a whole link, not one mentioned inside a sentence" do
      expect(described_class.parse("see https://t.me/c/1234567890/42 here")).to be_nil
    end
  end

  describe ".endpoint_for" do
    let(:target) { described_class.parse("https://t.me/c/1234567890/42") }

    it "finds the endpoint whose settings the link names" do
      wanted = endpoint("tg-general", adapter: :telegram, settings: { chat_id: "-1001234567890" })
      other = endpoint("tg-other", adapter: :telegram, settings: { chat_id: "-1009999999999" })

      expect(described_class.endpoint_for(target, [other, wanted])).to eq(wanted)
    end

    # An endpoint merely sitting on the same account must never match another's
    # link, or a report would be filed against the wrong room.
    it "never matches an endpoint on a different chat" do
      other = endpoint("tg-other", adapter: :telegram, settings: { chat_id: "-1009999999999" })

      expect(described_class.endpoint_for(target, [other])).to be_nil
    end

    it "never matches the same chat id on another platform" do
      elsewhere = endpoint("dc", adapter: :discord, settings: { chat_id: "-1001234567890" })

      expect(described_class.endpoint_for(target, [elsewhere])).to be_nil
    end

    # A forum link names a topic as well, so the endpoint for the whole chat is
    # not the one it means.
    it "holds a forum link to the thread it names" do
      forum = described_class.parse("https://t.me/c/1234567890/27/42")
      whole = endpoint("tg-general", adapter: :telegram, settings: { chat_id: "-1001234567890" })
      topic = endpoint("tg-topic", adapter: :telegram,
                       settings: { chat_id: "-1001234567890", thread_id: "27" })

      expect(described_class.endpoint_for(forum, [whole, topic])).to eq(topic)
    end
  end
end
