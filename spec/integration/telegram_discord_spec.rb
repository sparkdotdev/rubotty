# frozen_string_literal: true

require "spec_helper"

# Telegram on one side, Discord on the other, wired through the actual runtime,
# to catch the wiring mistakes unit tests structurally cannot see.
RSpec.describe "a Telegram and Discord room" do
  let(:yaml) do
    <<~YAML
      name: integration
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
        dc:
          adapter: discord
          token_env: DC_TOKEN
      storage:
        driver: memory
      behaviour:
        message_ttl: 1 hour
        log_level: fatal
      display_name:
        format: "{first_name} ({username})"
        fallback_format: "{first_name}"
      operators:
        - name: Alex
          identities:
            telegram: ["55"]
      rooms:
        - id: lounge
          endpoints:
            - id: tg-lounge
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
            - id: dc-lounge
              adapter: discord
              account: dc
              channel_id: "8000000000000000003"
    YAML
  end

  let(:tg_http) { Fakes::TelegramHttp.new }
  let(:dc_client) { DiscordFakes::Client.new(own_id: "bot-dc") }
  let(:config) do
    Rubotty::Config::Loader.load_string(
      yaml, env: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token" }
    )
  end
  let(:runtime) { Rubotty::Core::Runtime.new(config: config, logger: Rubotty::Log.null) }

  let(:tg_adapter) { runtime.adapters[[:telegram, "tg"]] }
  let(:dc_adapter) { runtime.adapters[[:discord, "dc"]] }
  let(:tg_endpoint) { config.topology.endpoint("tg-lounge") }
  let(:dc_endpoint) { config.topology.endpoint("dc-lounge") }
  let(:channel) { dc_client.channel("8000000000000000003") }
  let(:ada) { DiscordFakes.user(id: "77", username: "ada", global_name: "Ada L") }

  before do
    tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
    tg_http.default_result([])
    runtime.build
    tg_adapter.replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
    )
    dc_adapter.replace_client(dc_client)
    runtime.dispatcher.start
    runtime.loop_guard.register_identity(:telegram, "tg", tg_adapter.identify)
    dc_adapter.start
    runtime.loop_guard.register_identity(:discord, "dc", dc_adapter.own_account_id)
  end

  after { runtime.stop }

  def from_telegram(overrides = {})
    tg_adapter.handle_update(
      {
        "update_id" => 1,
        "message" => {
          "message_id" => 700,
          "date" => 1_700_000_000,
          "chat" => { "id" => -1008000000001, "type" => "supergroup" },
          "from" => { "id" => 55, "first_name" => "Alex", "username" => "alex", "is_bot" => false },
          "text" => "hello from telegram"
        }.merge(overrides)
      }
    )
    settled!
  end

  def from_discord(message)
    dc_adapter.emit_if(
      dc_adapter.instance_variable_get(:@inbound).message(
        DiscordFakes::MessageEvent.new(message: message, channel: channel)
      )
    )
    settled!
  end

  # Wait for the bridge, and say so when the wait ran out: a drain that gives up
  # leaves the assertions reading a bridge that has not finished delivering.
  def settled!
    expect(runtime.dispatcher.drain).to be(true)
  end

  describe "Telegram to Discord" do
    it "relays a message" do
      tg_http.on("sendMessage", { "message_id" => 900 })
      from_telegram
      expect(channel.sent.first[:content]).to include("hello from telegram")
    end

    it "renders the sender with the configured template" do
      from_telegram
      expect(channel.sent.first[:content]).to include("Alex (alex)")
    end

    it "converts Telegram entities into Discord markdown" do
      from_telegram(
        "text" => "🎉 party time",
        "entities" => [{ "type" => "bold", "offset" => 3, "length" => 5 }]
      )
      # Offsets survive the emoji, and bold becomes Discord markup.
      expect(channel.sent.first[:content]).to include("**party**")
    end

    it "suppresses mass mentions from relayed text" do
      from_telegram("text" => "@everyone look")
      # Nothing resolved the @everyone, so the whitelist names nobody and parse is
      # empty: the token survives as text but cannot ping.
      expect(channel.sent.first[:allowed_mentions]).to eq(parse: [], users: [], roles: [])
    end
  end

  describe "Discord to Telegram" do
    it "relays a message" do
      tg_http.on("sendMessage", { "message_id" => 900 })
      from_discord(DiscordFakes::Message.new(id: "800", content: "hello from discord", author: ada))
      expect(tg_http.last("sendMessage").params["text"]).to include("hello from discord")
    end

    it "converts Discord markdown into Telegram HTML" do
      tg_http.on("sendMessage", { "message_id" => 900 })
      from_discord(DiscordFakes::Message.new(id: "800", content: "a **bold** word", author: ada))
      expect(tg_http.last("sendMessage").params["text"]).to include("<b>bold</b>")
    end

    it "propagates a delete, which is the direction Telegram cannot report" do
      tg_http.on("sendMessage", { "message_id" => 900 })
      from_discord(DiscordFakes::Message.new(id: "800", content: "oops", author: ada))
      dc_adapter.emit_if(
        dc_adapter.instance_variable_get(:@inbound).delete(
          DiscordFakes::DeleteEvent.new(id: "800", channel: channel)
        )
      )
      settled!
      expect(tg_http.last("deleteMessage").params["message_id"]).to eq(900)
    end
  end

  describe "loop prevention across two real adapters" do
    it "does not relay a message the bridge itself posted on Discord" do
      bot = DiscordFakes.user(id: "bot-dc", username: "bridgebot", bot_account: true)
      from_discord(DiscordFakes::Message.new(id: "801", content: "Alex (alex): hi", author: bot))
      expect(tg_http.called?("sendMessage")).to be(false)
    end

    it "does not relay a Telegram message the bridge itself posted" do
      from_telegram("from" => { "id" => 424_242, "first_name" => "bridgebot", "is_bot" => true })
      expect(channel.sent).to be_empty
    end
  end

  describe "reactions across platforms" do
    before do
      tg_http.on("sendMessage", { "message_id" => 900 })
      from_telegram
      tg_http.requests.clear
    end

    it "mirrors a Discord reaction onto the Telegram original" do
      dc_adapter.emit_if(
        dc_adapter.instance_variable_get(:@inbound).reaction(
          DiscordFakes::ReactionEvent.new(
            message_id: "900", channel: channel, user: ada,
            emoji: DiscordFakes::Emoji.new(id: nil, name: "👍")
          ), :reaction_add
        )
      )
      settled!
      # Discord's copy maps back to the Telegram original, so the reaction lands
      # there rather than on the Discord message.
      expect(tg_http.called?("setMessageReaction")).to be(false)
    end

    it "mirrors a Telegram reaction onto the Discord copy" do
      target = channel.store(DiscordFakes::Message.new(id: "sent-1", content: "x", author: ada))
      tg_adapter.handle_update(
        {
          "update_id" => 2,
          "message_reaction" => {
            "chat" => { "id" => -1008000000001 },
            "message_id" => 700,
            "user" => { "id" => 55, "first_name" => "Alex" },
            "date" => 1_700_000_100,
            "old_reaction" => [],
            "new_reaction" => [{ "type" => "emoji", "emoji" => "👍" }]
          }
        }
      )
      settled!
      expect(target.reactions).to eq(["👍"])
    end

    # A chat whose reactions are anonymous sends this INSTEAD of
    # message_reaction, and it names nobody, so nothing about it goes down the
    # per-person path. Without it such a chat relays no reaction at all.
    it "mirrors an anonymous reaction count onto the Discord copy" do
      target = channel.store(DiscordFakes::Message.new(id: "sent-1", content: "x", author: ada))
      tg_adapter.handle_update(
        {
          "update_id" => 3,
          "message_reaction_count" => {
            "chat" => { "id" => -1008000000001 },
            "message_id" => 700,
            "date" => 1_700_000_100,
            "reactions" => [
              { "type" => { "type" => "emoji", "emoji" => "🤣" }, "total_count" => 4 },
              { "type" => { "type" => "emoji", "emoji" => "🤔" }, "total_count" => 1 }
            ]
          }
        }
      )
      settled!
      expect(target.reactions).to contain_exactly("🤣", "🤔")
    end

    # The reaction rows carry the message TTL, so the row holding the mappable emoji ages
    # out while the emoji itself is still on the Telegram message. The next reaction then
    # recomputes desired as the unshowable one alone with previous empty, so an empty
    # setMessageReaction there deletes an emoji nobody asked to take off.
    describe "an emoji Telegram cannot show, after the mappable one has expired" do
      def react_on_discord(emoji)
        dc_adapter.emit_if(
          dc_adapter.instance_variable_get(:@inbound).reaction(
            DiscordFakes::ReactionEvent.new(
              message_id: "sent-1", channel: channel, user: ada,
              emoji: DiscordFakes::Emoji.new(id: nil, name: emoji)
            ), :reaction_add
          )
        )
        settled!
      end

      # Age the stored row out by rewriting its expiry, which is what the TTL
      # does on its own once enough time has passed.
      def expire_the_thumbs_up
        runtime.storage.add_reaction(
          Rubotty::Core::MessageRef.new("dc-lounge", "sent-1"),
          reaction: Rubotty::Core::Reaction.new(emoji: "👍"), actor_id: "77",
          expires_at: Time.now - 1
        )
      end

      before do
        channel.store(DiscordFakes::Message.new(id: "sent-1", content: "x", author: ada))
        react_on_discord("👍")
      end

      it "mirrors the mappable one first" do
        expect(tg_http.last("setMessageReaction").params["reaction"])
          .to eq([{ "type" => "emoji", "emoji" => "👍" }])
      end

      it "leaves that emoji on the Telegram message rather than erasing it" do
        expire_the_thumbs_up
        react_on_discord("🥑")
        expect(tg_http.calls("setMessageReaction").size).to eq(1)
      end
    end

    it "takes an anonymous mirror away once nobody is counted holding it" do
      target = channel.store(DiscordFakes::Message.new(id: "sent-1", content: "x", author: ada))
      %w[4 5].each_with_index do |update_id, index|
        tg_adapter.handle_update(
          {
            "update_id" => update_id.to_i,
            "message_reaction_count" => {
              "chat" => { "id" => -1008000000001 },
              "message_id" => 700,
              "date" => 1_700_000_100 + index,
              "reactions" => index.zero? ? [{ "type" => { "type" => "emoji", "emoji" => "🤣" },
                                              "total_count" => 4 }] : []
            }
          }
        )
        settled!
      end
      expect(target.reactions).to be_empty
    end
  end

  describe "moderation" do
    before do
      tg_http.on("sendMessage", { "message_id" => 900 })
      from_telegram
      channel.store(DiscordFakes::Message.new(id: "sent-1", content: "x", author: ada))
    end

    # The whole point: one command, both platforms.
    it "deletes on every endpoint when an operator asks" do
      tg_http.on("sendMessage", { "message_id" => 901 })
      from_telegram(
        "message_id" => 701,
        "text" => "/delete",
        "reply_to_message" => { "message_id" => 700 }
      )
      expect(channel.load_message("sent-1").deleted).to be(true)
      # Acting at once also removes the /delete invocation itself (701),
      # alongside the moderated target (700), so both calls land, not just one.
      deleted_ids = tg_http.calls("deleteMessage").map { |request| request.params["message_id"] }
      expect(deleted_ids).to include(700, 701)
    end

    it "does nothing for someone who is not an operator" do
      from_telegram(
        "message_id" => 702,
        "text" => "/delete",
        "from" => { "id" => 999, "first_name" => "Nobody" },
        "reply_to_message" => { "message_id" => 700 }
      )
      expect(channel.load_message("sent-1").deleted).to be(false)
    end

    it "never relays the command itself as a message" do
      before_count = channel.sent.size
      from_telegram(
        "message_id" => 703,
        "text" => "/delete",
        "reply_to_message" => { "message_id" => 700 }
      )
      relayed = channel.sent[before_count..].map { |m| m[:content] }
      expect(relayed.grep(/\/delete/)).to be_empty
    end
  end
end
