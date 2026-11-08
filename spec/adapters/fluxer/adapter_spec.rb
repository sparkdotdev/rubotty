# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Fluxer::Adapter do
  let(:client) do
    FluxerFakes::Client.new(users: { "55" => { "username" => "ada", "global_name" => "Ada L" } })
  end
  let(:gateway) { FluxerFakes::Gateway.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }

  # Bot posting by default; a second endpoint turns a webhook on for per sender identity.
  let(:general) do
    endpoint("fx-general", adapter: :fluxer,
                           settings: { channel_id: "111111111", webhook: :off })
  end
  let(:hooked) do
    endpoint("fx-hooked", adapter: :fluxer,
                          settings: { channel_id: "222222222", webhook: :auto })
  end

  subject(:adapter) do
    described_class.new(
      account: "fx",
      settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: [general, hooked]
    ).replace_client(client).replace_gateway(gateway)
  end

  describe "startup" do
    it "learns its own account id and starts the gateway" do
      adapter.start
      expect(adapter.own_account_id).to eq("bot-fluxer")
      expect(gateway.started).to be(true)
      expect(adapter).to be_running
    end

    it "refuses to start if it cannot learn its own id" do
      allow(client).to receive(:own_id).and_return(nil)
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /loop prevention/)
    end

    it "converts an unexpected start failure into an AdapterError" do
      allow(client).to receive(:own_id).and_raise(RuntimeError.new("boom"))
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /failed to start.*boom/)
    end

    # A missing key leaves this one account waiting rather than refusing the
    # whole file, which matters most when the file also carries platforms
    # that are working. Several fluxer_instances rows may each name their
    # own key env var; nothing reads that table at boot yet, so per-instance dormancy waits.
    it "opts into graceful dormancy, like every other credentialed adapter" do
      expect(described_class.dormant_on_missing_secret?).to be(true)
    end
  end

  describe "capabilities" do
    it "reports reactions and the moderation vocabulary" do
      expect(adapter.capabilities.reactions?).to be(true)
      %i[delete ban unban kick pin unpin mute unmute].each do |a|
        expect(adapter.capabilities.moderates?(a)).to be(true)
      end
    end

    it "declares a real upload ceiling" do
      expect(adapter.capabilities.max_attachment_bytes).to eq(10 * 1024 * 1024)
    end
  end

  describe "inbound" do
    def create(channel: "111111111", **rest)
      FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: channel, **rest))
    end

    it "converts a message into canonical form" do
      message = adapter.handle_event(create(content: "hello"))
      expect(dispatcher.last).to eq(message)
      expect(message.origin.id).to eq("fx-general")
      expect(message.body.text).to eq("hello")
      expect(message.author.username).to eq("ada")
    end

    it "parses Discord flavoured markdown Fluxer shares" do
      message = adapter.handle_event(create(content: "a **bold** word"))
      expect(message.body.text).to eq("a bold word")
      expect(message.body.spans.map(&:kind)).to eq([:bold])
    end

    it "captures attachments with their URLs" do
      file = { "url" => "https://cdn.fluxer.test/a.png", "filename" => "a.png", "content_type" => "image/png" }
      message = adapter.handle_event(create(attachments: [file]))
      captured = message.attachments.first
      expect(captured.kind).to eq(:photo)
      expect(captured.url).to eq("https://cdn.fluxer.test/a.png")
    end

    it "captures the parent of a reply so it can be quoted elsewhere" do
      parent = { "id" => "600", "content" => "original", "author" => { "id" => "9", "username" => "grace" } }
      message = adapter.handle_event(
        create(message_reference: { "message_id" => "600" }, referenced_message: parent)
      )
      expect(message.reply_to).to eq(ref("fx-general", "600"))
      expect(message.reply_preview.body.text).to eq("original")
    end

    it "relays a genuine edit and ignores an update carrying no content" do
      edited = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_UPDATE",
                             { "id" => "700", "channel_id" => "111111111", "content" => "fixed" })
      )
      expect(edited.kind).to eq(:edit)
      expect(edited.body.text).to eq("fixed")

      noise = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_UPDATE", { "id" => "700", "channel_id" => "111111111" })
      )
      expect(noise).to be_nil
    end

    it "turns a delete into a delete message" do
      message = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_DELETE", { "id" => "700", "channel_id" => "111111111" })
      )
      expect(message.kind).to eq(:delete)
      expect(message.ref).to eq(ref("fx-general", "700"))
    end

    # MESSAGE_DELETE_BULK is in the gateway constants and in
    # fluxer_gateway/src/utils/event_atoms.erl. Nothing handled it, so a
    # moderator clearing a raid got the opposite of what they asked for: the
    # messages went from Fluxer and every mirrored copy stayed up.
    it "turns a bulk delete into one delete per id" do
      produced = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_DELETE_BULK",
                             { "channel_id" => "111111111", "ids" => %w[700 701 702] })
      )
      expect(produced.map(&:kind)).to eq(%i[delete delete delete])
      expect(dispatcher.messages.map { |message| message.ref.native_id }).to eq(%w[700 701 702])
    end

    it "ignores a bulk delete in a channel it has no endpoint for" do
      expect(adapter.handle_event(
               FluxerFakes.dispatch("MESSAGE_DELETE_BULK", { "channel_id" => "999", "ids" => %w[700] })
             )).to be_empty
      expect(dispatcher.messages).to be_empty
    end

    it "turns a reaction into a reaction event and recognises a custom emoji" do
      unicode = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                             { "channel_id" => "111111111", "message_id" => "700",
                               "user_id" => "55", "emoji" => { "id" => nil, "name" => "👍" } })
      )
      expect(unicode.kind).to eq(:reaction_add)
      expect(unicode.reaction.emoji).to eq("👍")

      custom = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                             { "channel_id" => "111111111", "message_id" => "700",
                               "user_id" => "55", "emoji" => { "id" => "999", "name" => "parrot" } })
      )
      expect(custom.reaction).to be_custom
    end

    # A reaction event carries only a bare user_id, never the full user object
    # a message or member event does, so the author used to come out with
    # nothing but that id set and no name to show.
    it "resolves the reacting user's real name through a fresh lookup the first time it sees them" do
      message = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                             { "channel_id" => "111111111", "message_id" => "700",
                               "user_id" => "55", "emoji" => { "id" => nil, "name" => "😎" } })
      )
      expect(message.author.username).to eq("ada")
      expect(message.author.display_name).to eq("Ada L")
      expect(client.fetch_user_calls).to eq(["55"])
    end

    it "resolves a second reaction from the same user out of the cache, with no second lookup" do
      2.times do
        adapter.handle_event(
          FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                               { "channel_id" => "111111111", "message_id" => "700",
                                 "user_id" => "55", "emoji" => { "id" => nil, "name" => "😎" } })
        )
      end
      expect(client.fetch_user_calls).to eq(["55"])
    end

    it "falls back to a bare id when the lookup finds nobody, same as it always did" do
      message = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                             { "channel_id" => "111111111", "message_id" => "700",
                               "user_id" => "404404404", "emoji" => { "id" => nil, "name" => "😎" } })
      )
      expect(message.author.native_id).to eq("404404404")
      expect(message.author.username).to be_nil
    end

    it "renders a real name in the reacted-with label instead of the bare snowflake" do
      message = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                             { "channel_id" => "111111111", "message_id" => "700",
                               "user_id" => "55", "emoji" => { "id" => nil, "name" => "😎" } })
      )
      label = Rubotty::Core::SenderLabel.for(author: message.author, platform: "fluxer").to_s
      expect(label).to eq("Ada L [ada@fluxer]")
    end

    # Discord's reaction family has four events; only add and remove were
    # handled before. Neither bulk variant names a user.
    it "turns a remove-emoji event into a reaction_clear naming that emoji, and no author" do
      message = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_REACTION_REMOVE_EMOJI",
                             { "channel_id" => "111111111", "message_id" => "700",
                               "emoji" => { "id" => nil, "name" => "👍" } })
      )
      expect(message.kind).to eq(:reaction_clear)
      expect(message.reaction.emoji).to eq("👍")
      expect(message.author.native_id).to be_nil
    end

    it "turns a remove-all event, which carries no emoji key, into a reaction_clear naming none" do
      message = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_REACTION_REMOVE_ALL", { "channel_id" => "111111111", "message_id" => "700" })
      )
      expect(message.kind).to eq(:reaction_clear)
      expect(message.reaction).to be_nil
    end

    it "does not relay a message it posted through its own webhook" do
      # Delivering through the webhook makes the manager remember its id.
      out = message(hooked, text: "hi").with(sender_label: "Ada")
      adapter.deliver(out, hooked)
      own_id = client.created_webhooks.first["id"]

      echo = FluxerFakes.dispatch(
        "MESSAGE_CREATE",
        FluxerFakes.message_data(channel: "222222222", webhook_id: own_id)
      )
      expect(adapter.handle_event(echo)).to be_nil
    end

    it "does not dispatch a message authored by its own bot account" do
      adapter.start
      echo = create(
        id: "bot-echo",
        author: { "id" => "bot-fluxer", "username" => "Rubotty", "bot" => true }
      )

      expect(adapter.handle_event(echo)).to be_nil
      expect(dispatcher.messages).to be_empty
    end

    it "ignores a channel it has no endpoint for" do
      expect(adapter.handle_event(create(channel: "999999999"))).to be_nil
    end
  end

  # Fluxer offers no way to publish the command list and no way to add to the
  # "/" menu its client compiles in, so the only surface left is the text
  # commands and what the bridge says about them in the room.
  describe "the command surface (issue #583)" do
    def create(channel: "111111111", **rest)
      FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: channel, **rest))
    end

    let(:adapters) { { [general.adapter_name, general.account] => adapter } }
    let(:home) { topology(room("r", general)) }

    let(:ephemeral) do
      Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: home, logger: Rubotty::Log.null
      )
    end

    # One community with the public command surface switched on, which is what
    # the pipeline resolves a scope against.
    let(:registry) do
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(
        endpoint: general, community_id: 1, route_key: "111111111"
      )
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "fx", name: "Fluxer community", status: "active", settings: {},
        topology: home, channels: [channel],
        operators: Rubotty::Core::Moderation::Directory.new,
        people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            room_key: nil, feature: "utility_commands", enabled: true
          )
        ]
      )
      instance_double(
        Rubotty::ControlPlane::Registry,
        current: Rubotty::ControlPlane::Snapshot.new(communities: [community])
      )
    end

    # The real chain a typed command travels, with the real parser at the head
    # of it, so this fails if anything ever puts a Fluxer message on a different
    # path from a Telegram or Discord one.
    let(:pipeline) do
      Rubotty::Features::Pipeline.new(
        features: [
          Rubotty::Features::Moderation.new(
            topology: home, adapters: adapters, storage: nil, logger: Rubotty::Log.null,
            commands: Rubotty::Core::Commands.new, ephemeral: ephemeral
          ),
          Rubotty::Features::UtilityCommands.new(
            topology: home, adapters: adapters, logger: Rubotty::Log.null, ephemeral: ephemeral
          )
        ],
        registry: registry, logger: Rubotty::Log.null
      )
    end

    def posted = client.sent.map { |call| call[:body][:content] }

    # Recorded so nobody re-adds a registration call: /applications/{id}/commands
    # answers 404 on the live API and the Fluxer docs list no interactions
    # resource, so there is nothing to publish Core::CommandRegistry into.
    it "publishes no native command list, because Fluxer has no resource to publish one to" do
      expect(adapter.capabilities.publishes_command_list?).to be(false)
      expect(adapter).not_to respond_to(:register_commands)
      expect(described_class.account_schema.fields).not_to have_key(:register_commands)
    end

    it "reserves \"/\", which the Fluxer client takes for a fixed menu of its own" do
      expect(adapter.capabilities.reserved_command_prefixes).to eq(["/"])
      expect(adapter.capabilities.reserves_prefix?("/")).to be(true)
      expect(adapter.capabilities.reserves_prefix?("!")).to be(false)
    end

    it "carries a gateway frame of !help through to the command listing" do
      pipeline.handle(adapter.handle_event(create(content: "!help")))

      expect(posted.last).to start_with("Commands you can use:")
      expect(posted.last).to include("!help - List the commands you can use here.")
    end

    it "carries /help through as well, for anyone whose client lets it out" do
      pipeline.handle(adapter.handle_event(create(content: "/help")))

      expect(posted.last).to start_with("Commands you can use:")
    end

    it "reaches the moderation parser, so a verb is recognised here like anywhere" do
      pipeline.handle(adapter.handle_event(create(content: "!ban")))

      expect(posted.last).to include("has to be sent as a reply")
    end

    it "points a channel at the help command the first time it sees one" do
      pipeline.handle(adapter.handle_event(create(content: "morning all")))

      expect(posted.last).to include("Type !help")
    end
  end

  describe "outbound as the bot" do
    let(:outgoing) { message(general, text: "hello").with(sender_label: "Ada (ada)") }

    it "sends the message with the sender prefix and returns a receipt" do
      receipt = adapter.deliver(outgoing, general)
      body = client.sent.first[:body]
      expect(body[:content]).to start_with("**Ada (ada)")
      expect(body[:content]).to include("hello")
      expect(receipt.native_id).to eq("sent-1")
    end

    it "carries a nonce for idempotency" do
      adapter.deliver(outgoing, general)
      expect(client.sent.first[:body][:nonce]).to eq(outgoing.correlation_id)
    end

    it "suppresses mass mentions by default" do
      adapter.deliver(outgoing, general)
      expect(client.sent.first[:body][:allowed_mentions]).to eq(parse: [], users: [], roles: [])
    end

    it "permits only the ids the bridge resolved, leaving injected tokens inert" do
      injected = message(
        general,
        text: rich("ping <@111> and @everyone and Alex", span(:mention, 30, 34, fluxer_id_for_target: "900"))
      ).with(sender_label: "Ada")
      adapter.deliver(injected, general)
      mentions = client.sent.first[:body][:allowed_mentions]
      expect(mentions[:users]).to eq(["900"])
      expect(mentions[:parse]).to eq([])
    end

    it "escapes markdown in relayed text" do
      hostile = message(general, text: "not **bold**").with(sender_label: "Ada")
      adapter.deliver(hostile, general)
      expect(client.sent.first[:body][:content]).to include('\\*\\*bold\\*\\*')
    end

    it "attaches a native reply when the parent lives on this endpoint" do
      local = outgoing.with(reply_to: ref("fx-general", "600"))
      adapter.deliver(local, general)
      expect(client.sent.first[:body][:message_reference]).to eq(message_id: "600", fail_if_not_exists: false)
    end

    it "quotes the parent when a native reply is impossible" do
      preview = Rubotty::Core::ReplyPreview.new(body: Rubotty::Core::RichText.plain("the original"), label: "Grace")
      foreign = outgoing.with(reply_to: ref("tg-general", "42"), reply_preview: preview)
      adapter.deliver(foreign, general)
      expect(client.sent.first[:body][:content]).to start_with("> **Grace**: the original")
      expect(client.sent.first[:body][:message_reference]).to be_nil
    end

    it "truncates a message past the limit" do
      long = message(general, text: "x" * 3000).with(sender_label: "Ada")
      adapter.deliver(long, general)
      expect(client.sent.first[:body][:content].length).to be <= 2000
    end
  end

  # Fluxer takes a multipart upload just like Discord; declaring
  # attachment_by_url and relaying a link never got a Telegram file across,
  # since a Telegram URL embeds the bot token and fails the public url test.
  describe "media (issue #735)" do
    let(:outgoing) { message(general, text: "look").with(sender_label: "Ada") }

    def stubbed_fetcher(&block)
      Rubotty::Util::MediaFetcher.new(http: block)
    end

    def fake_file(bytes)
      StringIO.new(bytes).tap { |io| io.define_singleton_method(:unlink) { nil } }
    end

    it "uploads a resolvable attachment as a real file instead of a link" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("PNGDATA") })
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")

      adapter.deliver(outgoing.with(attachments: [photo]), general)

      sent = client.sent.first
      expect(sent[:files].first[:io].string).to eq("PNGDATA")
      expect(sent[:files].first[:filename]).to eq("a.png")
      expect(sent[:body][:content]).to include("look")
      expect(sent[:body][:content]).not_to include("https://cdn.example/a.png")
    end

    it "never puts a Telegram file URL into the room, uploading its bytes instead" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("JPEGDATA") })
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )

      adapter.deliver(outgoing.with(attachments: [leaky]), general)

      sent = client.sent.first
      expect(sent[:files]).not_to be_empty
      expect(sent[:body][:content]).not_to include("AAsecret")
    end

    it "falls back to a text reference and reports the failure when the download fails" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| nil })
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")

      receipt = adapter.deliver(outgoing.with(attachments: [photo]), general)

      expect(client.sent.first[:files]).to be_nil
      expect(client.sent.first[:body][:content]).to include("https://cdn.example/a.png")
      expect(receipt.extra[:notes]).to include(a_string_matching(/could not relay a\.png/))
    end

    it "uploads through the webhook path too, since that is the default delivery mode" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("PNGDATA") })
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      out = message(hooked, text: "look", author: Rubotty::Core::Author.new(username: "ada"))
            .with(sender_label: "Ada", attachments: [photo])

      adapter.deliver(out, hooked)

      execute = client.webhook_executes.first
      expect(execute[:files].first[:io].string).to eq("PNGDATA")
      expect(execute[:body][:content]).not_to include("https://cdn.example/a.png")
    end
  end

  # No sender prefix, no attachments: nothing worth posting, a routine decline
  # rather than an attempted send that came back empty. A bare nil here had
  # Bridge log RELAY LOST and count the message in the backfill loss total.
  describe "outbound with nothing to say" do
    it "signals the bot path's decline as NOT_APPLICABLE rather than a bare nil" do
      receipt = adapter.deliver(message(general, text: ""), general)
      expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(receipt).to be_nil
      expect(client.sent).to be_empty
    end

    it "signals the webhook path's decline the same way" do
      receipt = adapter.deliver(message(hooked, text: ""), hooked)
      expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(receipt).to be_nil
      expect(client.webhook_executes).to be_empty
      expect(client.sent).to be_empty
    end
  end

  describe "outbound through a webhook" do
    it "posts under the sender's own name with no text prefix" do
      author = Rubotty::Core::Author.new(username: "ada", avatar_url: "https://cdn.example/a.png")
      out = message(hooked, text: "hello", author: author).with(sender_label: "Ada L [ada@telegram]")
      adapter.deliver(out, hooked)
      execute = client.webhook_executes.first
      expect(execute[:body][:username]).to eq("Ada L [ada@telegram]")
      expect(execute[:body][:avatar_url]).to eq("https://cdn.example/a.png")
      expect(execute[:body][:content]).to eq("hello")
    end

    it "falls back to bot posting when the webhook execute fails" do
      allow(client).to receive(:execute_webhook)
        .and_raise(Rubotty::AdapterError.new("Fluxer webhook gone (404)", adapter: :fluxer))
      out = message(hooked, text: "hello").with(sender_label: "Ada")
      adapter.deliver(out, hooked)
      expect(client.sent.first[:body][:content]).to include("hello")
    end
  end

  describe "edit and delete" do
    let(:outgoing) { message(general, text: "hello").with(sender_label: "Ada") }

    it "edits a bot message in place, carrying the mention whitelist" do
      adapter.edit(outgoing.with(body: Rubotty::Core::RichText.plain("now @everyone")), general, "900")
      edit = client.edited.first
      expect(edit[:id]).to eq("900")
      expect(edit[:body][:allowed_mentions]).to eq(parse: [], users: [], roles: [])
    end

    it "treats a late delete of a gone message as success" do
      allow(client).to receive(:delete_message)
        .and_raise(Rubotty::AdapterError.new("Fluxer DELETE failed (404): Unknown Message", adapter: :fluxer))
      expect { adapter.delete(general, "gone") }.not_to raise_error
    end
  end

  describe "reactions" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }

    it "adds newly desired and removes no longer desired reactions" do
      adapter.sync_reactions(general, "900", desired: [thumbs, party], previous: [])
      expect(client.reactions_added.map { |r| r[:emoji] }).to eq(%w[👍 🎉])
      adapter.sync_reactions(general, "900", desired: [party], previous: [thumbs, party])
      expect(client.reactions_removed.map { |r| r[:emoji] }).to eq(["👍"])
    end

    it "uses the name:id form for a custom emoji" do
      custom = Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot")
      adapter.sync_reactions(general, "900", desired: [custom], previous: [])
      expect(client.reactions_added.first[:emoji]).to eq("parrot:999")
    end

    # Swallowing these left the bridge recording the mirror as placed, and
    # storage then holds an emoji the message does not have, with nothing that
    # ever reconciles the two.
    it "lets a refused add out, rather than reporting an emoji it did not place" do
      allow(client).to receive(:add_reaction)
        .and_raise(Rubotty::PermissionError.new("Fluxer PUT failed (403): Missing Permissions",
                                                adapter: :fluxer))
      expect { adapter.sync_reactions(general, "900", desired: [thumbs], previous: []) }
        .to raise_error(Rubotty::PermissionError)
    end

    it "lets a rate limited remove out too" do
      allow(client).to receive(:remove_own_reaction)
        .and_raise(Rubotty::RateLimitedError.new("Fluxer DELETE failed (429): rate limited",
                                                 adapter: :fluxer))
      expect { adapter.sync_reactions(general, "900", desired: [], previous: [thumbs]) }
        .to raise_error(Rubotty::RateLimitedError)
    end

    it "still treats a reaction on a message that is already gone as done" do
      allow(client).to receive(:add_reaction)
        .and_raise(Rubotty::AdapterError.new("Fluxer PUT failed (404): Unknown Message",
                                             adapter: :fluxer))
      expect { adapter.sync_reactions(general, "900", desired: [thumbs], previous: []) }
        .not_to raise_error
    end
  end

  describe "moderation" do
    def command(action)
      Rubotty::Core::Moderation::Command.new(
        action: action,
        issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general,
        target_user_id: "u-bad"
      )
    end

    let(:guild_endpoint) do
      endpoint("fx-mod", adapter: :fluxer, settings: { channel_id: "111111111", guild_id: "GLD1", webhook: :off })
    end

    it "deletes the target message" do
      result = adapter.moderate(command(:delete), general, "900")
      expect(result.status).to eq(:done)
      expect(client.deleted.first[:id]).to eq("900")
    end

    it "bans and kicks through the configured guild" do
      expect(adapter.moderate(command(:ban), guild_endpoint, nil).status).to eq(:done)
      expect(client.bans.first).to include(guild: "GLD1", user: "u-bad")
      expect(adapter.moderate(command(:kick), guild_endpoint, nil).status).to eq(:done)
      expect(client.kicks.first).to include(guild: "GLD1", user: "u-bad")
    end

    it "reports a ban with no configured guild as failed rather than raising" do
      expect(adapter.moderate(command(:ban), general, nil).status).to eq(:failed)
    end

    it "reports an action outside its vocabulary as unsupported" do
      expect(adapter.moderate(command(:not_a_real_action), general, nil).status).to eq(:unsupported)
    end

    it "pins and unpins the target message" do
      expect(adapter.moderate(command(:pin), general, "900").status).to eq(:done)
      expect(client.pins.first).to include(channel: "111111111", id: "900")
      expect(adapter.moderate(command(:unpin), general, "900").status).to eq(:done)
      expect(client.unpins.first).to include(channel: "111111111", id: "900")
    end

    it "mutes and unmutes through the configured guild, timing out the member" do
      expect(adapter.moderate(command(:mute), guild_endpoint, nil).status).to eq(:done)
      muted = client.timeouts.first
      expect(muted).to include(guild: "GLD1", user: "u-bad")
      expect(muted[:until]).not_to be_nil

      expect(adapter.moderate(command(:unmute), guild_endpoint, nil).status).to eq(:done)
      expect(client.timeouts.last[:until]).to be_nil
    end

    it "reports a mute with no configured guild as failed rather than raising" do
      expect(adapter.moderate(command(:mute), general, nil).status).to eq(:failed)
    end
  end

  # The passive half of discovery: every event carrying a channel_id sights its
  # channel, which catches one created after the enumeration sweep ran.
  describe "channel discovery (issue #204)" do
    let(:sightings) { [] }
    let(:recording_discovery) do
      log = sightings
      Class.new { define_method(:saw) { |descriptor| log << descriptor } }.new
    end

    def discovering_adapter(account: "fx", discovery: recording_discovery)
      described_class.new(
        account: account, settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general, hooked],
        discovery: discovery
      ).replace_client(client).replace_gateway(gateway)
    end

    it "records a sighted channel on a message, keyed by the channel id" do
      discovering_adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "333333333", guild_id: "GLD-1"))
      )
      expect(sightings.size).to eq(1)
      expect(sightings.first).to include(adapter: :fluxer, account: "fx", route_key: "333333333")
    end

    # Nil rather than an empty string, because ChannelDiscovery#backfill_name
    # opens with presence() and an empty name can never be filled in later.
    it "sights a channel it has never listed with a nil name, so a later sighting can name it" do
      discovering_adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "333333333", guild_id: "GLD-1"))
      )
      expect(sightings.first[:name]).to be_nil
    end

    it "also sights an edit, a delete, and a reaction, not only a fresh message" do
      adapter = discovering_adapter
      adapter.handle_event(FluxerFakes.dispatch("MESSAGE_UPDATE",
                                                { "id" => "1", "channel_id" => "444", "guild_id" => "GLD-1",
                                                  "content" => "x" }))
      adapter.handle_event(FluxerFakes.dispatch("MESSAGE_DELETE",
                                                { "id" => "1", "channel_id" => "555", "guild_id" => "GLD-1" }))
      adapter.handle_event(FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                                                { "channel_id" => "666", "message_id" => "1", "user_id" => "9",
                                                  "guild_id" => "GLD-1",
                                                  "emoji" => { "id" => nil, "name" => "👍" } }))
      expect(sightings.map { |d| d[:route_key] }).to eq(%w[444 555 666])
    end

    it "never consumes the event: a sighted channel still routes normally" do
      message = discovering_adapter.handle_event(
        FluxerFakes.dispatch(
          "MESSAGE_CREATE",
          FluxerFakes.message_data(channel: "111111111", guild_id: "GLD-1", content: "still routes")
        )
      )
      expect(sightings).not_to be_empty
      expect(message.body.text).to eq("still routes")
    end

    it "uses the event's guild_id as the coarse space when the payload carries one" do
      discovering_adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "777", guild_id: "GLD-9"))
      )
      expect(sightings.first).to include(external_id: "GLD-9")
    end

    # DMs are the same MESSAGE_CREATE shape as a guild channel, minus a
    # guild_id, and there is no space to attribute one to.
    it "never sights a DM channel, since it belongs to no guild" do
      discovering_adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "888"))
      )
      expect(sightings).to be_empty
    end

    it "does not fail the receive loop when discovery raises" do
      raising = Class.new { def saw(_descriptor) = raise(StandardError, "boom") }.new
      message = discovering_adapter(discovery: raising).handle_event(
        FluxerFakes.dispatch(
          "MESSAGE_CREATE",
          FluxerFakes.message_data(channel: "111111111", guild_id: "GLD-1", content: "still works")
        )
      )
      expect(message.body.text).to eq("still works")
    end

    it "does nothing when no discovery is wired" do
      expect do
        adapter.handle_event(FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "111111111")))
      end.not_to raise_error
    end
  end

  # The active half: the bot asks Fluxer which guilds it is in and which channels
  # each one holds, rather than waiting for somebody to talk in them.
  describe "guild and channel enumeration (issue #579)" do
    let(:discovery) { FluxerFakes::Discovery.new }
    let(:pending) { FluxerFakes::PendingSpaces.new }
    let(:guild_id) { "8000000000000000008" }
    let(:client) do
      FluxerFakes::Client.new(
        guilds: [{ "id" => guild_id, "name" => "Example Gaming Community" }],
        guild_channels: {
          guild_id => [
            FluxerFakes.channel_data(id: "10", name: "general"),
            FluxerFakes.channel_data(id: "11", name: "Text Channels", type: 4),
            FluxerFakes.channel_data(id: "12", name: "Lounge", type: 2),
            FluxerFakes.channel_data(id: "13", name: "announcements")
          ]
        }
      )
    end

    def enumerating_adapter(client: self.client, discovery: self.discovery, pending_spaces: pending)
      described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
        discovery: discovery, pending_spaces: pending_spaces
      ).replace_client(client).replace_gateway(gateway)
    end

    it "enumerates every guild and inventories its channels at connect" do
      enumerating_adapter.handle_event(FluxerFakes.ready)

      expect(discovery.inventories.size).to eq(1)
      expect(discovery.inventories.first).to include(adapter: :fluxer, account: "fx", external_id: guild_id)
    end

    it "records only text channels, never a category or a voice channel" do
      enumerating_adapter.handle_event(FluxerFakes.ready)

      expect(discovery.inventories.first[:channels])
        .to eq([{ id: "10", name: "general" }, { id: "13", name: "announcements" }])
    end

    # The listing done at connect is what lets a later passive sighting name its
    # channel, so a channel found by traffic reads as well as one found by sweep.
    it "names a passively sighted channel from the listing it already fetched" do
      adapter = enumerating_adapter
      adapter.handle_event(FluxerFakes.ready)
      adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "10", guild_id: guild_id))
      )

      expect(discovery.sightings.last).to include(route_key: "10", name: "general")
    end

    it "inventories a guild's channels the moment the bot is added, with no traffic" do
      enumerating_adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: "CloudNine"))

      expect(discovery.inventories.first[:external_id]).to eq(guild_id)
      expect(discovery.inventories.first[:channels].map { |channel| channel[:id] }).to eq(%w[10 13])
      expect(discovery.sightings).to be_empty
      expect(dispatcher.messages).to be_empty
    end

    it "pends the space on the join event, so it reaches the board without traffic" do
      enumerating_adapter.handle_event(
        FluxerFakes.guild_created(id: guild_id, name: "Example Gaming Community", member_count: 42)
      )

      expect(pending.joins.size).to eq(1)
      expect(pending.joins.first).to include(
        adapter: :fluxer, account: "fx", external_id: guild_id,
        name: "Example Gaming Community", member_count: 42
      )
    end

    it "re-confirms a denial when the bot is added back to a denied guild" do
      denied = Rubotty::ControlPlane::PendingSpaces::Outcome.new(action: :leave, row: :denied_row)
      spaces = FluxerFakes::PendingSpaces.new(outcome: denied)
      enumerating_adapter(pending_spaces: spaces).handle_event(FluxerFakes.guild_created(id: guild_id))

      expect(spaces.reconfirmed).to eq([:denied_row])
    end

    it "keeps enumerating the other guilds when one refuses" do
      refusing = FluxerFakes::Client.new(
        guilds: [{ "id" => "1", "name" => "One" }, { "id" => "2", "name" => "Two" }],
        guild_channels: {
          "1" => Rubotty::PermissionError.new("Fluxer refused GET /guilds/1/channels (403): Missing Access",
                                              adapter: :fluxer),
          "2" => [FluxerFakes.channel_data(id: "20", name: "general")]
        }
      )

      expect { enumerating_adapter(client: refusing).handle_event(FluxerFakes.ready) }.not_to raise_error
      expect(refusing.channel_listings).to eq(%w[1 2])
      expect(discovery.inventories.map { |entry| entry[:external_id] }).to eq(%w[2])
    end

    it "stays quiet when the whole guild listing is unreachable" do
      unreachable = FluxerFakes::Client.new(
        guilds: Rubotty::AdapterError.new("Fluxer request failed: SocketError", adapter: :fluxer, retryable: true)
      )

      expect { enumerating_adapter(client: unreachable).handle_event(FluxerFakes.ready) }.not_to raise_error
      expect(discovery.inventories).to be_empty
    end

    # A reconnect replays a GUILD_CREATE per guild, and listing every guild's
    # channels twice is the burst worth avoiding.
    it "lists a guild's channels once per connect" do
      adapter = enumerating_adapter
      adapter.handle_event(FluxerFakes.ready)
      adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: "CloudNine"))

      expect(client.channel_listings).to eq([guild_id])
      expect(discovery.inventories.size).to eq(1)
      expect(pending.joins.size).to eq(1)
    end

    it "enumerates again after a reconnect" do
      adapter = enumerating_adapter
      2.times { adapter.handle_event(FluxerFakes.ready) }

      expect(client.channel_listings).to eq([guild_id, guild_id])
    end

    it "asks for nothing without a discovery seam" do
      enumerating_adapter(discovery: nil).handle_event(FluxerFakes.ready)

      expect(client.channel_listings).to be_empty
    end

    it "still pends a join without a discovery seam" do
      enumerating_adapter(discovery: nil).handle_event(FluxerFakes.guild_created(id: guild_id, name: "CloudNine"))

      expect(pending.joins.first).to include(external_id: guild_id)
    end

    it "does nothing without a pending-review service" do
      expect do
        enumerating_adapter(pending_spaces: nil).handle_event(FluxerFakes.guild_created(id: guild_id))
      end.not_to raise_error
    end

    # Fluxer sends a lazy guild object at connect, so the frame's name key comes
    # back nil and the card reads as an unnamed space.
    it "takes the guild name from the REST listing when the frame carries none" do
      enumerating_adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: nil, member_count: 2))

      expect(pending.joins.first).to include(name: "Example Gaming Community", member_count: 2)
    end

    it "prefers the REST listing's name over the one the frame did carry" do
      adapter = enumerating_adapter
      adapter.handle_event(FluxerFakes.ready)
      adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: "stale frame name"))

      expect(pending.joins.first[:name]).to eq("Example Gaming Community")
    end

    it "falls back to the frame's name when the listing is unreachable" do
      unreachable = FluxerFakes::Client.new(
        guilds: Rubotty::AdapterError.new("Fluxer request failed: SocketError", adapter: :fluxer, retryable: true)
      )
      enumerating_adapter(client: unreachable).handle_event(
        FluxerFakes.guild_created(id: guild_id, name: "Only The Frame Knows")
      )

      expect(pending.joins.first[:name]).to eq("Only The Frame Knows")
    end

    it "reuses the names the connect sweep already listed rather than asking again" do
      adapter = enumerating_adapter
      adapter.handle_event(FluxerFakes.ready)
      allow(client).to receive(:list_guilds).and_raise("the sweep should have cached this")

      adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: nil))

      expect(pending.joins.first[:name]).to eq("Example Gaming Community")
    end

    # For RehostedFiles' download-serve ceiling; see
    # ControlPlane::CommunityMembers. Fluxer's REST API carries no per-guild
    # count, so GUILD_CREATE's snapshot, kept in step by the join/leave
    # events the gateway already delivers, is the only source there is.
    describe "#community_member_count" do
      it "answers nil for a guild it has not seen a GUILD_CREATE for" do
        expect(enumerating_adapter.community_member_count("never-seen")).to be_nil
      end

      it "caches the count a GUILD_CREATE snapshot carried" do
        adapter = enumerating_adapter
        adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: "CloudNine", member_count: 42))

        expect(adapter.community_member_count(guild_id)).to eq(42)
      end

      it "is nudged up by a live join and down by a live leave" do
        adapter = enumerating_adapter
        adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: "CloudNine", member_count: 42))

        adapter.handle_event(FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: guild_id)))
        expect(adapter.community_member_count(guild_id)).to eq(43)

        adapter.handle_event(FluxerFakes.dispatch("GUILD_MEMBER_REMOVE", FluxerFakes.member_data(guild_id: guild_id)))
        expect(adapter.community_member_count(guild_id)).to eq(42)
      end

      it "leaves a never-snapshotted guild's count nil rather than start counting from a join" do
        adapter = enumerating_adapter
        adapter.handle_event(FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: guild_id)))

        expect(adapter.community_member_count(guild_id)).to be_nil
      end
    end
  end

  # The first listing of a space happens while it is still pending, so it has no
  # platform connection to be recorded against and the whole listing is dropped.
  describe "re-enumerating one space after its approval (issue #584)" do
    let(:discovery) { FluxerFakes::Discovery.new }
    let(:guild_id) { "8000000000000000008" }
    let(:client) do
      FluxerFakes::Client.new(
        guilds: [{ "id" => guild_id, "name" => "Example Gaming Community" }],
        guild_channels: {
          guild_id => [
            FluxerFakes.channel_data(id: "10", name: "general"),
            FluxerFakes.channel_data(id: "13", name: "announcements")
          ]
        }
      )
    end

    subject(:enumerating) do
      described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
        discovery: discovery, pending_spaces: FluxerFakes::PendingSpaces.new
      ).replace_client(client).replace_gateway(gateway)
    end

    it "declares the seam the approval flow reaches for" do
      expect(enumerating.supports_space_enumeration?).to be(true)
    end

    # The once-per-connect claim is what would otherwise silently refuse the
    # second listing, which is the whole point of asking for it.
    it "lists the guild's channels again even though this connect already did" do
      enumerating.handle_event(FluxerFakes.ready)
      expect(discovery.inventories.size).to eq(1)

      expect(enumerating.enumerate_space(guild_id)).to be(true)

      expect(client.channel_listings).to eq([guild_id, guild_id])
      expect(discovery.inventories.last[:channels].map { |channel| channel[:id] }).to eq(%w[10 13])
    end

    it "refuses a blank space id" do
      expect(enumerating.enumerate_space("  ")).to be(false)
      expect(client.channel_listings).to be_empty
    end

    it "answers false with no discovery seam wired" do
      bare = described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: []
      ).replace_client(client).replace_gateway(gateway)

      expect(bare.enumerate_space(guild_id)).to be(false)
    end
  end

  # Fluxer has no seeded topology in bridge.config.yaml, so the community and
  # its instances are built by hand here; the channels_route_idx unique index on
  # (adapter, account, route_key) is what keeps two instances apart.
  describe "channel discovery against the real seam (issue #204)", :control_plane do
    let(:models) { build_models(migrated_db) }
    let(:store) do
      Class.new do
        def initialize = @h = {}

        def get_state(key) = @h[key]

        def put_state(key, value, expires_at: nil) = @h[key] = value
      end.new
    end
    let(:watch) { Rubotty::ControlPlane::NewChannelWatch.new(models: models, store: store) }
    let(:discovery) { Rubotty::ControlPlane::ChannelDiscovery.new(models: models, watch: watch) }

    def build_community
      models.community.create(
        slug: "multi-fx", name: "Multi Fluxer", status: "active",
        settings: JSON.generate("new_channel_alerts" => { "enabled" => true, "ignore" => [] }),
        created_at: Time.now, updated_at: Time.now
      )
    end

    def connect(community, account:, external_id: "unresolved:#{account}")
      models.platform_connection.create(
        community_id: community.id, adapter: "fluxer", account: account, external_id: external_id,
        created_at: Time.now, updated_at: Time.now
      )
    end

    def fluxer_adapter(account, client: FluxerFakes::Client.new)
      described_class.new(
        account: account, settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: [], discovery: discovery
      ).replace_client(client).replace_gateway(FluxerFakes::Gateway.new)
    end

    it "records a sighted channel as a dormant row through the real seam" do
      community = build_community
      connect(community, account: "flagship", external_id: "9500")

      fluxer_adapter("flagship").handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "500", id: "1", guild_id: "9500"))
      )

      row = models.channel.where(adapter: "fluxer", account: "flagship", route_key: "500").first
      expect(row).not_to be_nil
      expect(row.endpoint_key).to eq("discovered:fluxer:flagship:500")
      expect(row.json_value(:settings)).to eq("channel_id" => "500")
      # Dormant: recorded, but in no room, so nothing bridges until mapped.
      expect(models.room_channel.where(channel_id: row.id).count).to eq(0)
    end

    it "never confuses two Fluxer instances that happen to share a channel id" do
      community = build_community
      connect(community, account: "flagship", external_id: "9500")
      connect(community, account: "selfhosted-a", external_id: "9500")

      fluxer_adapter("flagship").handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "500", id: "1", guild_id: "9500"))
      )
      fluxer_adapter("selfhosted-a").handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "500", id: "1", guild_id: "9500"))
      )

      rows = models.channel.where(adapter: "fluxer", route_key: "500").all
      expect(rows.map(&:account)).to contain_exactly("flagship", "selfhosted-a")
      expect(rows.map(&:endpoint_key)).to contain_exactly(
        "discovered:fluxer:flagship:500", "discovered:fluxer:selfhosted-a:500"
      )
    end

    it "prompts by default, without an explicit opt-in" do
      community = models.community.create(
        slug: "eager-fx", name: "Eager Fluxer", status: "active",
        created_at: Time.now, updated_at: Time.now
      )
      connect(community, account: "flagship", external_id: "9502")

      fluxer_adapter("flagship").handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "502", id: "1", guild_id: "9502"))
      )

      expect(models.channel.where(adapter: "fluxer", route_key: "502").first).not_to be_nil
    end

    it "records an enumerated guild's text channels as dormant rows in no room" do
      community = build_community
      connect(community, account: "flagship", external_id: "9001")
      client = FluxerFakes::Client.new(
        guilds: [{ "id" => "9001", "name" => "CloudNine" }],
        guild_channels: {
          "9001" => [
            FluxerFakes.channel_data(id: "77", name: "general"),
            FluxerFakes.channel_data(id: "78", name: "Text Channels", type: 4),
            FluxerFakes.channel_data(id: "79", name: "Lounge", type: 2)
          ]
        }
      )

      fluxer_adapter("flagship", client: client).handle_event(FluxerFakes.ready)

      row = models.channel.where(adapter: "fluxer", account: "flagship", route_key: "77").first
      expect(row.endpoint_key).to eq("discovered:fluxer:flagship:77")
      expect(row.label).to eq("general")
      expect(row.json_value(:settings)).to eq("channel_id" => "77")
      # Dormant: recorded, in no room, so nothing bridges until an operator maps it.
      expect(models.room_channel.where(channel_id: row.id).count).to eq(0)
      expect(models.channel.where(adapter: "fluxer", route_key: %w[78 79]).count).to eq(0)
    end

    it "learns nothing once a community explicitly opts out" do
      community = models.community.create(
        slug: "quiet-fx", name: "Quiet Fluxer", status: "active",
        settings: JSON.generate("new_channel_alerts" => { "enabled" => false }),
        created_at: Time.now, updated_at: Time.now
      )
      connect(community, account: "flagship", external_id: "9501")

      fluxer_adapter("flagship").handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "501", id: "1", guild_id: "9501"))
      )

      expect(models.channel.where(adapter: "fluxer", route_key: "501").first).to be_nil
    end
  end

  # Fluxer is Discord shaped, so a DM is the same open-a-channel-then-post
  # shape as a Discord DM, and deleting one is the ordinary channel-message
  # delete.
  describe "direct messages to an operator" do
    it "says it can send and delete, so the callers that check first will use it" do
      expect(adapter.supports_admin_dm?).to be(true)
      expect(adapter.supports_admin_dm_delete?).to be(true)
    end

    it "opens the DM channel, sends the message, and hands back a receipt" do
      receipt = adapter.send_admin_dm("55", "a room needs you")

      expect(client.dms_opened).to eq(["55"])
      expect(client.sent.first).to eq(channel: "dm-channel-55", body: { content: "a room needs you" })
      expect(receipt).to be_a(Rubotty::Core::DmReceipt)
      expect(receipt.native_id).not_to be_empty
      expect(receipt.channel_ref).to eq("dm-channel-55")
    end

    it "sends nothing for an empty message" do
      expect(adapter.send_admin_dm("55", "   ")).to be_nil
      expect(client.dms_opened).to be_empty
    end

    it "answers nil rather than raising when Fluxer refuses to open the DM" do
      allow(client).to receive(:create_dm)
        .and_raise(Rubotty::AdapterError.new("Fluxer POST failed (403): Cannot message this user",
                                             adapter: :fluxer))

      expect { expect(adapter.send_admin_dm("55", "hi")).to be_nil }.not_to raise_error
    end

    it "deletes the message the receipt points at" do
      receipt = adapter.send_admin_dm("55", "a room needs you")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
      expect(client.deleted).to include(channel: "dm-channel-55", id: receipt.native_id)
    end

    it "treats a late delete of a gone message as success" do
      allow(client).to receive(:delete_message)
        .and_raise(Rubotty::AdapterError.new("Fluxer DELETE failed (404): Unknown Message", adapter: :fluxer))
      receipt = Rubotty::Core::DmReceipt.new(native_id: "1", channel_ref: "dm-channel-55")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
    end

    it "is falsy for a receipt with nothing to delete" do
      expect(adapter.delete_admin_dm(nil)).to be(false)
    end
  end

  # A DM to the bot is a MESSAGE_CREATE with no guild_id, the same signal
  # channel discovery uses to recognise one; nothing routed it to control_lane
  # before, so a reply typed back to the bot's startup DM fell on the floor.
  describe "the operator console reached by DM (issue #732)" do
    let(:lane) { FluxerFakes::ControlLane.new(reply: "try !help") }
    let(:console_client) { FluxerFakes::Client.new }

    def console_adapter(control_lane: lane, client: console_client)
      described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general, hooked],
        control_lane: control_lane
      ).replace_client(client).replace_gateway(FluxerFakes::Gateway.new)
    end

    def dm(content:, author_id: "900", channel: "dm-1")
      FluxerFakes.dispatch(
        "MESSAGE_CREATE",
        { "id" => "1", "channel_id" => channel, "content" => content,
          "author" => { "id" => author_id, "username" => "op" } }
      )
    end

    it "hands a DM with no guild_id to the control lane instead of dropping it" do
      adapter = console_adapter
      adapter.start
      adapter.handle_event(dm(content: "!help"))

      expect(lane.handled.size).to eq(1)
      expect(lane.handled.first).to include(adapter: :fluxer, account: "fx", text: "!help")
    end

    it "posts the lane's reply back into the DM channel" do
      adapter = console_adapter
      adapter.start
      adapter.handle_event(dm(content: "!help", channel: "dm-1"))

      expect(console_client.sent.first).to eq(channel: "dm-1", body: { content: "try !help" })
    end

    it "swallows the DM rather than routing it as an ordinary channel message" do
      adapter = console_adapter
      adapter.start
      adapter.handle_event(dm(content: "!help"))

      expect(dispatcher.messages).to be_empty
    end

    it "never answers its own reply back, which would otherwise loop" do
      adapter = console_adapter
      adapter.start
      adapter.handle_event(dm(content: "try !help", author_id: "bot-fluxer"))

      expect(lane.handled).to be_empty
    end

    it "leaves an ordinary guild channel message alone" do
      adapter = console_adapter
      adapter.start
      message = adapter.handle_event(
        FluxerFakes.dispatch("MESSAGE_CREATE", FluxerFakes.message_data(channel: "111111111", guild_id: "GLD-1"))
      )

      expect(lane.handled).to be_empty
      expect(message).not_to be_nil
    end

    it "does nothing when no control lane is wired" do
      expect { adapter.handle_event(dm(content: "!help")) }.not_to raise_error
    end
  end

  # Fluxer's payload carries guild_id rather than a channel_id, so every
  # endpoint configured for that guild is given its own join or leave.
  describe "member join and leave (issue #731)" do
    let(:guild_endpoint) do
      endpoint("fx-mod", adapter: :fluxer, settings: { channel_id: "111111111", guild_id: "GLD1", webhook: :off })
    end

    def member_adapter(endpoints: [guild_endpoint])
      described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: endpoints
      ).replace_client(client).replace_gateway(gateway)
    end

    it "turns GUILD_MEMBER_ADD into a join on the endpoint configured for that guild" do
      member_adapter.handle_event(FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: "GLD1")))

      message = dispatcher.last
      expect(message.kind).to eq(:join)
      expect(message.origin.id).to eq("fx-mod")
      expect(message.author.username).to eq("ada")
    end

    it "turns GUILD_MEMBER_REMOVE into a leave" do
      member_adapter.handle_event(
        FluxerFakes.dispatch("GUILD_MEMBER_REMOVE", FluxerFakes.member_data(guild_id: "GLD1"))
      )

      expect(dispatcher.last.kind).to eq(:leave)
    end

    it "reaches every endpoint configured for that guild, not only the first" do
      other = endpoint("fx-mod-2", adapter: :fluxer,
                                   settings: { channel_id: "333", guild_id: "GLD1", webhook: :off })
      member_adapter(endpoints: [guild_endpoint, other]).handle_event(
        FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: "GLD1"))
      )

      expect(dispatcher.messages.map { |m| m.origin.id }).to contain_exactly("fx-mod", "fx-mod-2")
    end

    it "does nothing for a guild no endpoint is configured for" do
      member_adapter.handle_event(FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: "OTHER")))

      expect(dispatcher.messages).to be_empty
    end

    # guild_id is documented on the schema as needed only for ban/kick, which
    # reads as an invitation to leave it out of a plain relay endpoint.
    # Ordinary message relay backs that up, since endpoint_for routes by
    # channel_id alone; join and leave must reach the same endpoint.
    it "reaches an endpoint configured with only channel_id, no guild_id set" do
      channel_only = endpoint("fx-relay", adapter: :fluxer, settings: { channel_id: "111111111", webhook: :off })
      client_with_channels = FluxerFakes::Client.new(
        guild_channels: { "GLD1" => [FluxerFakes.channel_data(id: "111111111", name: "general")] }
      )
      described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [channel_only]
      ).replace_client(client_with_channels).replace_gateway(gateway)
        .handle_event(FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: "GLD1")))

      expect(dispatcher.last.origin.id).to eq("fx-relay")
    end

    it "does not resolve a channel-only endpoint whose channel belongs to a different guild" do
      channel_only = endpoint("fx-relay", adapter: :fluxer, settings: { channel_id: "999", webhook: :off })
      client_with_channels = FluxerFakes::Client.new(
        guild_channels: { "GLD1" => [FluxerFakes.channel_data(id: "111111111", name: "general")] }
      )
      described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [channel_only]
      ).replace_client(client_with_channels).replace_gateway(gateway)
        .handle_event(FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: "GLD1")))

      expect(dispatcher.messages).to be_empty
    end
  end

  # MESSAGE_REACTION_ADD_MANY is a live gateway event, reachable only once a
  # session's IDENTIFY sets the debounce_reactions flag. This adapter's
  # IDENTIFY never sets it, so the event does not arrive today, but the walk
  # is cheap and correct either way.
  describe "the batched reaction add event (issue #741)" do
    it "turns each entry into its own reaction_add, through the ordinary reaction path" do
      adapter.handle_event(
        FluxerFakes.dispatch(
          "MESSAGE_REACTION_ADD_MANY",
          FluxerFakes.reaction_add_many_data(
            channel: "111111111", message: "700",
            reactions: [
              { "user_id" => "55", "emoji" => { "id" => nil, "name" => "👍" } },
              { "user_id" => "9", "emoji" => { "id" => nil, "name" => "🎉" } }
            ]
          )
        )
      )

      expect(dispatcher.messages.map(&:kind)).to eq(%i[reaction_add reaction_add])
      expect(dispatcher.messages.map { |m| m.reaction.emoji }).to eq(%w[👍 🎉])
      expect(dispatcher.messages.map { |m| m.author.native_id }).to eq(%w[55 9])
    end

    it "drops an entry for a channel nothing is bridged to, keeping the rest" do
      adapter.handle_event(
        FluxerFakes.dispatch(
          "MESSAGE_REACTION_ADD_MANY",
          FluxerFakes.reaction_add_many_data(
            channel: "999999999", message: "700",
            reactions: [{ "user_id" => "55", "emoji" => { "id" => nil, "name" => "👍" } }]
          )
        )
      )

      expect(dispatcher.messages).to be_empty
    end
  end

  # The two halves that were missing: the pending notice pend_guild never
  # posted, and the auto-leave timer that fires later, which needs both
  # supports_leave? and supports_space_notice? to do anything at all.
  describe "pending space notice and departure (issue #718)" do
    let(:discovery) { FluxerFakes::Discovery.new }
    let(:guild_id) { "8000000000000000008" }
    let(:client) do
      FluxerFakes::Client.new(guild_channels: { guild_id => [FluxerFakes.channel_data(id: "10", name: "general")] })
    end

    def enumerating_adapter(pending_spaces:)
      described_class.new(
        account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
        discovery: discovery, pending_spaces: pending_spaces
      ).replace_client(client).replace_gateway(gateway)
    end

    it "posts the pending notice into the guild and marks it posted" do
      outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(action: :pending, row: :row1, post_notice: true)
      spaces = FluxerFakes::PendingSpaces.new(outcome: outcome)

      enumerating_adapter(pending_spaces: spaces).handle_event(
        FluxerFakes.guild_created(id: guild_id, name: "CloudNine")
      )

      expect(client.sent.first).to include(channel: "10")
      expect(client.sent.first[:body][:content]).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE)
      expect(spaces.notices_marked).to eq([:row1])
    end

    it "never posts again once the outcome says the notice already went out" do
      outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(action: :pending, row: :row1, post_notice: false)
      spaces = FluxerFakes::PendingSpaces.new(outcome: outcome)

      enumerating_adapter(pending_spaces: spaces).handle_event(
        FluxerFakes.guild_created(id: guild_id, name: "CloudNine")
      )

      expect(client.sent).to be_empty
      expect(spaces.notices_marked).to be_empty
    end

    it "declares both halves the auto-leave timer needs" do
      adapter = enumerating_adapter(pending_spaces: nil)
      expect(adapter.supports_leave?).to be(true)
      expect(adapter.supports_space_notice?).to be(true)
    end

    it "posts a notice then leaves the guild" do
      adapter = enumerating_adapter(pending_spaces: nil)

      expect(adapter.leave_space(guild_id, notice: "goodbye")).to be(true)
      expect(client.sent.first[:body][:content]).to eq("goodbye")
      expect(client.left_guilds).to eq([guild_id])
    end

    it "still leaves when no notice is given" do
      adapter = enumerating_adapter(pending_spaces: nil)

      expect(adapter.leave_space(guild_id)).to be(true)
      expect(client.sent).to be_empty
      expect(client.left_guilds).to eq([guild_id])
    end

    it "posts a bare notice with no leave" do
      adapter = enumerating_adapter(pending_spaces: nil)

      expect(adapter.post_space_notice(guild_id, "please come back")).to be(true)
      expect(client.sent.first[:body][:content]).to eq("please come back")
      expect(client.left_guilds).to be_empty
    end
  end
end
