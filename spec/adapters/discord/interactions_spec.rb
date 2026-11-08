# frozen_string_literal: true

require "spec_helper"

# The bot's commands registered as Discord application commands, with an
# invocation routed into the same dispatch a "!" text command uses. Driven
# against the fake client, so there is no gateway and no discordrb.
RSpec.describe Rubotty::Adapters::Discord::Interactions do
  let(:dc) do
    endpoint("dc", adapter: :discord, account: "acc",
                   settings: { channel_id: "chan-1", guild_id: "guild-9" })
  end
  let(:client) { DiscordFakes::Client.new }
  let(:emitted) { [] }
  let(:responses) { [] }
  let(:endpoint_for) { ->(channel_id) { channel_id.to_s == "chan-1" ? dc : nil } }

  subject(:interactions) do
    described_class.new(
      client: client, endpoint_for: endpoint_for,
      emit: ->(message) { emitted << message }, logger: Rubotty::Log.null
    )
  end

  def interaction(name, options: {}, channel_id: "chan-1", nickname: nil, display_name: "Mod")
    described_class::Interaction.new(
      name: name, channel_id: channel_id, guild_id: "guild-9",
      user: described_class::User.new(id: "555", username: "mod", nickname: nickname, display_name: display_name),
      options: options, responder: ->(text) { responses << text }
    )
  end

  describe "#definitions" do
    it "produces one definition per registered command" do
      expect(interactions.definitions.map(&:name)).to eq(Rubotty::Core::CommandRegistry.room_commands.map(&:name))
      expect(interactions.definitions.map(&:name)).to include("delete", "ban", "pin")
    end

    it "gates each moderator command to its matching native permission" do
      by_name = interactions.definitions.to_h { |definition| [definition.name, definition] }
      expect(by_name["delete"].default_member_permissions).to eq(described_class::MANAGE_MESSAGES)
      expect(by_name["ban"].default_member_permissions).to eq(described_class::BAN_MEMBERS)
      expect(by_name["kick"].default_member_permissions).to eq(described_class::KICK_MEMBERS)
      expect(by_name["mute"].default_member_permissions).to eq(described_class::MODERATE_MEMBERS)
    end

    it "gives a message command a required message-id option" do
      option = interactions.definitions.find { |d| d.name == "delete" }.options.first
      expect(option.name).to eq("message_id")
      expect(option.type).to eq(:message)
      expect(option.required).to be(true)
    end

    it "gives a user command a required member option, then its own arguments" do
      options = interactions.definitions.find { |d| d.name == "mute" }.options
      expect(options.map(&:name)).to eq(%w[user minutes])
      expect(options.first.type).to eq(:user)
      expect(options.last.required).to be(false)
    end
  end

  let(:command_count) { Rubotty::Core::CommandRegistry.room_commands.size }

  describe "#register_commands" do
    it "registers the whole set per guild when a guild is known" do
      interactions.register_commands(["guild-9"])

      expect(client.registered_commands.size).to eq(command_count)
      expect(client.registered_commands.map { |r| r[:guild_id] }.uniq).to eq(["guild-9"])
    end

    it "falls back to a single global registration when no guild is known" do
      interactions.register_commands([])

      expect(client.registered_commands.size).to eq(command_count)
      expect(client.registered_commands.map { |r| r[:guild_id] }.uniq).to eq([nil])
    end

    it "swallows a registration Discord rejects rather than failing to start" do
      allow(client).to receive(:register_application_command).and_raise(RuntimeError.new("boom"))
      expect { interactions.register_commands(["guild-9"]) }.not_to raise_error
    end

    # A command registered globally on an earlier boot is never touched by
    # per-guild registration and would linger with no handler bound to it.
    it "prunes a stale global command not in the current registry" do
      client.set_existing_global_commands(
        [{ id: "stale-1", name: "chatinfo" }, { id: "current-1", name: "delete" }]
      )

      interactions.register_commands(["guild-9"])

      expect(client.pruned_global_command_ids).to eq(["stale-1"])
    end

    it "does not fail registration when pruning stale globals errors" do
      allow(client).to receive(:prune_stale_global_commands).and_raise(RuntimeError.new("boom"))
      expect { interactions.register_commands(["guild-9"]) }.not_to raise_error
    end
  end

  describe "#register_handlers" do
    it "wires a handler for every command that routes into #handle" do
      interactions.register_handlers
      expect(client.command_handlers.keys).to match_array(Rubotty::Core::CommandRegistry.room_commands.map(&:name))

      client.invoke("delete", interaction("delete", options: { "message_id" => "900" }))
      expect(emitted.size).to eq(1)
    end

    # Discord raises the generic interaction event for every command
    # interaction, so this fires for known commands too, which their own
    # handlers have already answered.
    describe "the unknown-command catch-all" do
      it "answers a command Discord still has registered that the registry no longer defines" do
        interactions.register_handlers

        client.invoke_unknown(interaction("chatinfo"))

        expect(responses).to eq(["That command is not available."])
        expect(emitted).to be_empty
      end

      it "leaves a known command's own handler to answer it, once" do
        interactions.register_handlers

        client.invoke("delete", interaction("delete", options: { "message_id" => "900" }))
        client.invoke_unknown(interaction("delete", options: { "message_id" => "900" }))

        expect(responses).to eq(["Acknowledged, deleting this message."])
      end
    end
  end

  describe "#handle" do
    it "turns a message command into a canonical /command message with the target as a reply" do
      interactions.handle(interaction("delete", options: { "message_id" => "900" }))

      message = emitted.first
      expect(message.kind).to eq(:chat)
      expect(message.origin).to eq(dc)
      expect(message.body.text).to eq("/delete")
      expect(message.author.native_id).to eq("555")
      expect(message.reply_to).to eq(Rubotty::Core::MessageRef.new("dc", "900"))
    end

    it "carries the guild nickname and global display name as two separate author fields" do
      interactions.handle(interaction("delete", options: { "message_id" => "900" },
                                                 nickname: "Sammy", display_name: "Sam Global"))

      author = emitted.first.author
      expect(author.nickname).to eq("Sammy")
      expect(author.display_name).to eq("Sam Global")
    end

    it "leaves the author's nickname nil when the member set none" do
      interactions.handle(interaction("delete", options: { "message_id" => "900" }, nickname: nil))

      expect(emitted.first.author.nickname).to be_nil
    end

    it "carries a user command's arguments as words and its target as the reply author" do
      interactions.handle(interaction("mute", options: { "user" => "777", "minutes" => 30 }))

      message = emitted.first
      expect(message.body.text).to eq("/mute 30")
      expect(message.reply_preview.author.native_id).to eq("777")
      # A user action has no literal reply, so a sentinel ref stands in for the parser.
      expect(message.reply_to).not_to be_nil
    end

    # The regression this whole feature exists for: /event's arguments are
    # marked `keyed:` in Core::CommandRegistry so several separate Discord
    # options come back as the SAME "key=value" text a person would type by
    # hand, rather than losing every field name the way a bare space-join used to.
    describe "a keyed argument (the /event fix)" do
      it "reconstructs each filled option as name=value, one word per argument" do
        interactions.handle(interaction("event", options: {
                                           "title" => "Standup", "start" => "2026-07-25 09:00", "kind" => "general"
                                         }))

        expect(emitted.first.body.text).to eq('/event title=Standup start="2026-07-25 09:00" kind=general')
      end

      it "quotes a value with a space so it survives as one token" do
        interactions.handle(interaction("event", options: {
                                           "title" => "Friday Raid Night", "start" => "2026-07-25 20:00",
                                           "kind" => "gaming"
                                         }))

        expect(Shellwords.split(emitted.first.body.text)).to eq(
          ["/event", "title=Friday Raid Night", "start=2026-07-25 20:00", "kind=gaming"]
        )
      end

      it "omits a blank or missing keyed option entirely, rather than an empty name= word" do
        interactions.handle(interaction("event", options: { "title" => "Standup", "start" => "", "kind" => "general" }))

        expect(emitted.first.body.text).to eq("/event title=Standup kind=general")
      end

      it "leaves an unkeyed argument's value bare, unchanged from before this feature" do
        interactions.handle(interaction("rsvp", options: { "id" => 4, "response" => "yes" }))

        expect(emitted.first.body.text).to eq("/rsvp 4 yes")
      end

      # /poll mixes a bare (unkeyed) question argument with a keyed
      # reply_options override, unlike /event's all-keyed shape: this proves
      # the two reconstruct as separate words rather than the boolean
      # colliding with the question text.
      it "appends /poll's keyed reply_options after its bare question, as its own word" do
        interactions.handle(interaction("poll", options: {
                                           "question" => "Which map? | Dust II | Inferno",
                                           "reply_options" => true
                                         }))

        expect(emitted.first.body.text).to eq("/poll Which map? | Dust II | Inferno reply_options=true")
      end

      it "omits /poll's reply_options word entirely when the picker left it blank" do
        interactions.handle(interaction("poll", options: { "question" => "Which map? | Dust II | Inferno" }))

        expect(emitted.first.body.text).to eq("/poll Which map? | Dust II | Inferno")
      end

      it "appends /poll's keyed duration alongside reply_options, both as their own words" do
        interactions.handle(interaction("poll", options: {
                                           "question" => "Which map? | Dust II | Inferno",
                                           "reply_options" => true, "duration" => "12h"
                                         }))

        expect(emitted.first.body.text).to eq("/poll Which map? | Dust II | Inferno reply_options=true duration=12h")
      end

      it "appends /poll's keyed multi_select the same way as its other keyed overrides" do
        interactions.handle(interaction("poll", options: {
                                           "question" => "Which map? | Dust II | Inferno",
                                           "multi_select" => true
                                         }))

        expect(emitted.first.body.text).to eq("/poll Which map? | Dust II | Inferno multi_select=true")
      end

      # /schedule mirrors /event's shape: every field keyed, so the native
      # picker gives a labelled box per field instead of one free-text box.
      it "keys every /schedule field, times included, the same way /event does" do
        interactions.handle(interaction("schedule", options: {
                                           "name" => "Raid night", "game" => "Deep Rock Galactic",
                                           "times" => "tuesday 7pm | wednesday 7pm", "duration" => "48h"
                                         }))

        expect(Shellwords.split(emitted.first.body.text)).to eq(
          ["/schedule", "name=Raid night", "game=Deep Rock Galactic",
           "times=tuesday 7pm | wednesday 7pm", "duration=48h"]
        )
      end

      it "omits /schedule's duration word entirely when the picker left it blank" do
        interactions.handle(interaction("schedule", options: {
                                           "name" => "Raid night", "game" => "Deep Rock Galactic",
                                           "times" => "tuesday 7pm | wednesday 7pm"
                                         }))

        expect(Shellwords.split(emitted.first.body.text)).to eq(
          ["/schedule", "name=Raid night", "game=Deep Rock Galactic", "times=tuesday 7pm | wednesday 7pm"]
        )
      end
    end

    it "acknowledges privately with the native ephemeral reply" do
      interactions.handle(interaction("delete", options: { "message_id" => "900" }))
      expect(responses).to eq(["Acknowledged, deleting this message."])
    end

    it "does nothing but answer when the command is not registered" do
      interactions.handle(interaction("frobnicate"))
      expect(emitted).to be_empty
      expect(responses).to eq(["That command is not available."])
    end

    it "answers and dispatches nothing when the channel is not bridged" do
      interactions.handle(interaction("delete", options: { "message_id" => "900" }, channel_id: "other"))
      expect(emitted).to be_empty
      expect(responses).to eq(["Commands are not available in this channel."])
    end
  end

  describe "wired into the Discord adapter" do
    let(:dispatcher) { Fakes::RecordingDispatcher.new }
    let(:adapter) do
      Rubotty::Adapters::Discord::Adapter.new(
        account: "acc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [dc]
      ).replace_client(client)
    end

    # Registration runs on its own thread now, so a rate-limited one cannot
    # hold up the rest of boot behind Runtime#start's join. What gets
    # registered, and per which guild, is unchanged.
    it "registers the slash commands per configured guild on start" do
      adapter.start
      adapter.instance_variable_get(:@slash_registration)&.join(5)

      expect(client.registered_commands.map { |r| r[:guild_id] }.uniq).to eq(["guild-9"])
    end

    it "routes an invoked slash command through the dispatcher, as a text command would" do
      adapter.start
      client.invoke("delete", interaction("delete", options: { "message_id" => "900" }))

      expect(dispatcher.messages.size).to eq(1)
      expect(dispatcher.messages.first.body.text).to eq("/delete")
      expect(responses).to eq(["Acknowledged, deleting this message."])
    end

    # A thread is never itself a mapped endpoint (only its parent channel is),
    # and an ordinary message resolves through the parent's parent_id
    # fallback. A slash command invoked in that thread carries only the
    # thread's own channel id, and used to miss because it skipped that fallback.
    it "resolves a slash command invoked inside a bridged thread, the same as an ordinary message would" do
      client.channels["thread-1"] = DiscordFakes::Channel.new(
        id: "thread-1", parent_id: "chan-1", channel_type: :thread
      )
      adapter.start

      client.invoke("delete", interaction("delete", options: { "message_id" => "900" }, channel_id: "thread-1"))

      expect(dispatcher.messages.size).to eq(1)
      expect(dispatcher.messages.first.body.text).to eq("/delete")
      expect(responses).to eq(["Acknowledged, deleting this message."])
    end
  end
end
