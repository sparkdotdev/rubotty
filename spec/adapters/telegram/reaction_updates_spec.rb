# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A chat whose reactions are anonymous sends message_reaction_count INSTEAD of
# message_reaction, so a bot handling only the latter relays nothing at all from
# it. Every drop below also has to say why: working this out from the outside
# cost screenshots and a code read, and one log line answers it.
RSpec.describe Rubotty::Adapters::Telegram::Inbound do
  include Builders

  let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100111" }) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }
  let(:known) { ->(chat, _thread) { chat.to_s == "-100111" ? place : nil } }

  subject(:inbound) { described_class.new(endpoint_for: known, logger: logger) }

  def count_update(reactions, chat: -100_111, message_id: 700)
    inbound.call(
      "update_id" => 3,
      "message_reaction_count" => {
        "chat" => { "id" => chat },
        "message_id" => message_id,
        "date" => 1_700_000_100,
        "reactions" => reactions
      }
    )
  end

  def emoji_count(emoji, total)
    { "type" => { "type" => "emoji", "emoji" => emoji }, "total_count" => total }
  end

  describe "a count-only update" do
    it "produces one message carrying the whole counted set" do
      message = count_update([emoji_count("🤣", 3), emoji_count("🤔", 1)])
      expect(message.kind).to eq(:reaction_sync)
      expect(message.reaction_set.map(&:emoji)).to eq(%w[🤣 🤔])
    end

    it "points at the message that was reacted to, on the endpoint it arrived on" do
      message = count_update([emoji_count("🤣", 1)])
      expect(message.ref.to_a).to eq(%w[tg 700])
    end

    it "attributes nobody, there being nobody named in the payload" do
      message = count_update([emoji_count("🤣", 1)])
      expect(message.author.native_id).to be_nil
      expect(message.reaction).to be_nil
    end

    it "leaves out an emoji nobody holds any more" do
      message = count_update([emoji_count("🤣", 2), emoji_count("🤔", 0)])
      expect(message.reaction_set.map(&:emoji)).to eq(["🤣"])
    end

    it "reads a custom emoji count as a custom reaction" do
      message = count_update(
        [{ "type" => { "type" => "custom_emoji", "custom_emoji_id" => "c1" }, "total_count" => 1 }]
      )
      expect(message.reaction_set.first.custom_id).to eq("c1")
    end

    it "carries an empty set when the last reaction is taken off" do
      expect(count_update([]).reaction_set).to be_empty
    end

    it "says which chat it dropped one for, and that it had no topic to look under" do
      expect(count_update([emoji_count("🤣", 1)], chat: -100_999)).to be_nil
      expect(logs.string).to include("-100999")
      expect(logs.string).to include("the update names no topic")
      expect(logs.string).to include("-100999/<topic>")
    end
  end

  describe "a per-person update that names nobody" do
    def anonymous_reaction
      inbound.call(
        "update_id" => 4,
        "message_reaction" => {
          "chat" => { "id" => -100_111 },
          "message_id" => 701,
          "actor_chat" => { "id" => -100_111, "title" => "The Group" },
          "date" => 1_700_000_100,
          "old_reaction" => [],
          "new_reaction" => [{ "type" => "emoji", "emoji" => "🤣" }]
        }
      )
    end

    # One chat id can stand for several anonymous admins, so there is no holder
    # to add to or take away from and the aggregate has nothing to record.
    it "is still dropped" do
      expect(anonymous_reaction).to be_nil
    end

    it "warns, since nothing else will ever carry that reaction" do
      anonymous_reaction
      expect(logs.string).to include("WARN")
      expect(logs.string).to include("names no holder to count")
      expect(logs.string).to include("tg:701")
    end
  end

  it "says which chat it dropped a reaction for when nothing is bridged to it" do
    result = inbound.call(
      "update_id" => 5,
      "message_reaction" => {
        "chat" => { "id" => -100_999 },
        "message_id" => 702,
        "user" => { "id" => 55, "first_name" => "Alex" },
        "old_reaction" => [],
        "new_reaction" => [{ "type" => "emoji", "emoji" => "🤣" }]
      }
    )
    expect(result).to be_nil
    expect(logs.string).to include("-100999")
    expect(logs.string).to include("the update names no topic")
    expect(logs.string).to include("-100999/<topic>")
  end

  # A premium user's custom emoji crossed as its raw id, since a reaction update
  # carries the id and nothing else. getCustomEmojiStickers names the emoji underneath it.
  describe "a custom emoji reaction" do
    let(:asked) { [] }
    let(:resolver) do
      lambda do |ids|
        asked << ids
        { "5373015670822804395" => "😄" }
      end
    end

    subject(:inbound) do
      described_class.new(endpoint_for: known, custom_emoji_resolver: resolver, logger: logger)
    end

    def custom_reaction(id, old: [])
      inbound.call(
        "update_id" => 7,
        "message_reaction" => {
          "chat" => { "id" => -100_111 },
          "message_id" => 704,
          "user" => { "id" => 55, "first_name" => "Alex" },
          "old_reaction" => old,
          "new_reaction" => [{ "type" => "custom_emoji", "custom_emoji_id" => id }]
        }
      )
    end

    it "carries the emoji the custom one is drawn from, so it reads as a smile" do
      reaction = custom_reaction("5373015670822804395").first.reaction
      expect(reaction.label).to eq("😄")
      expect(reaction.base_emoji).to eq("😄")
    end

    it "keeps the id as the identity, so the aggregate still tells two of them apart" do
      expect(custom_reaction("5373015670822804395").first.reaction.key)
        .to eq("custom:5373015670822804395")
    end

    it "asks about the old and the new list together, one call for the update" do
      custom_reaction("5373015670822804395",
                      old: [{ "type" => "custom_emoji", "custom_emoji_id" => "111" }])
      expect(asked).to eq([%w[111 5373015670822804395]])
    end

    it "names it in words when the lookup answers for nothing" do
      answered = described_class.new(endpoint_for: known, custom_emoji_resolver: ->(_ids) { {} })
      produced = answered.call(
        "update_id" => 8,
        "message_reaction" => {
          "chat" => { "id" => -100_111 }, "message_id" => 705,
          "user" => { "id" => 55, "first_name" => "Alex" },
          "old_reaction" => [],
          "new_reaction" => [{ "type" => "custom_emoji", "custom_emoji_id" => "5373015670822804395" }]
        }
      )
      expect(produced.first.reaction.label).to eq("a custom emoji")
    end

    it "reads a count of custom emoji through the same lookup" do
      message = count_update(
        [{ "type" => { "type" => "custom_emoji", "custom_emoji_id" => "5373015670822804395" },
           "total_count" => 2 }]
      )
      expect(message.reaction_set.first.label).to eq("😄")
    end

    it "crosses the reaction anyway when the lookup itself raises" do
      angry = described_class.new(endpoint_for: known, logger: logger,
                                  custom_emoji_resolver: ->(_ids) { raise "Telegram is down" })
      produced = angry.call(
        "update_id" => 9,
        "message_reaction" => {
          "chat" => { "id" => -100_111 }, "message_id" => 706,
          "user" => { "id" => 55, "first_name" => "Alex" },
          "old_reaction" => [],
          "new_reaction" => [{ "type" => "custom_emoji", "custom_emoji_id" => "42" }]
        }
      )
      expect(produced.first.reaction.custom_id).to eq("42")
      expect(logs.string).to include("could not resolve a Telegram custom emoji")
    end
  end

  # An ordinary message used to vanish from an unmapped chat with nothing
  # logged, while a reaction to the same chat said why.
  it "says which chat it dropped an ordinary message for when nothing is bridged to it" do
    result = inbound.call(
      "update_id" => 7,
      "message" => {
        "message_id" => 704, "date" => 1_700_000_100,
        "chat" => { "id" => -100_999 },
        "from" => { "id" => 55, "first_name" => "Alex" },
        "text" => "hello"
      }
    )
    expect(result).to be_nil
    expect(logs.string).to include("-100999")
  end

  it "distinguishes a topic that resolved to nothing from a whole chat nobody has mapped" do
    result = inbound.call(
      "update_id" => 8,
      "message" => {
        "message_id" => 705, "date" => 1_700_000_100, "message_thread_id" => 42,
        "chat" => { "id" => -100_999, "type" => "supergroup", "is_forum" => true },
        "from" => { "id" => 55, "first_name" => "Alex" },
        "text" => "hello"
      }
    )
    expect(result).to be_nil
    expect(logs.string).to include("-100999/42")
  end

  it "leaves an attributed reaction exactly as it was" do
    produced = inbound.call(
      "update_id" => 6,
      "message_reaction" => {
        "chat" => { "id" => -100_111 },
        "message_id" => 703,
        "user" => { "id" => 55, "first_name" => "Alex" },
        "old_reaction" => [],
        "new_reaction" => [{ "type" => "emoji", "emoji" => "🤣" }]
      }
    )
    expect(produced.map(&:kind)).to eq([:reaction_add])
    expect(produced.first.author.native_id).to eq("55")
  end
end
