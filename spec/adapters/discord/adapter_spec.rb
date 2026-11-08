# frozen_string_literal: true

require "spec_helper"
require "rest-client"

RSpec.describe Rubotty::Adapters::Discord::Adapter do
  let(:client) { DiscordFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  # This file covers bot posting; the webhook path has its own file.
  let(:general) do
    endpoint("dc-general", adapter: :discord,
                           settings: { channel_id: "8000000000000000003", webhook: :off })
  end

  subject(:adapter) do
    described_class.new(
      account: "dc",
      settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: [general]
    ).replace_client(client)
  end

  let(:channel) { client.channel("8000000000000000003") }
  let(:ada) { DiscordFakes.user(id: "55", username: "ada", global_name: "Ada L") }

  describe "guild lookup for a channel" do
    it "answers the gateway's known immutable guild id" do
      channel.server = DiscordFakes::Server.new(id: "guild-known", name: "Example Guild")
      expect(adapter.guild_id_for_channel(channel.id)).to eq("guild-known")
    end

    it "returns no guild when the channel cannot be read" do
      allow(client).to receive(:channel).with("unavailable").and_raise(StandardError, "gateway unavailable")
      expect(adapter.guild_id_for_channel("unavailable")).to be_nil
    end

    it "does not guess a guild without a channel id or a cached server" do
      expect(adapter.guild_id_for_channel(nil)).to be_nil
      channel.server = nil
      expect(adapter.guild_id_for_channel(channel.id)).to be_nil
    end
  end

  describe "message permalinks" do
    it "builds a canonical link when the mapped endpoint knows its guild and channel" do
      linked = endpoint("dc-linked", adapter: :discord,
                        settings: { guild_id: "42", channel_id: "8000000000000000003" })

      expect(adapter.message_permalink(linked, "987")).to eq("https://discord.com/channels/42/8000000000000000003/987")
    end

    it "does not guess a link for an endpoint without its guild" do
      expect(adapter.message_permalink(general, "987")).to be_nil
    end

    it "links the channel itself, for a notice that names a room" do
      linked = endpoint("dc-linked", adapter: :discord,
                        settings: { guild_id: "42", channel_id: "8000000000000000003" })

      expect(adapter.room_permalink(linked)).to eq("https://discord.com/channels/42/8000000000000000003")
      expect(adapter.room_permalink(general)).to be_nil
    end
  end

  def incoming(content: "hello", **rest)
    DiscordFakes::MessageEvent.new(
      message: DiscordFakes::Message.new(id: "700", content: content, author: ada, **rest),
      channel: channel
    )
  end

  describe "startup" do
    it "learns its own account id, which loop prevention depends on" do
      adapter.start
      expect(adapter.own_account_id).to eq("bot-discord")
    end

    it "refuses to start if it cannot learn its own id" do
      allow(client).to receive(:own_id).and_return(nil)
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /loop prevention/)
    end

    # Tonight's outage: discordrb's own REST fallback for #profile still
    # resolves a real user id even when the gateway IDENTIFY was refused, so
    # #own_id alone would let the adapter start looking connected while deaf.
    it "refuses to start, naming the intent, when Discord refuses a privileged intent" do
      client.reject_privileged_intents!(:message_content)

      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /message_content.*developer portal/m)
    end

    it "surfaces as unhealthy, with the rejection's own reason, rather than reading as connected" do
      client.reject_privileged_intents!(:message_content)
      health = Rubotty::Core::AdapterHealth.new
      key = %i[discord dc]

      begin
        adapter.start
      rescue Rubotty::AdapterError => e
        health.record_error(key, e)
      end

      expect(health.healthy?(key)).to be(false)
      expect(health.recent_failures.first[:message]).to match(/message_content/)
    end

    # AdapterError keeps a start failure inside the runtime's per adapter rescue,
    # so one platform cannot crash loop the whole process.
    it "converts an unexpected start failure into an AdapterError" do
      allow(client).to receive(:connect).and_raise(RuntimeError.new("gateway boom"))
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /failed to start.*gateway boom/)
    end

    # One account is one bot token, so a missing one means "not yet connected"
    # rather than a fatal boot error.
    it "opts into graceful dormancy when its token is absent" do
      expect(described_class.dormant_on_missing_secret?).to be(true)
    end

    # Runtime#start joins every adapter's start thread before it resolves.
    # Slash registration sits under Discord's application-command rate
    # limit, which waits about twenty seconds per call, so it must not run
    # on this thread or it would hold up start until every command registered.
    it "does not wait for slash registration before returning" do
      gate = Thread::Queue.new
      allow(client).to receive(:register_application_command) { gate.pop }
      done = Thread::Queue.new

      Thread.new do
        adapter.start
        done.push(:started)
      end

      expect(done.pop(timeout: 5)).to eq(:started)
    ensure
      adapter.stop
      gate&.close
    end

    it "still registers the commands, on its own thread" do
      stub_const("#{described_class}::SLASH_GUILDS_WAIT_SECONDS", 0.05)
      stub_const("#{described_class}::SLASH_GUILDS_WAIT_POLL_INTERVAL", 0.01)
      adapter.start
      adapter.instance_variable_get(:@slash_registration)&.join(5)

      expect(client.registered_commands).not_to be_empty
    end

    it "abandons a registration still waiting on the rate limiter when it is stopped" do
      gate = Thread::Queue.new
      allow(client).to receive(:register_application_command) { gate.pop }
      adapter.start
      registration = adapter.instance_variable_get(:@slash_registration)

      adapter.stop

      expect(registration).not_to be_alive
    ensure
      gate&.close
    end
  end

  # A control-plane deployment configures no endpoints in YAML: they live in
  # the database instead. Reading only the static list therefore answers "no
  # guilds", which sends Interactions#register_commands down its rate-limited
  # GLOBAL path instead of the cheaper per-guild one.
  describe "slash command registration in a control-plane deployment" do
    let(:live) do
      endpoint("dc-live", adapter: :discord, settings: { channel_id: "8000000000000000003" })
    end
    let(:resolver) do
      instance_double(Rubotty::ControlPlane::ChannelResolver,
                      endpoints_for: [["8000000000000000003", live]])
    end
    let(:resolved_adapter) do
      described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
        endpoint_resolver: resolver
      ).replace_client(client)
    end

    before do
      client.channel("8000000000000000003").server =
        DiscordFakes::Server.new(id: "guild-live", name: "Live Guild")
    end

    it "finds the guild through the resolver, with nothing configured in YAML" do
      expect(resolved_adapter.send(:every_known_guild_id)).to eq(["guild-live"])
    end

    it "registers per guild rather than globally, which is the path the rate limiter punishes" do
      resolved_adapter.start
      resolved_adapter.instance_variable_get(:@slash_registration)&.join(5)

      expect(client.registered_commands).not_to be_empty
      expect(client.registered_commands.map { |entry| entry[:guild_id] }.uniq).to eq(["guild-live"])
    end
  end

  # known_guild_ids depends on the gateway's channel-to-guild cache, which is
  # not always warm the instant #start's thread runs it. A merely cold cache
  # used to read exactly like "no guild", silently sending registration down
  # Discord's slow, hour-cached global path with nothing in the log to say so.
  describe "slash command registration determinism against a cold gateway cache" do
    let(:live) do
      endpoint("dc-live", adapter: :discord, settings: { channel_id: "8000000000000000003" })
    end
    let(:resolver) do
      instance_double(Rubotty::ControlPlane::ChannelResolver,
                      endpoints_for: [["8000000000000000003", live]])
    end
    let(:logs) { StringIO.new }
    let(:logged_adapter) do
      described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.build(level: "info", io: logs), endpoints: [],
        endpoint_resolver: resolver
      ).replace_client(client)
    end

    before do
      stub_const("#{described_class}::SLASH_GUILDS_WAIT_SECONDS", 0.3)
      stub_const("#{described_class}::SLASH_GUILDS_WAIT_POLL_INTERVAL", 0.02)
    end

    it "waits out a cache that warms up shortly after start rather than registering globally" do
      Thread.new do
        sleep 0.05
        client.channel("8000000000000000003").server =
          DiscordFakes::Server.new(id: "guild-live", name: "Live Guild")
      end

      logged_adapter.start
      logged_adapter.instance_variable_get(:@slash_registration)&.join(5)

      expect(client.registered_commands).not_to be_empty
      expect(client.registered_commands.map { |entry| entry[:guild_id] }.uniq).to eq(["guild-live"])
    end

    it "still falls back to a global registration once the bounded wait elapses for a guild that never resolves" do
      logged_adapter.start
      logged_adapter.instance_variable_get(:@slash_registration)&.join(5)

      expect(client.registered_commands).not_to be_empty
      expect(client.registered_commands.map { |entry| entry[:guild_id] }.uniq).to eq([nil])
    end

    it "logs the per-guild path and how many commands went out once the guild is known" do
      client.channel("8000000000000000003").server =
        DiscordFakes::Server.new(id: "guild-live", name: "Live Guild")

      logged_adapter.start
      logged_adapter.instance_variable_get(:@slash_registration)&.join(5)

      command_count = logged_adapter.interactions.definitions.size
      expect(logs.string).to include(
        "registering #{command_count} slash command(s) in each of 1 guild(s) (guild-live)"
      )
    end

    it "logs the global path, distinguishing it from a per-guild registration, when no guild is ever known" do
      logged_adapter.start
      logged_adapter.instance_variable_get(:@slash_registration)&.join(5)

      command_count = logged_adapter.interactions.definitions.size
      expect(logs.string).to include(
        "registering #{command_count} slash command(s) globally, no guild known"
      )
    end
  end

  describe "backfill" do
    it "reports that Discord can reconstruct history" do
      expect(adapter.supports_backfill?).to be(true)
    end

    it "reconstructs canonical messages from channel history, oldest first" do
      first = DiscordFakes::Message.new(id: "100", content: "first", author: ada, timestamp: Time.now - 120)
      second = DiscordFakes::Message.new(id: "200", content: "second", author: ada, timestamp: Time.now - 60)
      [first, second].each { |message| message.channel = channel }
      allow(client).to receive(:history).and_return([first, second])

      messages = adapter.backfill_messages(general, since: Time.now - 3600)

      expect(messages.map { |message| message.ref.native_id }).to eq(%w[100 200])
      expect(messages.map { |message| message.body.text }).to eq(["first", "second"])
      expect(messages).to all(have_attributes(kind: :chat, origin: general))
    end

    it "asks history for messages after the since instant as a snowflake boundary" do
      allow(client).to receive(:history).and_return([])
      adapter.backfill_messages(general, since: Time.at(1_600_000_000))
      expect(client).to have_received(:history).with(
        "8000000000000000003", after_id: kind_of(String), limit: 100
      )
    end

    it "reports that Discord can reconstruct history reactions" do
      expect(adapter.supports_reaction_backfill?).to be(true)
    end

    it "reports that it can answer gap ownership questions" do
      expect(adapter.supports_gap_ownership?).to be(true)
    end

    it "pairs each backfill candidate with its ownership answer, dropping nothing" do
      channel.existing_webhooks = [DiscordFakes::Hook.new(id: "555", name: "rubotty", token: "t")]
      stranger = DiscordFakes::Message.new(id: "100", content: "hi", author: ada, timestamp: Time.now - 120)
      echo = DiscordFakes::Message.new(id: "200", content: "echo", author: ada,
                                       timestamp: Time.now - 60, webhook_id: "555")
      [stranger, echo].each { |message| message.channel = channel }
      allow(client).to receive(:history).and_return([stranger, echo])

      pairs = adapter.backfill_candidates(general, since: Time.now - 3600)

      expect(pairs.map { |message, _ownership| message.ref.native_id }).to eq(%w[100 200])
      expect(pairs.map { |_message, ownership| ownership }).to eq(%i[not_ours ours])
    end

    # #backfill_candidates is the read only twin: same history, nothing dropped.
    it "drops a copy this bridge wrote through a webhook, unlike #backfill_candidates" do
      channel.existing_webhooks = [DiscordFakes::Hook.new(id: "555", name: "rubotty", token: "t")]
      echo = DiscordFakes::Message.new(id: "200", content: "echo", author: ada,
                                       timestamp: Time.now - 60, webhook_id: "555")
      echo.channel = channel
      allow(client).to receive(:history).and_return([echo])

      expect(adapter.backfill_messages(general, since: Time.now - 3600)).to be_empty
    end

    it "shapes each history reaction into a reaction_add message on the right endpoint" do
      emoji = DiscordFakes::Emoji.new(id: nil, name: "👍")
      user = DiscordFakes.user(id: "55", username: "ada", global_name: "Ada L")
      allow(client).to receive(:reactions).and_return([[emoji, user]])

      reactions = adapter.backfill_reactions(general, "700")

      expect(reactions.size).to eq(1)
      reaction = reactions.first
      expect(reaction.kind).to eq(:reaction_add)
      expect(reaction.origin).to eq(general)
      expect(reaction.ref.native_id).to eq("700")
      expect(reaction.author.native_id).to eq("55")
      expect(reaction.reaction).to eq(Rubotty::Core::Reaction.new(emoji: "👍"))
    end

    it "carries a custom emoji's id and name through the reaction" do
      emoji = DiscordFakes::Emoji.new(id: "999", name: "parrot")
      allow(client).to receive(:reactions).and_return([[emoji, ada]])

      reaction = adapter.backfill_reactions(general, "700").first

      expect(reaction.reaction).to eq(Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot"))
    end

    it "asks the client for reactions bounded by the given limit" do
      allow(client).to receive(:reactions).and_return([])
      adapter.backfill_reactions(general, "700", limit: 25)
      expect(client).to have_received(:reactions).with("8000000000000000003", "700", limit: 25)
    end
  end

  describe "capabilities" do
    it "reports reaction support with no practical limit" do
      expect(adapter.capabilities.reactions?).to be(true)
      expect(adapter.capabilities.max_reactions).to be_nil
    end

    it "reports the moderation actions it can carry out" do
      %i[delete ban unban kick mute unmute pin unpin unpinall].each do |action|
        expect(adapter.capabilities.moderates?(action)).to be(true)
      end
      expect(adapter.capabilities.moderates?(:obliterate)).to be(false)
    end

    # An unboosted server takes 10 MB. Declaring 25 MB, which was right until
    # Discord dropped it, had the bridge relay files Discord then refused.
    it "declares the unboosted upload ceiling when the account says nothing" do
      expect(adapter.capabilities.max_attachment_bytes).to eq(10 * 1024 * 1024)
    end

    it "declares the account's own ceiling when a boosted server raised it" do
      boosted = described_class.new(
        account: "dc", settings: { token: "t", token_env: "D", max_upload_bytes: 100 * 1024 * 1024 },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      )

      expect(boosted.capabilities.max_attachment_bytes).to eq(100 * 1024 * 1024)
      expect(boosted.capabilities_for(general).max_attachment_bytes).to eq(100 * 1024 * 1024)
    end
  end

  describe "inbound" do
    before { adapter.start }

    it "converts a message into canonical form" do
      adapter.emit_if(adapter.instance_variable_get(:@inbound).message(incoming))
      message = dispatcher.last
      expect(message.origin.id).to eq("dc-general")
      expect(message.body.text).to eq("hello")
      expect(message.author.username).to eq("ada")
      expect(message.ref.native_id).to eq("700")
    end

    it "parses Discord markdown into canonical spans" do
      adapter.emit_if(adapter.instance_variable_get(:@inbound).message(incoming(content: "a **bold** word")))
      body = dispatcher.last.body
      expect(body.text).to eq("a bold word")
      expect(body.spans.map(&:kind)).to eq([:bold])
    end

    it "captures attachments with their URLs" do
      attachment = DiscordFakes::Attachment.new(
        url: "https://cdn.discordapp.com/a.png", filename: "a.png", content_type: "image/png"
      )
      adapter.emit_if(adapter.instance_variable_get(:@inbound).message(incoming(attachments: [attachment])))
      captured = dispatcher.last.attachments.first
      expect(captured.kind).to eq(:photo)
      expect(captured.url).to eq("https://cdn.discordapp.com/a.png")
    end

    it "captures the parent of a reply so it can be quoted elsewhere" do
      parent = DiscordFakes::Message.new(id: "600", content: "original", author: ada)
      adapter.emit_if(adapter.instance_variable_get(:@inbound).message(incoming(referenced_message: parent)))
      message = dispatcher.last
      expect(message.reply_to).to eq(ref("dc-general", "600"))
      expect(message.reply_preview.body.text).to eq("original")
    end

    # Discord fires MESSAGE_UPDATE for embed unfurls and pins as well as edits.
    it "ignores an update that is not actually an edit" do
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "700", content: "hi", author: ada, edited: false),
        channel: channel
      )
      expect(adapter.instance_variable_get(:@inbound).edit(event)).to be_nil
    end

    it "relays a genuine edit" do
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "700", content: "fixed", author: ada, edited: true),
        channel: channel
      )
      expect(adapter.instance_variable_get(:@inbound).edit(event).kind).to eq(:edit)
    end

    # A payload that cannot answer defaults to "not an edit": the other way
    # turns an embed unfurl or a pin into a fabricated edit.
    it "treats a payload that cannot say whether it was edited as not one" do
      inbound = adapter.instance_variable_get(:@inbound)
      payload = Object.new
      expect(inbound.send(:edited?, payload)).to be(false)
    end

    it "treats a failure to check as not an edit either" do
      inbound = adapter.instance_variable_get(:@inbound)
      payload = double("payload")
      allow(payload).to receive(:edited?).and_raise(RuntimeError.new("boom"))
      expect(inbound.send(:edited?, payload)).to be(false)
    end

    it "turns a delete event into a delete message" do
      event = DiscordFakes::DeleteEvent.new(id: "700", channel: channel)
      message = adapter.instance_variable_get(:@inbound).delete(event)
      expect(message.kind).to eq(:delete)
      expect(message.ref).to eq(ref("dc-general", "700"))
    end

    it "turns a reaction into a reaction event" do
      event = DiscordFakes::ReactionEvent.new(
        message_id: "700", channel: channel, user: ada,
        emoji: DiscordFakes::Emoji.new(id: nil, name: "👍")
      )
      message = adapter.instance_variable_get(:@inbound).reaction(event, :reaction_add)
      expect(message.kind).to eq(:reaction_add)
      expect(message.reaction.emoji).to eq("👍")
      expect(message.author.native_id).to eq("55")
    end

    # discordrb's ReactionEvent#user resolves the reacting member with a live
    # REST call, and answers nil rather than raise on a rate limit or any
    # other hiccup. Without the fallback to the bare id, a nil user silently
    # drops the reaction: the vote or RSVP vanishes with no error.
    it "falls back to the bare id already parsed off the payload when the member cannot be resolved" do
      event = DiscordFakes::ReactionEvent.new(
        message_id: "700", channel: channel, user: nil, user_id: "909",
        emoji: DiscordFakes::Emoji.new(id: nil, name: "👍")
      )
      message = adapter.instance_variable_get(:@inbound).reaction(event, :reaction_add)
      expect(message.author.native_id).to eq("909")
      expect(message.author.kind).to eq(:user)
    end

    it "warns rather than silently dropping a reaction whose member and bare id both come back nil" do
      logs = StringIO.new
      inbound = Rubotty::Adapters::Discord::Inbound.new(
        endpoint_for: adapter.method(:endpoint_for), logger: Rubotty::Log.build(level: "debug", io: logs)
      )
      event = DiscordFakes::ReactionEvent.new(
        message_id: "700", channel: channel, user: nil, emoji: DiscordFakes::Emoji.new(id: nil, name: "👍")
      )
      message = inbound.reaction(event, :reaction_add)
      expect(message.author.native_id).to be_nil
      expect(logs.string).to include("WARN")
      expect(logs.string).to include("no resolvable user")
    end

    it "recognises a custom emoji reaction" do
      event = DiscordFakes::ReactionEvent.new(
        message_id: "700", channel: channel, user: ada,
        emoji: DiscordFakes::Emoji.new(id: "999", name: "parrot")
      )
      message = adapter.instance_variable_get(:@inbound).reaction(event, :reaction_add)
      expect(message.reaction).to be_custom
      expect(message.reaction.custom_id).to eq("999")
    end

    it "warns, rather than silently dropping, a reaction that carries no readable emoji" do
      logs = StringIO.new
      inbound = Rubotty::Adapters::Discord::Inbound.new(
        endpoint_for: adapter.method(:endpoint_for), logger: Rubotty::Log.build(level: "debug", io: logs)
      )
      event = DiscordFakes::ReactionEvent.new(message_id: "700", channel: channel, user: ada, emoji: nil)
      expect(inbound.reaction(event, :reaction_add)).to be_nil
      expect(logs.string).to include("WARN")
      expect(logs.string).to include("no readable emoji")
    end

    # A skin-tone reaction is a multi-codepoint grapheme Discord hands over
    # whole, and it has to stay whole to round-trip.
    it "preserves the whole grapheme of a skin-tone reaction" do
      event = DiscordFakes::ReactionEvent.new(
        message_id: "700", channel: channel, user: ada,
        emoji: DiscordFakes::Emoji.new(id: nil, name: "👍🏾")
      )
      message = adapter.instance_variable_get(:@inbound).reaction(event, :reaction_add)
      expect(message.reaction.emoji).to eq("👍🏾")
      expect(message.reaction.key).to eq("emoji:👍🏾")
    end

    # MESSAGE_REACTION_REMOVE_ALL and MESSAGE_REACTION_REMOVE_EMOJI: Discord
    # names no user for either, so neither event carries one.
    it "turns a remove-emoji event into a reaction_clear naming that emoji" do
      event = DiscordFakes::ReactionEvent.new(
        message_id: "700", channel: channel, emoji: DiscordFakes::Emoji.new(id: nil, name: "👍")
      )
      message = adapter.instance_variable_get(:@inbound).reaction_clear(event)
      expect(message.kind).to eq(:reaction_clear)
      expect(message.reaction.emoji).to eq("👍")
      expect(message.author.native_id).to be_nil
    end

    it "turns a remove-all event, which carries no emoji, into a reaction_clear naming none" do
      event = DiscordFakes::ReactionEvent.new(message_id: "700", channel: channel, emoji: nil)
      message = adapter.instance_variable_get(:@inbound).reaction_clear(event)
      expect(message.kind).to eq(:reaction_clear)
      expect(message.reaction).to be_nil
    end

    it "wires reaction_remove_all and reaction_remove_emoji to the dispatcher alongside reaction_add and remove" do
      adapter.start
      client.fire(:reaction_remove_all, DiscordFakes::ReactionEvent.new(message_id: "700", channel: channel))
      expect(dispatcher.last.kind).to eq(:reaction_clear)

      client.fire(
        :reaction_remove_emoji,
        DiscordFakes::ReactionEvent.new(message_id: "700", channel: channel,
                                        emoji: DiscordFakes::Emoji.new(id: nil, name: "🎉"))
      )
      expect(dispatcher.last.reaction.emoji).to eq("🎉")
    end

    it "ignores a channel it has no endpoint for" do
      other = DiscordFakes::Channel.new(id: "999999")
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "1", content: "x", author: ada), channel: other
      )
      expect(adapter.instance_variable_get(:@inbound).message(event)).to be_nil
    end

    # The stored logger used to go unread; a message that vanishes for lack of
    # an endpoint left nothing to grep for.
    it "logs at debug when a channel carries no bridged endpoint" do
      logs = StringIO.new
      inbound = Rubotty::Adapters::Discord::Inbound.new(
        endpoint_for: adapter.method(:endpoint_for), logger: Rubotty::Log.build(level: "debug", io: logs)
      )
      other = DiscordFakes::Channel.new(id: "999999")
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "1", content: "x", author: ada), channel: other
      )
      inbound.message(event)
      expect(logs.string).to include("999999")
    end

    # A Discord thread is a channel with a parent, and its name travels with the
    # message so a target without threads can still name it.
    it "captures the thread a message lives in, with its name" do
      # parent_id pointing at the endpoint's real channel_id is what lets the
      # message resolve and route at all.
      thread_channel = DiscordFakes::Channel.new(
        id: "9999999999999999", parent_id: "8000000000000000003", name: "release chat", channel_type: :thread
      )
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "700", content: "hi", author: ada), channel: thread_channel
      )
      thread = adapter.instance_variable_get(:@inbound).message(event).thread
      expect(thread.native_id).to eq("9999999999999999")
      expect(thread.name).to eq("release chat")
    end

    # Discord hands the member who started a thread on the thread's own channel
    # object, so a target that cannot show the thread can still credit it.
    it "captures who started the thread, as their handle" do
      client.known_users["4242"] = DiscordFakes.user(id: "4242", username: "owner_handle")
      started = DiscordFakes::Channel.new(
        id: "9999999999999999", parent_id: "8000000000000000003", name: "Test.",
        channel_type: :thread, owner_id: "4242"
      )
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "703", content: "Thread test.", author: ada), channel: started
      )

      thread = adapter.instance_variable_get(:@inbound).message(event).thread

      expect(thread.creator).to eq("owner_handle")
      expect(thread.creator_native_id).to eq("4242")
    end

    it "carries no creator for a thread whose starter the bot cannot see" do
      orphaned = DiscordFakes::Channel.new(
        id: "9999999999999999", parent_id: "8000000000000000003", name: "Test.",
        channel_type: :thread, owner_id: "4242"
      )
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "704", content: "hi", author: ada), channel: orphaned
      )

      thread = adapter.instance_variable_get(:@inbound).message(event).thread

      expect(thread.creator).to be_nil
    end

    it "carries no thread for a message in a normal channel" do
      adapter.emit_if(adapter.instance_variable_get(:@inbound).message(incoming))
      expect(dispatcher.last.thread).to be_nil
    end

    # A real thread's own id is never itself a mapped endpoint, so the message
    # has to resolve through its parent channel or it is dropped.
    it "routes a message from a real (never separately mapped) thread through its parent channel" do
      real_thread = DiscordFakes::Channel.new(
        id: "9999999999999999", parent_id: "8000000000000000003", name: "release chat", channel_type: :thread
      )
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "701", content: "hi", author: ada), channel: real_thread
      )

      adapter.emit_if(adapter.instance_variable_get(:@inbound).message(event))

      expect(dispatcher.last).not_to be_nil
      expect(dispatcher.last.origin.id).to eq("dc-general")
      expect(dispatcher.last.thread.native_id).to eq("9999999999999999")
      expect(dispatcher.last.thread.name).to eq("release chat")
    end

    # Discord sets parent_id to the CATEGORY id for an ordinary channel that
    # sits in a category, the same field a thread uses for its parent channel,
    # so #endpoint_for cannot trust parent_id alone.
    it "resolves a channel sitting in a category to its own endpoint, not the category" do
      categorized = DiscordFakes::Channel.new(id: "8000000000000000003", parent_id: "718913494321201265")
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "702", content: "hi", author: ada), channel: categorized
      )

      adapter.emit_if(adapter.instance_variable_get(:@inbound).message(event))

      expect(dispatcher.last).not_to be_nil
      expect(dispatcher.last.origin.id).to eq("dc-general")
    end

    it "carries no thread for a message in a channel that merely sits in a category" do
      categorized = DiscordFakes::Channel.new(id: "8000000000000000003", parent_id: "718913494321201265")
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "703", content: "hi", author: ada), channel: categorized
      )

      message = adapter.instance_variable_get(:@inbound).message(event)

      expect(message.thread).to be_nil
    end
  end

  # GUILD_MEMBER_ADD and GUILD_MEMBER_REMOVE carry a guild, never a channel, so
  # every endpoint bridged in that guild gets its own join or leave rather than
  # one guessed off an arbitrary index.
  describe "membership: GUILD_MEMBER_ADD and GUILD_MEMBER_REMOVE" do
    let(:mod_channel) do
      endpoint("dc-mod", adapter: :discord, settings: { channel_id: "2222222222", guild_id: "GLD1", webhook: :off })
    end

    def guild_event(guild_id: "GLD1")
      DiscordFakes::MemberEvent.new(user: ada, server: DiscordFakes::Server.new(id: guild_id, name: "Guild One"))
    end

    def member_adapter(endpoints: [mod_channel])
      described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: endpoints
      ).replace_client(client)
    end

    it "turns a member join into a canonical join on the endpoint configured for that guild" do
      member_adapter.start
      client.fire(:member_join, guild_event)

      message = dispatcher.last
      expect(message.kind).to eq(:join)
      expect(message.origin.id).to eq("dc-mod")
      expect(message.author.username).to eq("ada")
      expect(message.author.native_id).to eq("55")
    end

    it "turns a member leave into a canonical leave the same way" do
      member_adapter.start
      client.fire(:member_leave, guild_event)
      expect(dispatcher.last.kind).to eq(:leave)
    end

    # Features::Greetings and Features::AntiRaid observe :join/:leave the same
    # way regardless of adapter, so reaching every bridged channel with the
    # right kind is what makes a Discord join or leave visible to either.
    it "reaches every endpoint configured for that guild, not only the first" do
      other = endpoint("dc-mod-2", adapter: :discord,
                                   settings: { channel_id: "3333333333", guild_id: "GLD1", webhook: :off })
      adapter = member_adapter(endpoints: [mod_channel, other])
      adapter.start
      client.fire(:member_join, guild_event)

      expect(dispatcher.messages.map { |m| m.origin.id }).to contain_exactly("dc-mod", "dc-mod-2")
    end

    it "does nothing for a guild no endpoint is configured for, rather than guessing one" do
      member_adapter.start
      client.fire(:member_join, guild_event(guild_id: "OTHER"))
      expect(dispatcher.messages).to be_empty
    end
  end

  # A command word in a channel with no endpoint is otherwise dropped in
  # silence, so the adapter answers it itself; it must stay silent for ordinary
  # chat and for a mapped channel's own webhook echo.
  describe "unmapped-channel commands (issue #168)" do
    before { adapter.start }

    let(:unmapped_channel) { client.channel("no-such-channel") }

    def unmapped(content:)
      DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "700", content: content, author: ada),
        channel: unmapped_channel
      )
    end

    it "replies when a recognised command word arrives in an unmapped channel" do
      adapter.send(:notify_unmapped_command, unmapped(content: "!delete"))
      expect(unmapped_channel.sent.map { |m| m[:content] }).to eq(["Commands are not available in this channel."])
    end

    it "recognises the / prefix as well as !" do
      adapter.send(:notify_unmapped_command, unmapped(content: "/help"))
      expect(unmapped_channel.sent.map { |m| m[:content] }).to eq(["Commands are not available in this channel."])
    end

    it "stays silent for ordinary chat that happens to start with a marker but no known word" do
      adapter.send(:notify_unmapped_command, unmapped(content: "!lol nice one"))
      expect(unmapped_channel.sent).to be_empty
    end

    it "stays silent for ordinary chat with no marker at all" do
      adapter.send(:notify_unmapped_command, unmapped(content: "hello everyone"))
      expect(unmapped_channel.sent).to be_empty
    end

    it "stays silent for a command word in a MAPPED channel (a different reason #inbound.message can return nil)" do
      adapter.send(:notify_unmapped_command, incoming(content: "!delete"))
      expect(channel.sent).to be_empty
    end

    it "never raises even when the channel cannot be replied to" do
      allow(unmapped_channel).to receive(:send_message).and_raise(RuntimeError.new("boom"))
      expect { adapter.send(:notify_unmapped_command, unmapped(content: "!delete")) }.not_to raise_error
    end

    # A relayed copy of our own message comes back as a MESSAGE_CREATE the
    # loop guard drops, so #inbound.message returns nil for reasons unrelated
    # to mapping. Inside a mapped THREAD that nil used to read as unmapped,
    # because #endpoint_for only resolves a thread's parent channel, not its own id.
    it "stays silent for a command word in a mapped THREAD, not just a mapped channel" do
      thread = DiscordFakes::Channel.new(id: "9990001", parent_id: channel.id, channel_type: :thread)
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "701", content: "!delete", author: ada), channel: thread
      )

      adapter.send(:notify_unmapped_command, event)

      expect(thread.sent).to be_empty
    end
  end

  # The adapter persists a thread's name so it survives a channel-object cache
  # miss and a thread that predates the session is still nameable.
  describe "learning thread names (#40)" do
    before do
      adapter.storage = Rubotty::Storage::Memory.new
      adapter.start
    end

    # parent_id points at the seeded general endpoint's real channel_id, so a
    # message in the thread routes through its parent as a real one does.
    def thread_channel(name)
      DiscordFakes::Channel.new(
        id: "9999999999999999", parent_id: "8000000000000000003", name: name, channel_type: :thread
      )
    end

    def nameless_thread_channel
      DiscordFakes::Channel.new(id: "9999999999999999", parent_id: "8000000000000000003", channel_type: :thread)
    end

    def relay_message_in(channel, id: "700")
      adapter.emit_if(
        adapter.instance_variable_get(:@inbound).message(
          DiscordFakes::MessageEvent.new(
            message: DiscordFakes::Message.new(id: id, content: "hi", author: ada), channel: channel
          )
        )
      )
    end

    it "learns from a THREAD_CREATE event, naming a later message whose channel lost its name" do
      client.fire(:thread_create, DiscordFakes::ThreadEvent.new(thread: thread_channel("release chat")))
      relay_message_in(nameless_thread_channel)
      expect(dispatcher.last.thread.name).to eq("release chat")
    end

    it "updates the name from a THREAD_UPDATE event" do
      client.fire(:thread_create, DiscordFakes::ThreadEvent.new(thread: thread_channel("release chat")))
      client.fire(:thread_update, DiscordFakes::ThreadEvent.new(thread: thread_channel("release war room")))
      relay_message_in(nameless_thread_channel)
      expect(dispatcher.last.thread.name).to eq("release war room")
    end

    it "learns from an ordinary message in the thread, covering threads that predate this session" do
      relay_message_in(thread_channel("release chat"))
      relay_message_in(nameless_thread_channel, id: "701")
      expect(dispatcher.last.thread.name).to eq("release chat")
    end

    it "keeps a thread's own current name rather than overriding it from the store" do
      client.fire(:thread_create, DiscordFakes::ThreadEvent.new(thread: thread_channel("stale")))
      relay_message_in(thread_channel("current"))
      expect(dispatcher.last.thread.name).to eq("current")
    end

    # discordrb 3.8.0 has no thread_create/thread_update DSL, so this is what
    # actually happens in production; the events above never fire there.
    it "learns from a THREAD_CREATE dispatch delivered through the unknown handler" do
      data = { "id" => "9999999999999999", "name" => "release chat" }
      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "THREAD_CREATE", data: data))
      relay_message_in(nameless_thread_channel)
      expect(dispatcher.last.thread.name).to eq("release chat")
    end

    it "updates the name from a THREAD_UPDATE dispatch through the unknown handler" do
      created = { "id" => "9999999999999999", "name" => "release chat" }
      updated = { "id" => "9999999999999999", "name" => "release war room" }
      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "THREAD_CREATE", data: created))
      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "THREAD_UPDATE", data: updated))
      relay_message_in(nameless_thread_channel)
      expect(dispatcher.last.thread.name).to eq("release war room")
    end
  end

  # A thread message's ref always names the PARENT endpoint (Inbound falls
  # back to it so the message routes at all), while the message itself only
  # exists in the thread's own channel. A write path addressing it again by
  # native id must reach into the thread, not the parent, or Discord 404s.
  describe "acting on a message that lives in a Discord thread (#682)" do
    before do
      adapter.storage = Rubotty::Storage::Memory.new
      adapter.start
    end

    let(:thread_id) { "9999999999999999" }
    let(:thread_channel) do
      DiscordFakes::Channel.new(
        id: thread_id, parent_id: "8000000000000000003", name: "release chat", channel_type: :thread
      )
    end

    def relay_message_in_thread(id:)
      adapter.emit_if(
        adapter.instance_variable_get(:@inbound).message(
          DiscordFakes::MessageEvent.new(
            message: DiscordFakes::Message.new(id: id, content: "hi", author: ada), channel: thread_channel
          )
        )
      )
    end

    it "edits the thread's own copy rather than 404ing against the parent channel" do
      relay_message_in_thread(id: "700")
      client.channel(thread_id).store(DiscordFakes::Message.new(id: "700", content: "old", author: ada))

      adapter.edit(message(general, text: "fixed"), general, "700")

      edit = client.edited_messages.first
      expect(edit[:channel_id]).to eq(thread_id)
      expect(edit[:message_id]).to eq("700")
    end

    it "deletes the thread's own copy rather than 404ing against the parent channel" do
      relay_message_in_thread(id: "701")
      client.channel(thread_id).store(DiscordFakes::Message.new(id: "701", content: "old", author: ada))

      adapter.delete(general, "701")

      expect(client.channel(thread_id).load_message("701").deleted).to be(true)
    end

    it "syncs reactions on the thread's own copy" do
      relay_message_in_thread(id: "702")
      target = client.channel(thread_id).store(DiscordFakes::Message.new(id: "702", content: "x", author: ada))

      adapter.sync_reactions(general, "702", desired: [Rubotty::Core::Reaction.new(emoji: "👍")], previous: [])

      expect(target.reactions).to eq(["👍"])
    end

    it "pins the thread's own copy" do
      relay_message_in_thread(id: "703")
      target = client.channel(thread_id).store(DiscordFakes::Message.new(id: "703", content: "keep", author: ada))
      command = Rubotty::Core::Moderation::Command.new(
        action: :pin, issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"), origin: general
      )

      expect(adapter.moderate(command, general, "703").status).to eq(:done)
      expect(target.pinned).to be(true)
    end

    it "carries the thread id through to a webhook edit, so Discord does not look in the parent channel" do
      relay_message_in_thread(id: "704")
      hook = DiscordFakes::WebhookClient.new
      allow(adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)

      adapter.edit(message(general, text: "fixed"), general, "704")

      expect(hook.edited.first[:thread_id]).to eq(thread_id)
    end

    it "carries the thread id through to a webhook delete when the bot cannot reach the message" do
      relay_message_in_thread(id: "705")
      manager = adapter.instance_variable_get(:@webhooks)
      hook = DiscordFakes::WebhookClient.new
      allow(manager).to receive(:for).and_return(hook)
      expect(manager).to receive(:delete).with(hook, "705", thread_id: thread_id)

      adapter.delete(general, "705")
    end

    it "still addresses the parent channel for a message that never lived in a thread" do
      channel.store(DiscordFakes::Message.new(id: "706", content: "old", author: ada))

      adapter.edit(message(general, text: "fixed"), general, "706")

      expect(client.edited_messages.first[:channel_id]).to eq("8000000000000000003")
    end
  end

  # GUILD_MEMBER_ADD and GUILD_MEMBER_REMOVE carry no channel, so the address
  # really is guild level. Membership itself is now resolved by guild id
  # instead of this nil-channel path; #endpoint_for still guards against
  # guessing whenever something else calls it with no channel id.
  describe "membership events with no live resolver (config-file mode, #686)" do
    let(:other) { endpoint("dc-other", adapter: :discord, settings: { channel_id: "222222", webhook: :off }) }
    let(:multi_adapter) do
      described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general, other]
      ).replace_client(client)
    end

    it "resolves a nil channel id to nil rather than an arbitrary endpoint" do
      expect(multi_adapter.send(:endpoint_for, nil)).to be_nil
    end

    # A single endpoint is not a guess: it is the only account this event
    # could possibly belong to, so it still resolves.
    it "still resolves a nil channel id when config-file mode configured exactly one endpoint" do
      expect(adapter.send(:endpoint_for, nil)).to eq(general)
    end
  end

  # A DM to the bot owns no configured channel, so it misses the resolver; a
  # wired control lane gets the gesture instead of it being dropped.
  describe "DM control gestures (#13 / #31)" do
    # Records the DM it is handed and answers with a canned line.
    let(:lane) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def handle_dm(adapter:, account:, author:, text:, quoted: nil, subject: nil)
          @calls << { adapter: adapter, account: account, author: author, text: text }
          "public-information notice"
        end
      end.new
    end

    subject(:adapter_with_lane) do
      described_class.new(
        account: "dc",
        settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher,
        logger: Rubotty::Log.null,
        endpoints: [general],
        control_lane: lane
      ).replace_client(client)
    end

    let(:dm_channel) { DiscordFakes::Channel.new(id: "dm-99", pm: true) }

    def dm(content, author: ada, channel: dm_channel)
      DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "700", content: content, author: author),
        channel: channel
      )
    end

    before { adapter_with_lane.start }

    it "hands a private-channel message to the control lane with the author and account" do
      client.fire(:message, dm("hi bot"))
      expect(lane.calls.size).to eq(1)
      call = lane.calls.first
      expect(call[:adapter]).to eq(:discord)
      expect(call[:account]).to eq("dc")
      expect(call[:text]).to eq("hi bot")
      expect(call[:author].native_id).to eq("55")
      expect(call[:author].username).to eq("ada")
    end

    it "sends the lane's reply back into the DM channel as the bot" do
      client.fire(:message, dm("hi bot"))
      expect(dm_channel.sent.map { |m| m[:content] }).to eq(["public-information notice"])
    end

    it "does not route a DM as a normal message" do
      client.fire(:message, dm("hi bot"))
      expect(dispatcher.messages).to be_empty
    end

    it "leaves a guild message untouched: it routes normally, not to the lane" do
      client.fire(:message, DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "701", content: "hello", author: ada),
        channel: channel
      ))
      expect(lane.calls).to be_empty
      expect(dispatcher.last.origin.id).to eq("dc-general")
    end

    it "ignores the bot's own DM, so a reply cannot loop" do
      me = DiscordFakes.user(id: "bot-discord", username: "bridgebot")
      client.fire(:message, dm("public-information notice", author: me))
      expect(lane.calls).to be_empty
      expect(dm_channel.sent).to be_empty
    end

    it "does not treat an empty DM as a gesture" do
      client.fire(:message, dm("   "))
      expect(lane.calls).to be_empty
      expect(dm_channel.sent).to be_empty
    end

    it "drops a DM with no control lane wired, exactly as before" do
      adapter.start
      client.fire(:message, dm("hi bot"))
      expect(dispatcher.messages).to be_empty
      expect(dm_channel.sent).to be_empty
    end

    # A DM owns no endpoint, so without a guard it falls into the
    # unmapped-channel notice and answers anybody who typed a command word.
    it "stays silent on a DM carrying a real command word and no control lane" do
      adapter.start
      client.fire(:message, dm("/help"))
      expect(dispatcher.messages).to be_empty
      expect(dm_channel.sent).to be_empty
    end

    it "still tells a member a command missed an unmapped GUILD channel" do
      adapter.start
      elsewhere = DiscordFakes::Channel.new(id: "dc-nowhere")
      client.fire(:message, DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "702", content: "/help", author: ada),
        channel: elsewhere
      ))
      expect(elsewhere.sent.map { |m| m[:content] }).to eq(["Commands are not available in this channel."])
    end
  end

  describe "outbound" do
    before { adapter.start }

    let(:outgoing) { message(general, text: "hello").with(sender_label: "Ada (ada)") }

    it "sends the message and returns a receipt" do
      receipt = adapter.deliver(outgoing, general)
      expect(channel.sent.first[:content]).to include("hello")
      expect(receipt.native_id).to eq("sent-1")
    end

    it "prefixes the sender name" do
      adapter.deliver(outgoing, general)
      expect(channel.sent.first[:content]).to start_with("**Ada (ada)")
    end

    # A Telegram user typing "@everyone" must not ping a Discord server.
    it "suppresses mass mentions by default" do
      adapter.deliver(outgoing, general)
      expect(channel.sent.first[:allowed_mentions]).to eq(parse: [], users: [], roles: [])
    end

    it "permits only the ids the bridge resolved, leaving injected tokens inert" do
      injected = message(
        general,
        text: rich(
          "ping <@111> and @everyone and Alex",
          span(:mention, 30, 34, discord_id_for_target: "900")
        )
      ).with(sender_label: "Ada")
      adapter.deliver(injected, general)
      mentions = channel.sent.first[:allowed_mentions]
      expect(mentions[:parse]).to eq([])
      expect(mentions[:users]).to eq(["900"])
      expect(mentions[:roles]).to eq([])
    end

    it "permits mass mentions only when the operator opts in" do
      loud = endpoint("dc-loud", adapter: :discord,
                      settings: { channel_id: "8000000000000000003", webhook: :off,
                                  allow_mass_mentions: true })
      adapter.deliver(outgoing, loud)
      expect(channel.sent.first[:allowed_mentions]).to be_nil
    end

    it "escapes markdown in relayed text so it is not reinterpreted" do
      hostile = message(general, text: "not **bold**").with(sender_label: "Ada")
      adapter.deliver(hostile, general)
      expect(channel.sent.first[:content]).to include('\\*\\*bold\\*\\*')
    end

    it "attaches a native reply when the parent lives on this endpoint" do
      local = outgoing.with(reply_to: ref("dc-general", "600"))
      adapter.deliver(local, general)
      expect(channel.sent.first[:message_reference]).to eq(message_id: 600, fail_if_not_exists: false)
    end

    it "quotes the parent when a native reply is impossible" do
      preview = Rubotty::Core::ReplyPreview.new(
        body: Rubotty::Core::RichText.plain("the original"), label: "Grace"
      )
      foreign = outgoing.with(reply_to: ref("tg-general", "42"), reply_preview: preview)
      adapter.deliver(foreign, general)
      content = channel.sent.first[:content]
      expect(content).to start_with("> **Grace**: the original")
      expect(channel.sent.first[:message_reference]).to be_nil
    end

    it "does not quote when it can make a native reply, to avoid showing it twice" do
      preview = Rubotty::Core::ReplyPreview.new(
        body: Rubotty::Core::RichText.plain("the original"), label: "Grace"
      )
      local = outgoing.with(reply_to: ref("dc-general", "600"), reply_preview: preview)
      adapter.deliver(local, general)
      expect(channel.sent.first[:content]).not_to include("> **Grace**")
    end

    it "edits a message in place" do
      channel.store(DiscordFakes::Message.new(id: "900", content: "old", author: ada))
      adapter.edit(outgoing.with(body: Rubotty::Core::RichText.plain("fixed")), general, "900")
      edit = client.edited_messages.first
      expect(edit[:message_id]).to eq("900")
      expect(edit[:content]).to include("fixed")
    end

    # discordrb's Message#edit sends no allowed_mentions of its own, so the edit
    # path has to supply the same whitelist the send path does.
    it "carries a mention whitelist on a bot edit, so an edit cannot reopen the hole" do
      channel.store(DiscordFakes::Message.new(id: "900", content: "old", author: ada))
      edited = outgoing.with(body: Rubotty::Core::RichText.plain("now @everyone"))
      adapter.edit(edited, general, "900")
      expect(client.edited_messages.first[:allowed_mentions]).to eq(parse: [], users: [], roles: [])
    end

    # A bridge notice is posted as the bot even on a webhook backed channel, so
    # editing it through the webhook would target a message it does not own.
    it "edits a bridge notice as the bot even where a webhook is configured" do
      hooked = endpoint("dc-hook", adapter: :discord,
                                   settings: { channel_id: "8000000000000000003", webhook: :auto })
      hooked_adapter = described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [hooked]
      ).replace_client(client)
      hook = DiscordFakes::WebhookClient.new
      allow(hooked_adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
      channel.store(DiscordFakes::Message.new(id: "900", content: "old"))

      notice = Rubotty::Core::Message.new(
        kind: :system,
        ref: Rubotty::Core::MessageRef.new("dc-hook", "900"),
        origin: hooked,
        author: Rubotty::Core::Author.new(display_name: "bridge", kind: :system),
        body: Rubotty::Core::RichText.plain("Successfully removed message on 2/2 connected services."),
        sender_label: "bridge"
      )
      hooked_adapter.edit(notice, hooked, "900")

      expect(client.edited_messages.map { |edit| edit[:message_id] }).to include("900")
      expect(hook.edited).to be_empty
    end

    it "deletes a message" do
      channel.store(DiscordFakes::Message.new(id: "900", content: "old", author: ada))
      adapter.delete(general, "900")
      expect(channel.load_message("900").deleted).to be(true)
    end

    it "treats an already deleted message as success" do
      expect { adapter.delete(general, "does-not-exist") }.not_to raise_error
    end

    # With a webhook configured the delete falls through to it, and the
    # webhook's own 404 has to resolve the same way as the case above.
    it "treats an already deleted message as success through the webhook path too" do
      require "discordrb"
      hooked = endpoint("dc-hook", adapter: :discord,
                                   settings: { channel_id: "8000000000000000003", webhook: :auto })
      hooked_adapter = described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [hooked]
      ).replace_client(client)
      hook = DiscordFakes::WebhookClient.new
      hook.fail_next(Discordrb::Errors::UnknownMessage.new("Unknown Message"))
      allow(hooked_adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)

      expect { hooked_adapter.delete(hooked, "already-gone") }.not_to raise_error
    end

    it "truncates a message that exceeds Discord's limit" do
      long = message(general, text: "x" * 3000).with(sender_label: "Ada")
      adapter.deliver(long, general)
      expect(channel.sent.first[:content].length).to be <= 2000
    end
  end

  describe "media" do
    before { adapter.start }

    let(:attachment) do
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
    end
    let(:with_media) do
      message(general, text: "look").with(sender_label: "Ada", attachments: [attachment])
    end

    it "downloads and re uploads, because Discord will not fetch a URL" do
      fetcher = Rubotty::Util::MediaFetcher.new(
        http: ->(_uri, _filename) { StringIO.new("PNGDATA").tap { |io| io.define_singleton_method(:unlink) { nil } } }
      )
      adapter.instance_variable_set(:@fetcher, fetcher)
      adapter.deliver(with_media, general)
      expect(channel.files.first[:bytes]).to eq("PNGDATA")
    end

    # Discord's upload_file route carries no allowed_mentions, so a caption of
    # "@everyone" there would ping the server.
    it "posts the caption as its own message, never on the file upload" do
      fetcher = Rubotty::Util::MediaFetcher.new(
        http: ->(_uri, _filename) { StringIO.new("PNGDATA").tap { |io| io.define_singleton_method(:unlink) { nil } } }
      )
      adapter.instance_variable_set(:@fetcher, fetcher)
      adapter.deliver(with_media, general)
      expect(channel.files.first[:caption]).to be_nil
      expect(channel.sent.first[:content]).to include("look")
      expect(channel.sent.first[:allowed_mentions]).to eq(parse: [], users: [], roles: [])
    end

    it "falls back to posting the link when the upload cannot happen" do
      fetcher = Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { nil })
      adapter.instance_variable_set(:@fetcher, fetcher)
      adapter.deliver(with_media, general)
      expect(channel.files).to be_empty
      expect(channel.sent.first[:content]).to include("https://cdn.example/a.png")
    end

    # An empty string url used to pass the uploadable filter and then die
    # silently in the fetcher: resolvable? and the fetcher now agree, so this
    # never reaches the fetcher at all.
    it "never attempts to fetch an attachment whose url is an empty string, and relays its label instead" do
      attempted = false
      fetcher = Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { attempted = true; nil })
      adapter.instance_variable_set(:@fetcher, fetcher)
      blank = Rubotty::Core::Attachment.new(kind: :photo, url: "", filename: "blank.png")
      adapter.deliver(message(general, text: "look").with(sender_label: "Ada", attachments: [blank]), general)

      expect(attempted).to be(false)
      expect(channel.files).to be_empty
      expect(channel.sent.first[:content]).to include("blank.png")
    end

    # One Discord adapter instance is shared across every room bridged through
    # that bot account, and Core::Dispatcher runs one worker thread per room,
    # so #deliver must be safe under concurrent calls. Stashing a failed
    # upload note on the instance let one room's worker steal or clear another's.
    it "keeps a failed-upload note out of the other room's receipt under concurrent delivery" do
      room_two = endpoint("dc-room-two", adapter: :discord,
                                        settings: { channel_id: "999888777", webhook: :off })
      channel_two = client.channel("999888777")

      fetcher = Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { nil })
      adapter.instance_variable_set(:@fetcher, fetcher)

      media_message = lambda do |endpoint, label|
        photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/#{label}.png",
                                              filename: "#{label}.png")
        message(endpoint, text: "").with(sender_label: "Ada", attachments: [photo])
      end

      entered = Queue.new
      release = Queue.new
      blocked_once = false
      allow(channel).to receive(:send_message).and_wrap_original do |original, *args|
        unless blocked_once
          blocked_once = true
          entered << :entered
          release.pop
        end
        original.call(*args)
      end

      first = Thread.new { adapter.deliver(media_message.call(general, "general"), general) }
      entered.pop # general's worker has noted its failure and is now stuck posting the fallback

      second_receipt = adapter.deliver(media_message.call(room_two, "room-two"), room_two)
      release << :go
      first_receipt = first.value

      expect(first_receipt.extra[:notes].join).to include("general.png")
      expect(first_receipt.extra[:notes].join).not_to include("room-two.png")
      expect(second_receipt.extra[:notes].join).to include("room-two.png")
      expect(second_receipt.extra[:notes].join).not_to include("general.png")
      expect(channel_two.sent.first[:content]).to include("room-two.png")
    end
  end

  describe "reactions" do
    before { adapter.start }

    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }

    it "adds the reactions that are newly desired" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "x", author: ada))
      adapter.sync_reactions(general, "900", desired: [thumbs, party], previous: [])
      expect(target.reactions).to eq(%w[👍 🎉])
    end

    it "removes only the reactions that are no longer desired" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "x", author: ada))
      adapter.sync_reactions(general, "900", desired: [thumbs, party], previous: [])
      adapter.sync_reactions(general, "900", desired: [party], previous: [thumbs, party])
      expect(target.reactions).to eq(["🎉"])
    end

    it "does nothing when the desired state already matches" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "x", author: ada))
      adapter.sync_reactions(general, "900", desired: [thumbs], previous: [])
      adapter.sync_reactions(general, "900", desired: [thumbs], previous: [thumbs])
      expect(target.reactions).to eq(["👍"])
    end

    it "uses the name and id form for a custom emoji" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "x", author: ada))
      custom = Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot")
      adapter.sync_reactions(general, "900", desired: [custom], previous: [])
      expect(target.reactions).to eq(["parrot:999"])
    end

    # A Telegram custom emoji has no name and an id Discord knows nothing about,
    # so what it is drawn from is the only thing that can go up.
    it "places the emoji a foreign custom one is drawn from" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "x", author: ada))
      custom = Rubotty::Core::Reaction.new(custom_id: "5373015670822804395", emoji: "😄")
      adapter.sync_reactions(general, "900", desired: [custom], previous: [])
      expect(target.reactions).to eq(["😄"])
    end

    it "places nothing for a foreign custom emoji it could not resolve" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "x", author: ada))
      custom = Rubotty::Core::Reaction.new(custom_id: "5373015670822804395")
      adapter.sync_reactions(general, "900", desired: [custom], previous: [])
      expect(target.reactions).to be_empty
    end

    # Discord can show a skin tone, so the toned grapheme must reach it intact.
    it "sends a skin-tone emoji to Discord with its modifier intact" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "x", author: ada))
      toned = Rubotty::Core::Reaction.new(emoji: "👍🏾")
      adapter.sync_reactions(general, "900", desired: [toned], previous: [])
      expect(target.reactions).to eq(["👍🏾"])
    end

    it "ignores a message that has since been deleted" do
      expect { adapter.sync_reactions(general, "gone", desired: [thumbs], previous: []) }
        .not_to raise_error
    end

  end

  # Every caller of the message fetch reads a nil as a fact about the message.
  # A 429, a revoked Read Message History or a socket blip is not that fact, and
  # answering nil for one writes a delete, a reaction or a dropped edit into
  # storage that never happened on Discord.
  describe "a message lookup that failed rather than proving the message gone" do
    before { adapter.start }

    let(:throttled) do
      require "rest-client"
      RestClient::TooManyRequests.new
    end

    def throttle_lookups!
      allow(channel).to receive(:load_message).and_raise(throttled)
    end

    it "raises out of a reaction sync instead of reporting the emoji placed" do
      throttle_lookups!
      thumbs = Rubotty::Core::Reaction.new(emoji: "👍")

      expect { adapter.sync_reactions(general, "900", desired: [thumbs], previous: []) }
        .to raise_error(Rubotty::AdapterError, /reaction sync failed/)
    end

    it "raises out of a delete instead of answering with delete's own success value" do
      throttle_lookups!

      expect { adapter.delete(general, "900") }
        .to raise_error(Rubotty::AdapterError, /delete failed/)
    end

    it "raises out of an edit instead of dropping it" do
      throttle_lookups!
      edit = message(general, text: "corrected").with(sender_label: "Ada")

      expect { adapter.edit(edit, general, "900") }
        .to raise_error(Rubotty::AdapterError, /edit failed/)
    end

    it "reports a pin as failed rather than as a message that is not there" do
      throttle_lookups!
      command = Rubotty::Core::Moderation::Command.new(
        action: :pin, issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"), origin: general
      )

      expect(adapter.moderate(command, general, "900").status).to eq(:failed)
    end

    # The honest nil: Discord answered that the message is not there.
    it "still answers nil for a message Discord confirmed is gone" do
      require "discordrb"
      allow(channel).to receive(:load_message).and_raise(Discordrb::Errors::UnknownMessage.new("Unknown Message"))
      thumbs = Rubotty::Core::Reaction.new(emoji: "👍")

      expect { adapter.sync_reactions(general, "900", desired: [thumbs], previous: []) }.not_to raise_error
    end

    it "still answers nil for a bare 404" do
      allow(channel).to receive(:load_message).and_raise(RestClient::NotFound.new)

      expect { adapter.delete(general, "900") }.not_to raise_error
    end
  end

  describe "moderation" do
    before { adapter.start }

    it "deletes the target message and reports success" do
      channel.store(DiscordFakes::Message.new(id: "900", content: "bad", author: ada))
      command = Rubotty::Core::Moderation::Command.new(
        action: :delete,
        issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general
      )
      result = adapter.moderate(command, general, "900")
      expect(result.status).to eq(:done)
      expect(channel.load_message("900").deleted).to be(true)
    end

    it "reports an action outside the vocabulary as unsupported" do
      command = Rubotty::Core::Moderation::Command.new(
        action: :obliterate,
        issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general
      )
      expect(adapter.moderate(command, general, nil).status).to eq(:unsupported)
    end

    it "pins a message" do
      target = channel.store(DiscordFakes::Message.new(id: "900", content: "keep", author: ada))
      command = Rubotty::Core::Moderation::Command.new(
        action: :pin, issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general
      )
      expect(adapter.moderate(command, general, "900").status).to eq(:done)
      expect(target.pinned).to be(true)
    end

    it "reports a pin target that is not there as not_found" do
      command = Rubotty::Core::Moderation::Command.new(
        action: :pin, issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general
      )
      expect(adapter.moderate(command, general, "gone").status).to eq(:not_found)
    end
  end

  # Being added to a guild is a GUILD_CREATE (discordrb server_create), which
  # also fires for every guild the bot is already in at connect. Driven against
  # the real join guard and the real seeded control plane, nothing stubbed.
  describe "auto-leave and discovery on being added to a guild (#35, #38, #39)", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community) { models.community.first }
    let(:discord_connection) { models.platform_connection.where(adapter: "discord").first }
    # A Discord channel id is globally unique, so a seeded channel's route_key
    # appearing in a guild identifies that guild as the seeded one.
    let(:seeded_channel_id) { models.channel.where(adapter: "discord").order(:id).first.route_key }

    let(:store) do
      Class.new do
        def initialize = @h = {}

        def get_state(key)
          row = @h[key]
          row && (row[:expires_at].nil? || row[:expires_at] > Time.now) ? row[:value] : nil
        end

        def put_state(key, value, expires_at: nil) = @h[key] = { value: value, expires_at: expires_at }
      end.new
    end

    let(:notifier) do
      Class.new do
        attr_reader :prompts

        def initialize = @prompts = []

        def prompt(community:, descriptor:) = @prompts << descriptor
      end.new
    end

    let(:onboarding) { nil }
    let(:watch) { Rubotty::ControlPlane::NewChannelWatch.new(models: models, store: store) }
    let(:discovery) do
      Rubotty::ControlPlane::ChannelDiscovery.new(models: models, watch: watch, notifier: notifier)
    end
    let(:join_guard) do
      Rubotty::ControlPlane::JoinGuard.new(
        authorization: Rubotty::ControlPlane::AuthorizationDirectory.new(models: models),
        onboarding: onboarding
      )
    end

    let(:guild_client) { DiscordFakes::Client.new }

    subject(:guild_adapter) do
      described_class.new(
        account: "discord",
        settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
        join_guard: join_guard, discovery: discovery
      ).replace_client(guild_client).tap(&:start)
    end

    def add_guild(guild_id:, name:, channels:)
      guild_adapter # force the subject so start registers the server_create handler
      guild_client.set_guild_channels(guild_id, channels)
      server = DiscordFakes::Server.new(id: guild_id, name: name)
      guild_client.fire(:server_create, DiscordFakes::ServerCreateEvent.new(server: server))
    end

    def enable_alerts
      settings = community.json_value(:settings)
      settings["new_channel_alerts"] = { "enabled" => true, "ignore" => [] }
      community.update(settings: JSON.generate(settings))
    end

    def disable_alerts
      settings = community.json_value(:settings)
      settings["new_channel_alerts"] = { "enabled" => false }
      community.update(settings: JSON.generate(settings))
    end

    # The seeded guild's connection still reads "unresolved:<slug>" and its name
    # matches nothing on the protected whitelist, so only the sentinel
    # resolution can save it.
    it "never leaves its own seeded guild, resolving the sentinel from its channels" do
      add_guild(guild_id: "70707070", name: "Totally Unrelated Name",
                channels: [{ id: seeded_channel_id, name: "general" }])

      expect(guild_client.left_servers).to be_empty
      expect(guild_client.guild_notices).to be_empty
      expect(discord_connection.reload.external_id).to eq("70707070")
    end

    it "keeps a guild whose NAME matches the protected whitelist, even unmapped (#118)" do
      add_guild(guild_id: "888", name: "Example Gaming Community",
                channels: [{ id: "777001", name: "lobby" }])

      expect(guild_client.left_servers).to be_empty
      expect(guild_client.guild_notices).to be_empty
    end

    it "keeps a guild while an onboarding is in progress for it" do
      allow_onboarding = double("onboarding")
      allow(allow_onboarding).to receive(:in_progress?)
        .with(adapter: :discord, account: "discord", external_id: "654").and_return(true)

      guard = Rubotty::ControlPlane::JoinGuard.new(
        authorization: Rubotty::ControlPlane::AuthorizationDirectory.new(models: models),
        onboarding: allow_onboarding
      )
      adapter = described_class.new(
        account: "discord", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
        join_guard: guard, discovery: discovery
      ).replace_client(guild_client).tap(&:start)

      guild_client.set_guild_channels("654", [{ id: "654001", name: "welcome" }])
      adapter.handle_guild_added(
        DiscordFakes::ServerCreateEvent.new(server: DiscordFakes::Server.new(id: "654", name: "New Community"))
      )
      expect(guild_client.left_servers).to be_empty
    end

    it "posts the notice and leaves a genuinely unauthorized guild" do
      add_guild(guild_id: "999", name: "Rando Server",
                channels: [{ id: "123001", name: "general" }])

      expect(guild_client.left_servers).to eq(["999"])
      notice = guild_client.guild_notices.first
      expect(notice[:guild_id]).to eq("999")
      expect(notice[:text]).to eq(Rubotty::ControlPlane::JoinGuard::DEFAULT_NOTICE)
    end

    it "leaves an unauthorized guild even when the notice cannot be posted" do
      allow(guild_client).to receive(:post_guild_notice).and_raise(StandardError.new("no perms"))
      add_guild(guild_id: "999", name: "Rando Server", channels: [{ id: "123001", name: "general" }])
      expect(guild_client.left_servers).to eq(["999"])
    end

    # discordrb never raises server_create for a guild the bot is already in at
    # connect, so #sweep_known_guilds on bot.ready is what catches one added
    # while the bot was down.
    describe "the boot-time guild sweep on bot.ready (closing the discordrb server_create gap)" do
      it "never fires server_create for a guild already known at connect (documents the library gap this works around)" do
        guild_adapter # force the subject so start registers the handlers
        guild_client.set_servers("999" => DiscordFakes::Server.new(id: "999", name: "Rando Server"))
        guild_client.set_guild_channels("999", [{ id: "123001", name: "general" }])

        guild_client.fire(:ready, nil)

        expect(guild_client.handlers[:server_create]).not_to be_nil
        expect(guild_client.left_servers).to eq(["999"]) # only the ready sweep could have caused this
      end

      it "leaves an unauthorized guild the bot was already in at connect, exactly as a live join would" do
        guild_adapter
        guild_client.set_servers("999" => DiscordFakes::Server.new(id: "999", name: "Rando Server"))
        guild_client.set_guild_channels("999", [{ id: "123001", name: "general" }])

        guild_client.fire(:ready, nil)

        expect(guild_client.left_servers).to eq(["999"])
        notice = guild_client.guild_notices.first
        expect(notice[:text]).to eq(Rubotty::ControlPlane::JoinGuard::DEFAULT_NOTICE)
      end

      it "keeps a protected-by-title guild already in at connect, and records its channels" do
        guild_adapter
        guild_client.set_servers("888" => DiscordFakes::Server.new(id: "888", name: "Example Gaming Community"))
        guild_client.set_guild_channels("888", [{ id: "777001", name: "lobby" }])

        guild_client.fire(:ready, nil)

        expect(guild_client.left_servers).to be_empty
        expect(guild_client.guild_notices).to be_empty
      end

      it "sweeps every guild the connection reports, not just the first" do
        guild_adapter
        guild_client.set_servers(
          "999" => DiscordFakes::Server.new(id: "999", name: "Rando One"),
          "888" => DiscordFakes::Server.new(id: "888", name: "Example Gaming Community"),
          "997" => DiscordFakes::Server.new(id: "997", name: "Rando Two")
        )
        guild_client.set_guild_channels("999", [{ id: "1", name: "general" }])
        guild_client.set_guild_channels("888", [{ id: "2", name: "lobby" }])
        guild_client.set_guild_channels("997", [{ id: "3", name: "general" }])

        guild_client.fire(:ready, nil)

        expect(guild_client.left_servers).to contain_exactly("999", "997")
      end

      it "does not stop the sweep when one guild in it raises" do
        guild_adapter
        guild_client.set_servers(
          "999" => DiscordFakes::Server.new(id: "999", name: "Rando One"),
          "888" => DiscordFakes::Server.new(id: "888", name: "Example Gaming Community")
        )
        guild_client.set_guild_channels("888", [{ id: "2", name: "lobby" }])
        allow(guild_client).to receive(:guild_text_channels).and_wrap_original do |original, guild_id|
          raise StandardError, "boom" if guild_id.to_s == "999"

          original.call(guild_id)
        end

        expect { guild_client.fire(:ready, nil) }.not_to raise_error
        # The per-guild rescue means the guild after it is still evaluated.
        expect(guild_client.left_servers).to be_empty
      end

      it "does nothing when neither a join guard nor discovery is wired" do
        adapter = described_class.new(
          account: "discord", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: []
        ).replace_client(guild_client).tap(&:start)
        guild_client.set_servers("999" => DiscordFakes::Server.new(id: "999", name: "Rando Server"))

        expect(guild_client.handlers[:ready]).to be_nil
        expect { adapter.sweep_known_guilds }.not_to raise_error
      end

      # discordrb spawns a new thread per registered handler for the same
      # event, so bot.ready { sweep_known_guilds } and #start's wait for
      # READY have no ordering guarantee. The test forces the race by
      # clearing @own_account_id back to nil, the way the sweep would see it if it won.
      it "waits for own_account_id rather than reading it as nil when the sweep wins the race with #start" do
        guild_adapter
        guild_adapter.instance_variable_set(:@own_account_id, nil)
        guild_client.set_servers("999" => DiscordFakes::Server.new(id: "999", name: "Rando Server"))
        guild_client.set_guild_channels("999", [{ id: "123001", name: "general" }])
        Thread.new { sleep 0.05; guild_adapter.instance_variable_set(:@own_account_id, "bot-discord") }

        expect(guild_client).to receive(:guild_inviter).with("999", "bot-discord").and_call_original

        guild_client.fire(:ready, nil)
      end
    end

    # A guild's channel ids are what resolve a seeded connection's sentinel, so a
    # listing that could not be read has to stay distinguishable from a guild
    # with nothing in it. Read as emptiness it turns a core community into a
    # stranger, and the bot walks out of it for good.
    describe "when a guild's channels cannot be listed" do
      # The whole shape end to end, through the real client: the boot sweep
      # enumerates every guild at once, Discord throttles one of them, and the
      # guild it could not read is the community's own.
      it "keeps the seeded guild when the sweep's enumeration is rate limited" do
        require "rest-client"
        throttled = DiscordFakes::Gateway::Server.new(
          id: "70707070", name: "Totally Unrelated Name",
          listing_error: RestClient::TooManyRequests.new
        )
        real_client = Rubotty::Adapters::Discord::Client.new(token: "t", logger: Rubotty::Log.null)
        real_client.instance_variable_set(:@bot, DiscordFakes::Gateway::Bot.new("70707070" => throttled))
        adapter = described_class.new(
          account: "discord", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
          join_guard: join_guard, discovery: discovery
        ).replace_client(real_client)

        adapter.sweep_known_guilds

        expect(throttled.left?).to be(false)
        expect(discord_connection.reload.external_id).to start_with("unresolved:")
      end

      it "keeps a guild it cannot read rather than treating it as unowned" do
        guild_adapter
        guild_client.throttle_guild_channels("999")
        server = DiscordFakes::Server.new(id: "999", name: "Rando Server")

        decision = guild_client.fire(:server_create, DiscordFakes::ServerCreateEvent.new(server: server))

        expect(decision.stay?).to be(true)
        expect(guild_client.left_servers).to be_empty
        expect(guild_client.guild_notices).to be_empty
      end

      it "still leaves an unauthorized guild whose listing genuinely came back empty" do
        add_guild(guild_id: "999", name: "Rando Server", channels: [])

        expect(guild_client.left_servers).to eq(["999"])
      end

      it "keeps every guild in a sweep that is throttled across the board" do
        guild_adapter
        guild_client.set_servers(
          "999" => DiscordFakes::Server.new(id: "999", name: "Rando One"),
          "997" => DiscordFakes::Server.new(id: "997", name: "Rando Two")
        )
        guild_client.throttle_guild_channels("999")
        guild_client.throttle_guild_channels("997")

        guild_client.fire(:ready, nil)

        expect(guild_client.left_servers).to be_empty
      end

      it "records no channels for a guild it could not read" do
        guild_adapter
        guild_client.throttle_guild_channels("999")
        before = models.channel.count

        guild_client.fire(:server_create,
                          DiscordFakes::ServerCreateEvent.new(
                            server: DiscordFakes::Server.new(id: "999", name: "Rando Server")
                          ))

        expect(models.channel.count).to eq(before)
      end
    end

    # The first listing of a guild happens while its space is still pending, so
    # it has no platform connection and is dropped; approval asks again here.
    describe "re-enumerating one guild on demand (issue #584)" do
      it "declares the seam the approval flow reaches for" do
        expect(guild_adapter.supports_space_enumeration?).to be(true)
      end

      it "records the guild's channels against a connection that now exists" do
        discord_connection.update(external_id: "70707070")
        guild_client.set_guild_channels("70707070", [{ id: "900101", name: "late-arrival" }])

        expect(guild_adapter.enumerate_space("70707070")).to be(true)

        row = models.channel.where(adapter: "discord", route_key: "900101").first
        expect(row.label).to eq("late-arrival")
        expect(row.platform_connection_id).to eq(discord_connection.id)
      end

      it "refuses a blank guild id" do
        expect(guild_adapter.enumerate_space("")).to be(false)
      end

      it "reports failure rather than raising when the listing is refused" do
        allow(guild_client).to receive(:guild_text_channels).and_raise(StandardError, "missing access")

        expect(guild_adapter.enumerate_space("70707070")).to be(false)
      end
    end

    # A bot that cannot actually leave, for want of permission or through a
    # transient failure, posts the inert notice instead of silently sitting there.
    describe "when the leave call itself fails (#169)" do
      it "posts the inert fallback notice instead of silently staying" do
        guild_client.fail_next_leave(StandardError.new("missing permission"))
        add_guild(guild_id: "999", name: "Rando Server", channels: [{ id: "123001", name: "general" }])

        expect(guild_client.left_servers).to be_empty
        texts = guild_client.guild_notices.map { |notice| notice[:text] }
        expect(texts).to include(Rubotty::ControlPlane::JoinGuard::INERT_NOTICE)
      end

      it "posts the inert fallback notice only once per guild" do
        guild_client.fail_next_leave(StandardError.new("missing permission"))
        add_guild(guild_id: "999", name: "Rando Server", channels: [{ id: "123001", name: "general" }])
        guild_client.fail_next_leave(StandardError.new("missing permission"))
        add_guild(guild_id: "999", name: "Rando Server", channels: [{ id: "123001", name: "general" }])

        inert_count = guild_client.guild_notices.count do |notice|
          notice[:text] == Rubotty::ControlPlane::JoinGuard::INERT_NOTICE
        end
        expect(inert_count).to eq(1)
      end

      # discordrb answers nil for a guild it cannot resolve and nothing raises,
      # so a leave that never happened used to read as a completed one.
      it "posts the inert fallback for a guild the client could not find to leave" do
        guild_client.hide_guild_from_leave("999")
        add_guild(guild_id: "999", name: "Rando Server", channels: [{ id: "123001", name: "general" }])

        expect(guild_client.left_servers).to be_empty
        texts = guild_client.guild_notices.map { |notice| notice[:text] }
        expect(texts).to include(Rubotty::ControlPlane::JoinGuard::INERT_NOTICE)
      end
    end

    # The pending-space flow reads leave_space's answer as a confirmed
    # departure: on a true it stops nagging about the space and files it as
    # left, so a true it did not earn leaves the bot sitting in a guild the
    # board says it walked out of.
    describe "#leave_space" do
      it "confirms a leave it actually issued" do
        expect(guild_adapter.leave_space("999")).to be(true)
        expect(guild_client.left_servers).to eq(["999"])
      end

      it "denies a leave for a guild the client could not find" do
        guild_client.hide_guild_from_leave("999")

        expect(guild_adapter.leave_space("999")).to be(false)
        expect(guild_client.left_servers).to be_empty
      end

      it "denies a leave whose call raised" do
        guild_client.fail_next_leave(StandardError.new("missing permission"))

        expect(guild_adapter.leave_space("999")).to be(false)
      end

      it "still confirms a leave whose notice could not be posted" do
        allow(guild_client).to receive(:post_guild_notice).and_raise(StandardError.new("no perms"))

        expect(guild_adapter.leave_space("999", notice: "goodbye")).to be(true)
      end
    end

    # Who added the bot, the guild's name and a sample of its channel names,
    # carried on every decision in one shape for every platform.
    describe "the normalized join signal (#169)" do
      it "captures the inviter, title, and a channel sample on an unauthorized guild's decision" do
        guild_client.set_guild_inviter("999", { id: "42", username: "modmax", display_name: "Mod Max" })
        decision = add_guild(guild_id: "999", name: "Rando Server",
                             channels: [{ id: "123001", name: "general" }, { id: "123002", name: "off-topic" }])

        signal = decision.signal
        expect(signal.adapter).to eq(:discord)
        expect(signal.title).to eq("Rando Server")
        expect(signal.inviter).to be_a(Rubotty::Core::Author)
        expect(signal.inviter.username).to eq("modmax")
        expect(signal.inviter.display_name).to eq("Mod Max")
        expect(signal.channel_sample).to contain_exactly("general", "off-topic")
      end

      it "still carries a signal, with no inviter, when the audit log cannot say" do
        decision = add_guild(guild_id: "70707070", name: "Totally Unrelated Name",
                             channels: [{ id: seeded_channel_id, name: "general" }])

        expect(decision.signal.inviter).to be_nil
        expect(decision.signal.title).to eq("Totally Unrelated Name")
        expect(decision.signal.channel_sample).to eq(["general"])
      end
    end

    it "records a kept guild's unmapped channels so the mapping wizard lists them (#38)" do
      add_guild(guild_id: "70707070", name: "Totally Unrelated Name",
                channels: [{ id: seeded_channel_id, name: "general" }, { id: "900500", name: "new-chan" }])

      row = models.channel.where(adapter: "discord", route_key: "900500").first
      expect(row).not_to be_nil
      expect(row.label).to eq("new-chan")
      # Dormant: recorded but in no room, so it does not bridge until mapped.
      expect(models.room_channel.where(channel_id: row.id).count).to eq(0)
    end

    it "does not route a server_create as a normal message" do
      add_guild(guild_id: "999", name: "Rando", channels: [{ id: "123001", name: "general" }])
      expect(dispatcher.messages).to be_empty
    end

    describe "a new channel appearing (CHANNEL_CREATE, #39)" do
      before { discord_connection.update(external_id: "70707070") }

      def create_channel(id:, name:, guild_id: "70707070", **rest)
        server = DiscordFakes::Server.new(id: guild_id, name: "SAMPLE")
        channel = DiscordFakes::Channel.new(id: id, name: name, server: server, **rest)
        guild_adapter.handle_channel_created(DiscordFakes::ChannelCreateEvent.new(channel: channel))
      end

      it "prompts the operator and records a newly created channel in an opted-in community" do
        enable_alerts
        create_channel(id: "900600", name: "fresh-channel")

        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["900600"])
        expect(models.channel.where(route_key: "900600").count).to eq(1)
      end

      it "prompts by default, without an explicit opt-in" do
        create_channel(id: "900601", name: "fresh-channel")
        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["900601"])
      end

      it "learns nothing once a community explicitly opts out" do
        disable_alerts
        create_channel(id: "900603", name: "fresh-channel")
        expect(notifier.prompts).to be_empty
        expect(models.channel.where(route_key: "900603").first).to be_nil
      end

      it "ignores a channel that is not a guild text channel (a DM)" do
        enable_alerts
        create_channel(id: "900602", name: "dm", pm: true)
        expect(notifier.prompts).to be_empty
      end
    end

    it "registers no membership handler without a guard or discovery" do
      # The top-level adapter has neither, so server_create is never wired.
      plain = described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: []
      ).replace_client(guild_client)
      plain.start
      expect(guild_client.handlers[:server_create]).to be_nil
      expect(guild_client.handlers[:channel_create]).to be_nil
    end
  end

  describe "native scheduled events" do
    let(:with_guild) do
      endpoint("dc-general", adapter: :discord, community_id: 1,
                             settings: { channel_id: "8000000000000000003", guild_id: "guild-9" })
    end
    let(:guild_adapter) do
      described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [with_guild]
      ).replace_client(client)
    end

    def event_row(overrides = {})
      {
        id: 1, community_id: 10, room_id: 20, title: "Raid night",
        description: nil, timezone: "UTC", kind: "gaming",
        game_title: nil, server_address: "raid.example.com", url: nil,
        rsvp_mode: "full", status: "scheduled",
        reminder_intervals: nil, native_refs: "{}", created_by: "sample_owner",
        starts_at: Time.utc(2026, 8, 1, 20, 0, 0), ends_at: nil
      }.merge(overrides)
    end

    def rubotty_event(overrides = {}) = Rubotty::Events::Event.new(event_row(overrides))

    it "reports native event support" do
      expect(guild_adapter.supports_native_events?).to be(true)
    end

    it "creates a native scheduled event in the account's known guild" do
      native_id = guild_adapter.create_scheduled_event(rubotty_event, with_guild)

      expect(native_id).to eq("1")
      expect(client.created_scheduled_events.first[:guild_id]).to eq("guild-9")
      expect(client.created_scheduled_events.first[:payload][:name]).to eq("Raid night")
    end

    it "updates a native scheduled event in the account's known guild" do
      guild_adapter.update_scheduled_event("42", rubotty_event(title: "Raid night (moved)"), with_guild)

      recorded = client.updated_scheduled_events.first
      expect(recorded[:guild_id]).to eq("guild-9")
      expect(recorded[:event_id]).to eq("42")
      expect(recorded[:payload][:name]).to eq("Raid night (moved)")
    end

    it "deletes a native scheduled event in the account's known guild" do
      guild_adapter.delete_scheduled_event("42", with_guild)
      expect(client.deleted_scheduled_events).to eq([{ guild_id: "guild-9", event_id: "42" }])
    end

    it "reads native RSVPs shaped to identity/response pairs, carrying any name Discord sent" do
      allow(client).to receive(:scheduled_event_users).and_return(
        [{ "user" => { "id" => "111", "username" => "quill", "global_name" => "Quill Marlowe" } }]
      )
      expect(guild_adapter.read_native_rsvps("42", with_guild)).to eq(
        [{ identity: "111", response: "interested", username: "quill", display: "Quill Marlowe" }]
      )
    end

    # The top level subject bridges only `general`, which carries no guild_id,
    # and the fake client's channel for it carries no server either, matching
    # a gateway that has not (or cannot) resolve it.
    it "degrades to a no-op for an account with no known guild" do
      expect(adapter.create_scheduled_event(rubotty_event, general)).to be_nil
      expect(client.created_scheduled_events).to be_empty
    end

    it "converts an unexpected client failure into an AdapterError" do
      allow(client).to receive(:create_scheduled_event).and_raise(RuntimeError.new("discord boom"))
      expect { guild_adapter.create_scheduled_event(rubotty_event, with_guild) }
        .to raise_error(Rubotty::AdapterError, /discord boom/)
    end

    # A channel discovered live never carries a guild_id setting (see
    # ChannelDiscovery#addressing), so a scheduled event used to no-op
    # silently while the card still posted to chat. #known_guild_ids now
    # asks the live gateway instead of that setting, like #server_for already does.
    context "for a channel discovered live, with no guild_id setting at all" do
      let(:discovered) do
        endpoint("dc-discovered", adapter: :discord, settings: { channel_id: "42424242" })
      end
      let(:discovered_adapter) do
        described_class.new(
          account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [discovered]
        ).replace_client(client)
      end

      before { client.channel("42424242").server = DiscordFakes::Server.new(id: "guild-live", name: "Live Guild") }

      it "still resolves the guild live off the gateway and creates the native event" do
        native_id = discovered_adapter.create_scheduled_event(rubotty_event, discovered)

        expect(native_id).to eq("1")
        expect(client.created_scheduled_events.first[:guild_id]).to eq("guild-live")
      end
    end

    # Issue #1701: this bot bridges several real guilds through one shared
    # account, so #known_guild_ids.first is the wrong target for a room
    # that lives in any OTHER guild. Two endpoints on one adapter, each in
    # its own guild, is that shape in miniature; a one-guild fixture could never catch this.
    context "with two guilds bridged through one account" do
      let(:second) { endpoint("dc-second", adapter: :discord, settings: { channel_id: "11111111" }) }
      let(:sample) { endpoint("dc-sample", adapter: :discord, settings: { channel_id: "22222222" }) }
      let(:multi_guild_adapter) do
        described_class.new(
          account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [second, sample]
        ).replace_client(client)
      end

      before do
        client.channel("11111111").server = DiscordFakes::Server.new(id: "guild-second", name: "SECOND")
        client.channel("22222222").server = DiscordFakes::Server.new(id: "guild-sample", name: "SAMPLE")
      end

      it "creates in the SECOND guild when that room's own endpoint is passed" do
        native_id = multi_guild_adapter.create_scheduled_event(rubotty_event, sample)

        expect(native_id).to eq("1")
        expect(client.created_scheduled_events.first[:guild_id]).to eq("guild-sample")
      end

      it "creates in the FIRST guild too, proving the second case is not a coincidence" do
        multi_guild_adapter.create_scheduled_event(rubotty_event, second)
        expect(client.created_scheduled_events.first[:guild_id]).to eq("guild-second")
      end

      it "updates in the room's own guild, not whichever guild sorts first" do
        multi_guild_adapter.update_scheduled_event("42", rubotty_event, sample)
        expect(client.updated_scheduled_events.first[:guild_id]).to eq("guild-sample")
      end

      it "deletes in the room's own guild, not whichever guild sorts first" do
        multi_guild_adapter.delete_scheduled_event("42", sample)
        expect(client.deleted_scheduled_events).to eq([{ guild_id: "guild-sample", event_id: "42" }])
      end

      it "reads RSVPs from the room's own guild, not whichever guild sorts first" do
        allow(client).to receive(:scheduled_event_users).with("guild-sample", "42").and_return(
          [{ "user" => { "id" => "77", "username" => "quill" } }]
        )
        expect(multi_guild_adapter.read_native_rsvps("42", sample).first[:identity]).to eq("77")
      end

      # Issue #1701 left the no-endpoint call falling back to whichever guild
      # sorted first, and issue #1767 is what that shipped as: an event created
      # in one community announced into another. The fallback is gone, and the
      # call now refuses rather than guessing which tenant it meant.
      it "refuses a call made with no endpoint at all rather than guessing a guild" do
        expect { multi_guild_adapter.create_scheduled_event(rubotty_event, nil) }
          .to raise_error(Rubotty::AdapterError, /needs the room's own endpoint/)
        expect(client.created_scheduled_events).to be_empty
      end

      it "logs the guild a successful create resolved, closing the silent-success gap" do
        io = StringIO.new
        logged_adapter = described_class.new(
          account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.build(level: "info", io: io), endpoints: [second, sample]
        ).replace_client(client)

        logged_adapter.create_scheduled_event(rubotty_event, sample)

        expect(io.string).to include("guild-sample")
      end
    end
  end

  describe "channel management (issue #227)" do
    let(:with_guild) do
      endpoint("dc-general", adapter: :discord, community_id: 1,
                             settings: { channel_id: "8000000000000000003", guild_id: "guild-9" })
    end
    let(:guild_adapter) do
      described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [with_guild]
      ).replace_client(client)
    end

    it "reports real support" do
      expect(guild_adapter.supports_channel_management?).to be(true)
    end

    it "creates a channel in the account's known guild" do
      native_id = guild_adapter.create_channel(name: "Gaming & Scheduling", community_id: 1)

      expect(native_id).to eq("created-channel-1")
      expect(client.created_guild_channels).to eq(
        [{ guild_id: "guild-9", name: "Gaming & Scheduling", template_id: nil }]
      )
    end

    it "passes a template id through so the client can copy its category" do
      guild_adapter.create_channel(name: "Gaming", community_id: 1, template: "8000000000000000003")
      expect(client.created_guild_channels.first[:template_id]).to eq("8000000000000000003")
    end

    it "degrades to no channel created for an account with no known guild" do
      expect(adapter.create_channel(name: "Gaming", community_id: 1)).to be_nil
      expect(client.created_guild_channels).to be_empty
    end

    # Issues #1701 and #1782: create_channel kept the deployment-wide guess on
    # a line of its own, so the scheduled-event fix left it standing. Nothing
    # can resolve against the new channel's own room, so a template resolves
    # the guild exactly and the asking community resolves it otherwise.
    context "with two communities' guilds bridged through one account" do
      let(:second) do
        endpoint("dc-second", adapter: :discord, settings: { channel_id: "11111111" }, community_id: 3)
      end
      let(:sample) do
        endpoint("dc-sample", adapter: :discord, settings: { channel_id: "22222222" }, community_id: 1)
      end
      let(:multi_guild_adapter) do
        described_class.new(
          account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [second, sample]
        ).replace_client(client)
      end

      before do
        client.channel("11111111").server = DiscordFakes::Server.new(id: "guild-second", name: "SECOND")
        client.channel("22222222").server = DiscordFakes::Server.new(id: "guild-sample", name: "SAMPLE")
      end

      it "creates the channel in the TEMPLATE's own guild" do
        multi_guild_adapter.create_channel(name: "New Room", community_id: 1, template: "22222222")
        expect(client.created_guild_channels.first[:guild_id]).to eq("guild-sample")
      end

      # Inverted from "falls back to the first-sorting guild only when no
      # template is given at all", which is the leak itself: second sorts first,
      # so that is exactly what a template-less create for sample used to pick.
      it "falls back to the guild of the community being provisioned for" do
        multi_guild_adapter.create_channel(name: "New Room", community_id: 1)
        expect(client.created_guild_channels.first[:guild_id]).to eq("guild-sample")
      end

      it "refuses a template naming a channel in another community's guild" do
        created = multi_guild_adapter.create_channel(name: "New Room", community_id: 1, template: "11111111")

        expect(created).to be_nil
        expect(client.created_guild_channels).to be_empty
      end
    end

    it "deletes a channel by native id" do
      expect(guild_adapter.delete_channel("42", community_id: 1)).to be(true)
      expect(client.deleted_guild_channels).to eq(["42"])
    end

    it "copies permission overwrites from one channel onto another" do
      client.set_permission_overwrites("8000000000000000003", [{ id: "role-1", allow: 1024, deny: 0 }])

      expect(guild_adapter.copy_channel_permissions(from: "8000000000000000003", to: "created-channel-1"))
        .to be(true)
      expect(client.copied_permission_overwrites).to eq(
        [{ from: "8000000000000000003", to: "created-channel-1",
           overwrites: [{ id: "role-1", allow: 1024, deny: 0 }] }]
      )
    end

    it "reports nothing copied when the source channel has no overwrites" do
      expect(guild_adapter.copy_channel_permissions(from: "8000000000000000003", to: "created-channel-1"))
        .to be(false)
    end
  end

  describe "#render_timestamp" do
    let(:time) { Time.utc(2026, 8, 1, 20, 0, 0) }

    it "renders Discord's own markup, needing no tz" do
      expect(adapter.render_timestamp(time)).to eq("<t:#{time.to_i}:F>")
    end

    it "renders the relative style as Discord's own countdown token" do
      expect(adapter.render_timestamp(time, style: :relative)).to eq("<t:#{time.to_i}:R>")
    end

    it "renders both tokens together for :both" do
      expect(adapter.render_timestamp(time, style: :both)).to eq("<t:#{time.to_i}:F> <t:#{time.to_i}:R>")
    end
  end

  describe "the native-event gateway hook (issue #184)" do
    it "registers a catch-all handler for a dispatch discordrb does not otherwise turn into an event" do
      adapter.start
      expect(client.handlers[:unknown]).not_to be_nil
    end

    it "normalizes a GUILD_SCHEDULED_EVENT_CREATE dispatch and hands it to a registered listener" do
      changes = []
      adapter.on_native_event_change { |change| changes << change }
      adapter.start

      data = {
        "id" => "999", "guild_id" => "guild-9", "name" => "Raid night",
        "scheduled_start_time" => "2026-08-01T20:00:00.000000+00:00",
        "scheduled_end_time" => "2026-08-01T23:00:00.000000+00:00", "status" => 1
      }
      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "GUILD_SCHEDULED_EVENT_CREATE", data: data))

      expect(changes.size).to eq(1)
      change = changes.first
      expect(change).to be_a(Rubotty::Events::NativeEventChange)
      expect(change.created?).to be(true)
      expect(change.native_id).to eq("999")
      expect(change.guild_id).to eq("guild-9")
      expect(change.title).to eq("Raid night")
      expect(change.status).to eq(:scheduled)
      expect(change.starts_at).to eq(Time.utc(2026, 8, 1, 20, 0, 0))
    end

    it "recognizes update and delete dispatches too" do
      changes = []
      adapter.on_native_event_change { |change| changes << change }
      adapter.start

      base = { "id" => "999", "guild_id" => "guild-9", "name" => "Raid night", "status" => 4 }
      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "GUILD_SCHEDULED_EVENT_UPDATE", data: base))
      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "GUILD_SCHEDULED_EVENT_DELETE", data: base))

      expect(changes.map(&:action)).to eq(%i[updated deleted])
      expect(changes.last.status).to eq(:cancelled)
    end

    it "ignores an unrelated unknown dispatch" do
      changes = []
      adapter.on_native_event_change { |change| changes << change }
      adapter.start

      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "SOME_OTHER_DISPATCH", data: {}))

      expect(changes).to be_empty
    end

    it "names the dispatch type at debug rather than dropping it with no trace" do
      logs = StringIO.new
      logging_adapter = described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.build(level: "debug", io: logs),
        endpoints: [general]
      ).replace_client(client)
      logging_adapter.start

      client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "SOME_OTHER_DISPATCH", data: {}))

      expect(logs.string).to include("SOME_OTHER_DISPATCH")
    end

    it "never raises out, even when a listener itself blows up" do
      adapter.on_native_event_change { |_change| raise "listener boom" }
      adapter.start

      data = { "id" => "999", "guild_id" => "guild-9", "name" => "Raid night" }
      expect do
        client.fire(:unknown, DiscordFakes::UnknownEvent.new(type: "GUILD_SCHEDULED_EVENT_CREATE", data: data))
      end.not_to raise_error
    end
  end
end

RSpec.describe Rubotty::Adapters::Discord::Adapter, "direct messages to an operator" do
  let(:client) { DiscordFakes::Client.new }
  let(:general) do
    endpoint("dc-general", adapter: :discord,
                           settings: { channel_id: "8000000000000000003", webhook: :off })
  end

  subject(:adapter) do
    described_class.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
      endpoints: [general]
    ).replace_client(client)
  end

  it "says it can, so the callers that check first will use it" do
    expect(adapter.supports_admin_dm?).to be(true)
  end

  it "sends the message to the id it was given, and hands back a receipt" do
    receipt = adapter.send_admin_dm("55", "a room needs you")

    expect(client.direct_messages).to eq([{ native_id: "55", text: "a room needs you" }])
    expect(receipt).to be_a(Rubotty::Core::DmReceipt)
    expect(receipt.native_id).not_to be_empty
    expect(receipt.channel_ref).not_to be_nil
  end

  # Discord refuses when the recipient shares no guild with the bot or has DMs
  # from server members off.
  it "answers nil for somebody it cannot reach, rather than raising" do
    client.unreachable!("99")

    expect { expect(adapter.send_admin_dm("99", "hello")).to be_nil }.not_to raise_error
  end

  it "sends nothing for an empty message" do
    expect(adapter.send_admin_dm("55", "   ")).to be_nil
    expect(client.direct_messages).to be_empty
  end

  # A DM channel is a channel like any other, so deleting one is the ordinary
  # channel-message delete.
  describe "#delete_admin_dm" do
    it "says it can, so callers know the DM is worth making ephemeral" do
      expect(adapter.supports_admin_dm_delete?).to be(true)
    end

    it "deletes the message the receipt points at" do
      receipt = adapter.send_admin_dm("55", "a room needs you")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
      expect(client.channel(receipt.channel_ref).load_message(receipt.native_id).deleted).to be(true)
    end

    it "counts an already-gone message as deleted rather than a failure" do
      receipt = adapter.send_admin_dm("55", "a room needs you")
      client.channel(receipt.channel_ref).load_message(receipt.native_id).delete

      expect(adapter.delete_admin_dm(receipt)).to be(true)
    end

    it "is falsy for a receipt with nothing to delete" do
      expect(adapter.delete_admin_dm(nil)).to be(false)
    end
  end
end

# For RehostedFiles' download-serve ceiling; see ControlPlane::CommunityMembers.
# Public so a control-plane service outside the adapter can reach it, unlike
# the pending-card read it wraps.
RSpec.describe Rubotty::Adapters::Discord::Adapter, "#community_member_count" do
  let(:client) { DiscordFakes::Client.new }
  let(:adapter) do
    described_class.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).replace_client(client)
  end

  it "answers the gateway's live count for a known guild" do
    client.set_member_count("70707070", 812)

    expect(adapter.community_member_count("70707070")).to eq(812)
  end

  it "answers nil for a guild the gateway has no cached view of" do
    expect(adapter.community_member_count("unknown-guild")).to be_nil
  end
end
