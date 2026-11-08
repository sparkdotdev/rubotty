# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "rest-client"

# BASE_INTENTS used to sit here as a dead fallback: Config::Schema fills
# @intents' default into resolved settings before this ever connects, so
# only Adapter::DEFAULT_INTENTS mattered. Neither list carried
# direct_message_reactions, so a reaction on a DM to the bot produced no gateway event.
RSpec.describe Rubotty::Adapters::Discord::Client do
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "warn", io: logs) }
  let(:intents) { nil }

  subject(:client) { described_class.new(token: "t", logger: logger, intents: intents) }

  describe "#intents_bitfield" do
    context "with an empty intents list" do
      let(:intents) { [] }

      it "still ORs in MESSAGE_CONTENT, the one intent that is never optional" do
        expect(client.intents_bitfield & described_class::MESSAGE_CONTENT_INTENT)
          .to eq(described_class::MESSAGE_CONTENT_INTENT)
      end

      it "still ORs in SCHEDULED_EVENTS, so a native Discord event is never invisible by default" do
        expect(client.intents_bitfield & described_class::SCHEDULED_EVENTS_INTENT)
          .to eq(described_class::SCHEDULED_EVENTS_INTENT)
      end

      # Config::Schema fills a field's default in for an ABSENT key only, so a
      # stored `intents: []` reaches the client intact. It used to resolve to
      # MESSAGE_CONTENT and SCHEDULED_EVENTS alone, neither of which delivers
      # a message, so the bot signed in and received nothing: one-directional bridging.
      it "falls back to the account default rather than subscribing to nothing" do
        expect(client.intents_bitfield)
          .to eq(described_class.new(token: "t", logger: logger,
                                     intents: Rubotty::Adapters::Discord::Adapter::DEFAULT_INTENTS)
                                .intents_bitfield)
      end

      it "says so, so a deaf gateway is never a silent one" do
        client.intents_bitfield

        expect(logs.string).to include("no Discord gateway intents configured")
      end
    end

    # Whatever the list says, the gateway has to be able to hear a message.
    context "with a list that names no receiving intent at all" do
      let(:intents) { %i[direct_messages] }

      it "still requests server_messages, without which no MESSAGE_CREATE ever arrives" do
        expect(client.intents_bitfield & Discordrb::INTENTS[:server_messages]).not_to eq(0)
      end

      it "still requests servers, without which no guild or channel is ever cached" do
        expect(client.intents_bitfield & Discordrb::INTENTS[:servers]).not_to eq(0)
      end

      it "keeps what the operator did ask for" do
        expect(client.intents_bitfield & Discordrb::INTENTS[:direct_messages]).not_to eq(0)
      end
    end

    context "with the account schema's own default" do
      let(:intents) { Rubotty::Adapters::Discord::Adapter::DEFAULT_INTENTS }

      # bit 13 per discordrb's own INTENTS map; this is the bit the gateway
      # never got asked for.
      it "requests direct_message_reactions, so a reaction on a DM reaches the gateway" do
        expect(client.intents_bitfield & Discordrb::INTENTS[:direct_message_reactions]).not_to eq(0)
      end

      it "requests direct_messages too, so a DM itself still reaches the gateway" do
        expect(client.intents_bitfield & Discordrb::INTENTS[:direct_messages]).not_to eq(0)
      end

      # Privileged; without it a join or leave never reaches the gateway at
      # all, which is what left Discord greetings dead.
      it "requests server_members, so a join or leave reaches the gateway" do
        expect(client.intents_bitfield & Discordrb::INTENTS[:server_members]).not_to eq(0)
      end
    end

    context "with an intent name discordrb does not recognise" do
      let(:intents) { %i[servers not_a_real_intent] }

      it "warns and ignores it rather than raising" do
        expect { client.intents_bitfield }.not_to raise_error
        expect(logs.string).to include("unknown Discord intent")
        expect(logs.string).to include("not_a_real_intent")
      end
    end

    context "with server_scheduled_events explicitly listed" do
      let(:intents) { %i[servers server_scheduled_events] }

      # discordrb's own INTENTS map has no entry for this name at all, the same
      # gap MESSAGE_CONTENT has; without the special case below it would warn
      # "unknown Discord intent" every boot despite being handled.
      it "does not warn, since it is handled the same way MESSAGE_CONTENT is" do
        client.intents_bitfield
        expect(logs.string).not_to include("unknown Discord intent")
      end
    end

    context "with intents left nil" do
      let(:intents) { nil }

      it "does not raise" do
        expect { client.intents_bitfield }.not_to raise_error
      end

      # This used to assert MESSAGE_CONTENT and SCHEDULED_EVENTS alone, which
      # is a gateway that connects and then never receives anything. Not
      # raising was the guarantee worth keeping; the value it settled on was
      # the bug.
      it "resolves to the account default rather than to a gateway that hears nothing" do
        expect(client.intents_bitfield & Discordrb::INTENTS[:server_messages]).not_to eq(0)
      end
    end
  end

  it "carries no BASE_INTENTS fallback any more: the account default is the only list" do
    expect(described_class.constants).not_to include(:BASE_INTENTS)
  end

  describe "#requested_privileged_intents" do
    it "always names message_content, forced regardless of what is configured" do
      expect(described_class.new(token: "t", logger: logger, intents: [:servers])
        .requested_privileged_intents).to eq([:message_content])
    end

    it "also names a configured privileged intent, alongside the forced one" do
      expect(described_class.new(token: "t", logger: logger, intents: [:server_members])
        .requested_privileged_intents).to contain_exactly(:message_content, :server_members)
    end
  end

  # discordrb only ever logs a rejected IDENTIFY (WS close code 4014); nothing
  # on Bot or Gateway reports it back to the caller. #connect prepends a
  # capture onto ::Discordrb::Gateway itself, so this exercises the real
  # discordrb classes rather than a stand-in for them.
  describe "a refused privileged intent" do
    subject(:client) { described_class.new(token: "test-bot-token", logger: logger) }

    before { client.connect }

    it "reads false before anything has closed" do
      expect(client.privileged_intent_rejected?).to be(false)
    end

    it "reads true once the gateway closes with Discord's own disabled-privileged-intents code" do
      client.bot.gateway.__send__(:handle_close, double("close_event", code: 4014, data: "disallowed intents"))

      expect(client.privileged_intent_rejected?).to be(true)
    end

    it "stays false for an unrelated fatal close code, like a bad token" do
      client.bot.gateway.__send__(:handle_close, double("close_event", code: 4004, data: "authentication failed"))

      expect(client.privileged_intent_rejected?).to be(false)
    end
  end

  # discordrb answers nil for a channel Discord no longer has, logging its own
  # "Unknown Channel" error on the way past. The history sweep meets a
  # deleted row as a matter of course, and calling straight through to
  # #history on that nil raised a NoMethodError that took the sweep with it.
  describe "a channel that is gone" do
    let(:absent_bot) do
      Class.new do
        def channel(_id) = nil
      end.new
    end

    before { client.instance_variable_set(:@bot, absent_bot) }

    it "skips the history read instead of raising" do
      expect(client.history("1427709346850275360", after_id: "0")).to eq([])
    end

    it "says which channel it skipped, so a stale row is findable rather than silent" do
      client.history("1427709346850275360", after_id: "0")

      expect(logs.string).to include("1427709346850275360")
      expect(logs.string).to include("gone")
    end

    it "skips a reaction read on it too, the other side of the same sweep" do
      expect(client.reactions("1427709346850275360", "99")).to eq([])
    end
  end

  # The guild membership seam. Everything above it works on neutral values, so
  # this is the only place the difference between "the guild has no channels"
  # and "the guild's channels could not be read" can be drawn.
  def with_bot(servers)
    client.instance_variable_set(:@bot, DiscordFakes::Gateway::Bot.new(servers))
    client
  end

  def server(**rest) = DiscordFakes::Gateway::Server.new(**rest)

  describe "#guild_text_channels" do
    it "lists a visible guild's channels" do
      channel = DiscordFakes::Gateway::Channel.new(id: "1", name: "general")
      with_bot("42" => server(id: "42", channels: [channel]))

      listing = client.guild_text_channels("42")

      expect(listing.listed?).to be(true)
      expect(listing.channels).to eq([{ id: "1", name: "general" }])
      expect(listing.channel_ids).to eq(["1"])
    end

    it "reports a genuinely empty guild as listed with no channels" do
      with_bot("42" => server(id: "42", channels: []))

      listing = client.guild_text_channels("42")

      expect(listing.listed?).to be(true)
      expect(listing.channels).to be_empty
    end

    # The dangerous case: the sweep at connect enumerates every guild at once,
    # which is exactly when Discord starts throttling.
    it "reports a rate limited enumeration as unavailable rather than empty" do
      with_bot("42" => server(id: "42", listing_error: RestClient::TooManyRequests.new))

      listing = client.guild_text_channels("42")

      expect(listing.unavailable?).to be(true)
      expect(listing.listed?).to be(false)
      expect(listing.channels).to be_empty
      expect(listing.reason).to include("TooManyRequests")
    end

    it "reports a refused enumeration as unavailable" do
      with_bot("42" => server(id: "42", listing_error: RuntimeError.new("missing access")))

      expect(client.guild_text_channels("42").unavailable?).to be(true)
    end

    it "reports a guild the cache cannot resolve as unavailable" do
      with_bot({})

      listing = client.guild_text_channels("42")

      expect(listing.unavailable?).to be(true)
      expect(listing.reason).to include("not visible")
    end

    it "reports an unconnected gateway as unavailable" do
      expect(client.guild_text_channels("42").unavailable?).to be(true)
    end
  end

  # Telegram, Stoat, Fluxer and Matrix all turn a 429 into RateLimitedError
  # carrying retry_after; this is Discord's turn.
  describe "#permission_or_adapter_error" do
    def too_many_requests(retry_after: nil)
      body = retry_after ? JSON.generate("retry_after" => retry_after) : nil
      response = Struct.new(:code, :body, :headers).new(429, body, {})
      RestClient::TooManyRequests.new(response)
    end

    it "turns a 429 into a RateLimitedError carrying Discord's own wait" do
      error = client.send(:permission_or_adapter_error, "do a thing", too_many_requests(retry_after: 2.2))
      expect(error).to be_a(Rubotty::RateLimitedError)
      expect(error.retry_after).to eq(3)
    end

    it "still answers a RateLimitedError with no body to read a wait from" do
      error = client.send(:permission_or_adapter_error, "do a thing", too_many_requests)
      expect(error).to be_a(Rubotty::RateLimitedError)
      expect(error.retry_after).to be_nil
    end

    it "still classifies a plain 403 as a PermissionError, unaffected by the 429 check" do
      error = client.send(:permission_or_adapter_error, "do a thing", RestClient::Forbidden.new)
      expect(error).to be_a(Rubotty::PermissionError)
    end

    it "falls back to a retryable AdapterError for anything else" do
      error = client.send(:permission_or_adapter_error, "do a thing", RuntimeError.new("boom"))
      expect(error).to be_a(Rubotty::AdapterError)
      expect(error).not_to be_a(Rubotty::RateLimitedError)
      expect(error.retryable?).to be(true)
    end
  end

  describe "#leave_server" do
    it "confirms a leave it actually issued" do
      guild = server(id: "42")
      with_bot("42" => guild)

      expect(client.leave_server("42")).to be(true)
      expect(guild.left?).to be(true)
    end

    # discordrb hands back nil for a guild it cannot resolve, and nothing raises,
    # so without this the adapter above would record a departure that never was.
    it "denies a leave for a guild it could not resolve" do
      with_bot({})

      expect(client.leave_server("42")).to be(false)
    end

    it "denies a leave with no gateway at all" do
      expect(client.leave_server("42")).to be(false)
    end

    it "lets a failing leave call raise, for the caller's own rescue" do
      with_bot("42" => server(id: "42", leave_error: RuntimeError.new("missing permission")))

      expect { client.leave_server("42") }.to raise_error(RuntimeError, /missing permission/)
    end
  end

  # The seam that feeds Interactions::User for a slash command: nickname and
  # display_name must land as two SEPARATE fields, neither one the
  # nickname-merged form discordrb's own Member#display_name returns (see
  # Interactions::User's own doc comment on why).
  describe "#build_user" do
    def call_build_user(user) = client.send(:build_user, user)

    it "returns nil for a nil user" do
      expect(call_build_user(nil)).to be_nil
    end

    it "carries a guild member's raw nickname separately from their pure global name" do
      member = Struct.new(:id, :username, :nick, :global_name).new("1", "sam", "Sammy", "Sam Global")

      user = call_build_user(member)

      expect(user.id).to eq("1")
      expect(user.username).to eq("sam")
      expect(user.nickname).to eq("Sammy")
      expect(user.display_name).to eq("Sam Global")
    end

    it "leaves nickname nil for a member with none set, rather than falling back to anything" do
      member = Struct.new(:id, :username, :nick, :global_name).new("1", "sam", nil, "Sam Global")

      expect(call_build_user(member).nickname).to be_nil
    end

    it "leaves nickname nil for a plain DM user, which has no #nick method at all" do
      dm_user = Struct.new(:id, :username, :global_name).new("1", "sam", "Sam Global")

      user = call_build_user(dm_user)
      expect(user.nickname).to be_nil
      expect(user.display_name).to eq("Sam Global")
    end

    it "falls back to #display_name when the object has no #global_name at all" do
      legacy = Struct.new(:id, :username, :display_name).new("1", "sam", "Sam Legacy")

      expect(call_build_user(legacy).display_name).to eq("Sam Legacy")
    end

    it "answers nil display_name when neither #global_name nor #display_name responds, leaving author_for's own username fallback to catch it" do
      bare = Struct.new(:id, :username).new("1", "sam")

      expect(call_build_user(bare).display_name).to be_nil
    end
  end
end
