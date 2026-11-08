# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Discord::Webhook do
  let(:client) { DiscordFakes::Client.new }
  let(:channel) { client.channel("123456789") }
  let(:webhook_class) { Class.new(described_class) }

  subject(:webhooks) do
    webhook_class.new(client: client, logger: Rubotty::Log.null, bridge_name: "rubotty")
  end

  before do
    allow(File).to receive(:binread).and_call_original
    allow(File).to receive(:binread).with(described_class::LOGO_PATH).and_return("\x89PNG\r\n\x1a\n".b)
  end

  def endpoint_with(**settings)
    endpoint("dc", adapter: :discord, settings: { channel_id: "123456789" }.merge(settings))
  end

  describe "resolving a webhook" do
    it "creates one when the channel has none" do
      expect(webhooks.for(endpoint_with(webhook: :auto))).not_to be_nil
      expect(channel.created_webhooks.map(&:name)).to eq(["rubotty"])
    end

    # So a message with no per sender picture shows the Rubotty icon.
    it "gives a newly created webhook the Rubotty logo as its default avatar" do
      webhooks.for(endpoint_with(webhook: :auto))
      created = channel.created_webhooks.first
      expect(created.avatar).to eq("data:image/png;base64,iVBORw0KGgo=")
    end

    # A webhook made before the logo existed carries Discord's default, and
    # adoption on startup is the only path that ever fixes it.
    it "sets the Rubotty avatar on an adopted webhook that has none" do
      channel.existing_webhooks << DiscordFakes::Hook.new(id: "old", name: "rubotty", token: "t")
      webhooks.for(endpoint_with(webhook: :auto))
      adopted = channel.existing_webhooks.first
      expect(adopted.avatar).to eq("data:image/png;base64,iVBORw0KGgo=")
      expect(adopted.avatar_writes).to eq(1)
    end

    # A steady state restart must not rewrite the avatar every time.
    it "leaves an adopted webhook's avatar alone when it already has one" do
      channel.existing_webhooks << DiscordFakes::Hook.new(
        id: "old", name: "rubotty", token: "t", avatar: "existing-hash"
      )
      webhooks.for(endpoint_with(webhook: :auto))
      adopted = channel.existing_webhooks.first
      expect(adopted.avatar).to eq("existing-hash")
      expect(adopted.avatar_writes).to eq(0)
    end

    it "leaves Discord to supply the default avatar when the logo is absent" do
      allow(File).to receive(:binread).with(described_class::LOGO_PATH).and_raise(Errno::ENOENT)
      webhooks.for(endpoint_with(webhook: :auto))

      expect(channel.created_webhooks.first.avatar).to be_nil
    end

    # Without reuse, every restart adds another, up to Discord's limit of ten per channel.
    it "reuses a webhook this bridge already made" do
      channel.existing_webhooks << DiscordFakes::Hook.new(id: "old", name: "rubotty", token: "t")
      webhooks.for(endpoint_with(webhook: :auto))
      expect(channel.created_webhooks).to be_empty
    end

    it "ignores a webhook somebody else made" do
      channel.existing_webhooks << DiscordFakes::Hook.new(id: "other", name: "some-app", token: "t")
      webhooks.for(endpoint_with(webhook: :auto))
      expect(channel.created_webhooks.size).to eq(1)
    end

    it "ignores a webhook with no token, which cannot be used to post" do
      channel.existing_webhooks << DiscordFakes::Hook.new(id: "x", name: "rubotty", token: nil)
      webhooks.for(endpoint_with(webhook: :auto))
      expect(channel.created_webhooks.size).to eq(1)
    end

    it "does not touch webhooks at all when turned off" do
      expect(webhooks.for(endpoint_with(webhook: :off))).to be_nil
      expect(channel.created_webhooks).to be_empty
    end

    # A bridge that relays imperfectly beats one that does not relay.
    it "degrades to bot posting when the bot lacks Manage Webhooks" do
      channel.webhook_error = RuntimeError.new("Missing Permissions")
      expect(webhooks.for(endpoint_with(webhook: :auto))).to be_nil
    end

    it "caches the negative result, so a forbidden channel is not re probed" do
      channel.webhook_error = RuntimeError.new("Missing Permissions")
      3.times { webhooks.for(endpoint_with(webhook: :auto)) }
      # One attempt at listing, one at creating, then nothing further.
      expect(webhooks.for(endpoint_with(webhook: :auto))).to be_nil
    end

    it "can be told to forget, so a webhook deleted in Discord is replaced" do
      webhooks.for(endpoint_with(webhook: :auto))
      # Somebody removes it in the channel's integration settings.
      channel.existing_webhooks.clear
      webhooks.forget(endpoint_with(webhook: :auto))
      webhooks.for(endpoint_with(webhook: :auto))
      expect(channel.created_webhooks.size).to eq(2)
    end

    it "does not re resolve while the cached webhook is still good" do
      3.times { webhooks.for(endpoint_with(webhook: :auto)) }
      expect(channel.created_webhooks.size).to eq(1)
    end
  end

  describe "#puppet_snapshot" do
    it "starts empty, before anything has been asked to resolve" do
      expect(webhooks.puppet_snapshot).to eq({})
    end

    it "reports :active once a webhook resolves" do
      endpoint = endpoint_with(webhook: :auto)
      webhooks.for(endpoint)
      expect(webhooks.puppet_snapshot).to eq(endpoint.id => :active)
    end

    it "reports :off for an endpoint turned off, without attempting anything" do
      endpoint = endpoint_with(webhook: :off)
      webhooks.for(endpoint)
      expect(webhooks.puppet_snapshot).to eq(endpoint.id => :off)
    end

    it "reports :degraded when the bot lacks Manage Webhooks" do
      channel.webhook_error = RuntimeError.new("Missing Permissions")
      endpoint = endpoint_with(webhook: :auto)
      webhooks.for(endpoint)
      expect(webhooks.puppet_snapshot).to eq(endpoint.id => :degraded)
    end

    it "drops the entry on #forget, so a stale answer is not reported until re resolved" do
      endpoint = endpoint_with(webhook: :auto)
      webhooks.for(endpoint)
      webhooks.forget(endpoint)
      expect(webhooks.puppet_snapshot).to eq({})
    end
  end

  # "Already gone" must read as success, or the periodic reap retries the same
  # message until it is abandoned.
  describe "#delete" do
    def hook_raising(error)
      Class.new do
        define_method(:delete_message) { |_id| raise error }
      end.new
    end

    it "treats Discordrb::Errors::UnknownMessage (code 10008) as success" do
      require "discordrb"
      hook = hook_raising(Discordrb::Errors::UnknownMessage.new("Unknown Message"))
      expect { webhooks.delete(hook, "123") }.not_to raise_error
    end

    it "treats RestClient::ResourceNotFound as success" do
      # The webhook client's #delete_message wraps RestClient::Resource#delete
      # with none of the bot REST client's mapping of a 404 onto
      # Discordrb::Errors::UnknownMessage, so a 404 surfaces raw here.
      require "rest-client"
      hook = hook_raising(RestClient::ResourceNotFound.new)
      expect { webhooks.delete(hook, "123") }.not_to raise_error
    end

    it "still raises a genuinely different error" do
      hook = hook_raising(StandardError.new("something else"))
      expect { webhooks.delete(hook, "123") }.to raise_error(StandardError, "something else")
    end

    # discordrb-webhooks 3.8.0's #delete_message takes no thread_id, unlike
    # #execute and #edit_message, so a thread message's delete has to build
    # the request itself rather than call through the gem method.
    it "targets the thread when a thread_id is given, since delete_message cannot carry one" do
      require "discordrb/webhooks"
      real_hook = Discordrb::Webhooks::Client.new(id: "123", token: "tok")
      captured = nil
      allow(RestClient).to receive(:delete) { |url| captured = url }

      webhooks.delete(real_hook, "900", thread_id: "9999999999999999")

      expect(captured).to include("/webhooks/123/tok/messages/900")
      expect(captured).to include("thread_id=9999999999999999")
    end

    it "calls the ordinary delete_message when no thread_id is given" do
      require "discordrb/webhooks"
      real_hook = Discordrb::Webhooks::Client.new(id: "123", token: "tok")
      allow(RestClient).to receive(:delete) { |url| Struct.new(:body, :code).new("", 204).tap { url } }

      webhooks.delete(real_hook, "900")

      expect(RestClient).to have_received(:delete).with("https://discord.com/api/v9/webhooks/123/tok/messages/900")
    end
  end

  # +thread_id+ is what lets an edit or a delete reach a message posted into a
  # thread under the webhook's own channel.
  describe "#edit with a thread_id" do
    it "passes it straight through to edit_message" do
      require "discordrb/webhooks"
      real_hook = Discordrb::Webhooks::Client.new(id: "123", token: "tok")
      allow(RestClient).to receive(:patch) { |url| Struct.new(:body, :code).new("", 200).tap { url } }

      webhooks.edit(real_hook, "900", content: "fixed", thread_id: "9999999999999999")

      expect(RestClient).to have_received(:patch).with(
        a_string_including("/messages/900?thread_id=9999999999999999"), anything, anything
      )
    end
  end

  # A malformed or unexpected response used to come back as a bare nil,
  # indistinguishable from a working send anywhere the caller looked.
  describe "#execute logging a response it cannot use" do
    let(:warnings) { [] }
    let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
    subject(:logging_webhooks) { described_class.new(client: client, logger: logger, bridge_name: "rubotty") }

    before { allow(logger).to receive(:warn) { |&block| warnings << block.call } }

    def hook_returning(body:, code: nil)
      Class.new do
        define_method(:execute) { |*| Struct.new(:body, :code).new(body, code) }
      end.new
    end

    it "warns, naming the response code, on an empty body" do
      result = logging_webhooks.execute(hook_returning(body: "", code: 204), content: "hi", username: "ada")

      expect(result).to be_nil
      expect(warnings.join("\n")).to include("204")
    end

    it "warns, naming the response code, when the body is not JSON" do
      result = logging_webhooks.execute(hook_returning(body: "not json", code: 200), content: "hi", username: "ada")

      expect(result).to be_nil
      expect(warnings.join("\n")).to include("200")
    end

    it "still warns when the response carries no code at all" do
      hook = Class.new { define_method(:execute) { |*| "" } }.new
      result = logging_webhooks.execute(hook, content: "hi", username: "ada")

      expect(result).to be_nil
      expect(warnings).not_to be_empty
    end
  end

  # #execute_files is only exercised against DiscordFakes::WebhookClient
  # elsewhere, which never touches the wire format. This runs it through the
  # REAL Discordrb::Webhooks::Client, stopping only at RestClient.post, so a
  # future change that broke the wire shape would show up here.
  describe "#execute_files against the real Discordrb::Webhooks::Client" do
    before { require "discordrb/webhooks" }

    def open_file(contents, name)
      file = Tempfile.new(name)
      file.binmode
      file.write(contents)
      file.rewind
      file.define_singleton_method(:original_filename) { name }
      file
    end

    it "posts one multipart request carrying files[0], files[1] and a payload_json part" do
      real_hook = Discordrb::Webhooks::Client.new(id: "123", token: "tok")
      captured = nil
      allow(RestClient).to receive(:post) do |url, payload|
        captured = { url: url, payload: payload }
        Struct.new(:body, :code).new(%({"id":"999"}), 200)
      end

      file0 = open_file("one", "a.png")
      file1 = open_file("two", "b.png")
      webhooks = described_class.new(client: client, logger: Rubotty::Log.null, bridge_name: "rubotty")

      result = webhooks.execute_files(real_hook, content: "album caption", username: "ada",
                                                  files: [file0, file1],
                                                  allowed_mentions: { parse: [], users: [], roles: [] })

      expect(result).to eq("id" => "999")
      expect(captured[:url]).to include("wait=true")
      expect(captured[:payload]).to have_key("files[0]")
      expect(captured[:payload]).to have_key("files[1]")
      expect(captured[:payload]).to have_key(:payload_json)

      # The literal bytes RestClient would have written to the socket: the
      # same encoder discordrb's post_multipart hands a hash to for a single
      # file today, run here over a hash carrying two.
      body = RestClient::Payload::Multipart.new(captured[:payload]).to_s
      expect(body).to include('name="files[0]"')
      expect(body).to include('name="files[1]"')
      expect(body).to include('name="payload_json"')

      sent = JSON.parse(captured[:payload][:payload_json])
      expect(sent["content"]).to eq("album caption")
      expect(sent["allowed_mentions"]).to eq("parse" => [], "users" => [], "roles" => [])
      expect(sent["attachments"]).to eq(
        [{ "id" => 0, "filename" => "a.png" }, { "id" => 1, "filename" => "b.png" }]
      )
    ensure
      [file0, file1].each { |f| f&.close! }
    end
  end

  # Discord rejects a username breaking these rules, and the rejection fails the
  # whole send.
  describe ".sanitise_username" do
    it "passes an ordinary name through" do
      expect(described_class.sanitise_username("Alex (alex)")).to eq("Alex (alex)")
    end

    it "breaks up the reserved word discord" do
      expect(described_class.sanitise_username("discord fan")).not_to match(/discord/i)
    end

    it "breaks up the reserved word clyde" do
      expect(described_class.sanitise_username("clyde")).not_to match(/clyde/i)
    end

    it "keeps a name containing a reserved word legible" do
      expect(described_class.sanitise_username("discordian")).to eq("d.iscordian")
    end

    it "truncates to Discord's 80 character limit" do
      expect(described_class.sanitise_username("x" * 200).length).to eq(80)
    end

    # Eats into the display name rather than cutting off the bracketed handle mid platform tag.
    it "shortens an over long structured label by eating the display name, not the bracketed handle" do
      long = "#{"A" * 100} [owner_handle@telegram]"
      result = described_class.sanitise_username(long)
      expect(result).to end_with(" [owner_handle@telegram]")
      expect(result.length).to eq(80)
    end

    it "substitutes a fallback for an empty name" do
      expect(described_class.sanitise_username("", fallback: "bridge")).to eq("bridge")
      expect(described_class.sanitise_username("   ", fallback: "bridge")).to eq("bridge")
    end

    it "defuses the names that would ping a whole server" do
      expect(described_class.sanitise_username("everyone")).to eq("everyone.")
      expect(described_class.sanitise_username("here")).to eq("here.")
    end
  end
end

RSpec.describe Rubotty::Adapters::Discord::Adapter, "webhook delivery" do
  let(:client) { DiscordFakes::Client.new }
  let(:hook) { DiscordFakes::WebhookClient.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:general) do
    endpoint("dc-general", adapter: :discord,
                           settings: { channel_id: "8000000000000000003", webhook: :auto })
  end

  subject(:adapter) do
    described_class.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
    ).replace_client(client)
  end

  let(:channel) { client.channel("8000000000000000003") }
  let(:outgoing) { message(general, text: "hello").with(sender_label: "Alex (alex)") }

  before do
    adapter.start
    allow(adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
  end

  it "posts under the sender's own name rather than the bot's" do
    adapter.deliver(outgoing, general)
    expect(hook.executed.first[:username]).to eq("Alex (alex)")
  end

  it "omits the sender prefix, since the webhook already carries the name" do
    adapter.deliver(outgoing, general)
    expect(hook.executed.first[:content]).to eq("hello")
  end

  # A webhook execute carries no message_reference, so a reply relayed through
  # one can only ever show as a quoted block of text, never a real Discord
  # reply. Sending it as the bot instead trades the impersonated name for a
  # native reply link.
  describe "when the message is a reply" do
    let(:replying) do
      message(general, text: "hi back", reply_to: ref(general.id, "999")).with(sender_label: "Alex (alex)")
    end

    it "posts as the bot instead of the webhook" do
      adapter.deliver(replying, general)
      expect(hook.executed).to be_empty
      expect(channel.sent).not_to be_empty
    end

    it "carries a real message_reference to the replied to message" do
      adapter.deliver(replying, general)
      expect(channel.sent.last[:message_reference]).to eq(message_id: 999, fail_if_not_exists: false)
    end

    it "puts the sender's name back as a text prefix, since the bot has no impersonated username" do
      adapter.deliver(replying, general)
      expect(channel.sent.last[:content]).not_to eq("hi back")
      expect(channel.sent.last[:content]).to include("Alex (alex)")
    end

    it "still goes out through the webhook when the reply target is not on this endpoint" do
      elsewhere = message(general, text: "hi back", reply_to: ref("some-other-endpoint", "999"))
                  .with(sender_label: "Alex (alex)")
      adapter.deliver(elsewhere, general)
      expect(hook.executed).not_to be_empty
      expect(channel.sent).to be_empty
    end
  end

  # The structured label goes in the webhook username and stays out of the text,
  # so "@platform" is not shown twice.
  describe "with a structured cross platform label" do
    let(:structured) do
      message(general, text: "hello").with(
        sender_label: Rubotty::Core::SenderLabel.new(
          username: "sample_owner", platform: "telegram", display_name: "Alex R"
        )
      )
    end

    it "uses the plain text label as the webhook username" do
      adapter.deliver(structured, general)
      expect(hook.executed.first[:username]).to eq("Alex R [sample_owner@telegram]")
    end

    it "still omits the in text prefix" do
      adapter.deliver(structured, general)
      expect(hook.executed.first[:content]).to eq("hello")
    end
  end

  it "returns a receipt carrying the created message id" do
    receipt = adapter.deliver(outgoing, general)
    expect(receipt.native_id).to eq("wh-1")
  end

  it "still suppresses mass mentions" do
    adapter.deliver(outgoing, general)
    expect(hook.executed.first[:allowed_mentions]).to eq(parse: [], users: [], roles: [])
  end

  it "passes a Discord avatar through" do
    with_avatar = outgoing.with(
      author: Rubotty::Core::Author.new(native_id: "1", username: "alex",
                                           avatar_url: "https://cdn.discordapp.com/avatars/1/a.png")
    )
    adapter.deliver(with_avatar, general)
    expect(hook.executed.first[:avatar_url]).to eq("https://cdn.discordapp.com/avatars/1/a.png")
  end

  # A per message avatar_url wins over the webhook's own default.
  it "keeps the sender's real public avatar taking precedence over the default" do
    with_avatar = outgoing.with(
      author: Rubotty::Core::Author.new(native_id: "1", username: "alex",
                                          avatar_url: "https://cdn.discordapp.com/avatars/1/a.png")
    )
    expect(adapter.send(:webhook_avatar, with_avatar))
      .to eq("https://cdn.discordapp.com/avatars/1/a.png")
  end

  # A Telegram file URL embeds the bot token, so handing one to Discord to fetch
  # would leak it.
  it "refuses to use an avatar URL that embeds a bot token" do
    leaky = outgoing.with(
      author: Rubotty::Core::Author.new(
        native_id: "1", username: "alex",
        avatar_url: "https://api.telegram.org/file/bot123:ABC/photos/a.jpg"
      )
    )
    adapter.deliver(leaky, general)
    expect(hook.executed.first[:avatar_url]).to be_nil
  end

  it "edits through the same webhook, since the bot cannot edit its messages" do
    adapter.edit(outgoing.with(body: Rubotty::Core::RichText.plain("fixed")), general, "wh-1")
    expect(hook.edited.first[:id]).to eq("wh-1")
    expect(hook.edited.first[:content]).to include("fixed")
  end

  it "quotes a reply, because a webhook cannot make a native one" do
    preview = Rubotty::Core::ReplyPreview.new(
      body: Rubotty::Core::RichText.plain("the original"), label: "Grace"
    )
    adapter.deliver(outgoing.with(reply_preview: preview), general)
    expect(hook.executed.first[:content]).to start_with("> **Grace**: the original")
  end

  # Nothing to post and no file to upload, so the send never happens. A bare nil
  # here had Bridge log RELAY LOST and count the message in the backfill loss
  # total, which is the one thing this case is not.
  it "signals a blank webhook send as NOT_APPLICABLE rather than a bare nil" do
    receipt = adapter.deliver(message(general, text: ""), general)
    expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
    expect(receipt).to be_nil
    expect(hook.executed).to be_empty
  end

  # A webhook deleted in the channel settings must not cost the message.
  it "falls back to bot posting when the webhook has gone" do
    hook.fail_next(RuntimeError.new("Unknown Webhook"))
    adapter.deliver(outgoing, general)
    expect(channel.sent.size).to eq(1)
    expect(channel.sent.first[:content]).to include("Alex (alex)")
  end

  # A rate limit is not a broken webhook: the same webhook still works once
  # the wait passes, so rewriting it as "posting as bot" and forgetting the
  # webhook is what let a genuinely throttled channel look like ordinary
  # flakiness on the board rather than the rate limit it actually was.
  describe "a webhook 429" do
    def too_many_requests(retry_after:)
      require "rest-client"
      response = Struct.new(:code, :body).new(429, %({"retry_after": #{retry_after}}))
      RestClient::TooManyRequests.new(response)
    end

    it "raises RateLimitedError rather than falling back to posting as the bot" do
      hook.fail_next(too_many_requests(retry_after: 2.5))
      expect { adapter.deliver(outgoing, general) }.to raise_error(Rubotty::RateLimitedError)
      expect(channel.sent).to be_empty
    end

    it "carries the retry_after Discord asked for, rounded up" do
      hook.fail_next(too_many_requests(retry_after: 2.5))
      caught = nil
      begin
        adapter.deliver(outgoing, general)
      rescue Rubotty::RateLimitedError => e
        caught = e
      end
      expect(caught.retry_after).to eq(3)
    end

    it "does not forget the webhook, since it is not actually broken" do
      hook.fail_next(too_many_requests(retry_after: 1))
      manager = adapter.instance_variable_get(:@webhooks)
      expect(manager).not_to receive(:forget)
      expect { adapter.deliver(outgoing, general) }.to raise_error(Rubotty::RateLimitedError)
    end
  end

  it "forgets a failed webhook so the next send re resolves it" do
    manager = adapter.instance_variable_get(:@webhooks)
    expect(manager).to receive(:forget).with(general)
    hook.fail_next(RuntimeError.new("Unknown Webhook"))
    adapter.deliver(outgoing, general)
  end

  it "uploads a file through the webhook" do
    attachment = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png",
                                                  filename: "a.png")
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: lambda { |_uri, _filename|
        StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
      }
    )
    adapter.instance_variable_set(:@fetcher, fetcher)
    adapter.deliver(outgoing.with(attachments: [attachment]), general)
    expect(hook.executed.first[:file]).not_to be_nil
  end

  # webhook: :auto is the default, so this is the path a puppeted album
  # actually takes in production. Discord groups every file on ONE message
  # into a gallery; splitting them across several executes is what produced
  # the one photo per post bug, so this fails on the un-fixed adapter.
  it "uploads every attachment in one execute, so Discord renders one gallery rather than a post per photo" do
    files = %w[a.png b.png c.png].map do |name|
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/#{name}", filename: name)
    end
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: lambda { |_uri, _filename|
        StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
      }
    )
    adapter.instance_variable_set(:@fetcher, fetcher)

    adapter.deliver(outgoing.with(attachments: files), general)

    expect(hook.executed.size).to eq(1)
    expect(hook.executed.first[:files].size).to eq(3)
  end

  # group_for_upload used to read a private max_upload_bytes helper of its
  # own, falling back to a hardcoded 25 MB rather than the shared
  # upload_limit, and treated 0 as a set limit (Ruby's || sees 0 as truthy)
  # rather than unset, though it should still group like any other album.
  it "still groups an album under one execute when max_upload_bytes is 0, treating it as unset like upload_limit does" do
    zeroed_adapter = described_class.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN", max_upload_bytes: 0 },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
    ).replace_client(client)
    zeroed_adapter.start
    allow(zeroed_adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)

    files = %w[a.png b.png].map do |name|
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/#{name}", filename: name)
    end
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: lambda { |_uri, _filename|
        StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
      }
    )
    zeroed_adapter.instance_variable_set(:@fetcher, fetcher)

    zeroed_adapter.deliver(outgoing.with(attachments: files), general)

    expect(hook.executed.size).to eq(1)
    expect(hook.executed.first[:files].size).to eq(2)
  end

  # Discord caps a message at ten attachments, so an eleven photo album has to
  # become two messages rather than either failing whole or falling back to
  # eleven separate posts.
  it "splits an album over Discord's ten attachment cap into as few messages as possible" do
    files = (1..11).map do |n|
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/#{n}.png", filename: "#{n}.png")
    end
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: lambda { |_uri, _filename|
        StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
      }
    )
    adapter.instance_variable_set(:@fetcher, fetcher)

    adapter.deliver(outgoing.with(attachments: files), general)

    expect(hook.executed.size).to eq(2)
    expect(hook.executed.map { |entry| entry[:files].size }).to eq([10, 1])
  end

  # One album, one Discord message, one id in the message map: a delete of it
  # has nothing left over to remove.
  it "deletes the whole album with a single delete, since the album is a single message" do
    files = %w[a.png b.png c.png].map do |name|
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/#{name}", filename: name)
    end
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: lambda { |_uri, _filename|
        StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
      }
    )
    adapter.instance_variable_set(:@fetcher, fetcher)

    receipt = adapter.deliver(outgoing.with(attachments: files), general)
    adapter.delete(general, receipt.native_id)

    expect(hook.deleted).to eq([receipt.native_id])
  end

  # note_failed_upload already fed the bot posting path's receipt; the webhook
  # path never plugged it in at all, so the sender learned nothing went wrong.
  it "notes an attachment the webhook could not fetch, so the sender learns about it" do
    files = [
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png"),
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/bad.png", filename: "bad.png")
    ]
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: lambda { |_uri, filename|
        next nil if filename == "bad.png"

        StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
      }
    )
    adapter.instance_variable_set(:@fetcher, fetcher)

    receipt = adapter.deliver(outgoing.with(attachments: files), general)

    expect(receipt.extra[:notes]).not_to be_nil
    expect(receipt.extra[:notes].join).to include("bad.png")
  end

  # Nothing crossed used to return as soon as the first missed attachment
  # got a fallback message, dropping every other one silently rather than
  # just losing its upload: a two photo album where both downloads failed
  # posted one broken reference and threw the second photo away outright.
  it "still posts a fallback for every attachment when none of them cross" do
    files = [
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/first.png", filename: "first.png"),
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/second.png", filename: "second.png")
    ]
    fetcher = Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { nil })
    adapter.instance_variable_set(:@fetcher, fetcher)

    receipt = adapter.deliver(outgoing.with(attachments: files), general)

    expect(receipt.extra[:notes].join).to include("first.png").and include("second.png")
    posted = hook.executed.map { |call| call[:content] }.join("\n")
    expect(posted).to include("first.png")
    expect(posted).to include("second.png")
  end

  # A nil from the fetcher (no download) and a nil from the webhook call (a
  # response the webhook could not use) used to be indistinguishable outside
  # this method, which is why a failed album upload logged nothing about
  # which half came back empty.
  describe "logging which half of an upload failed" do
    let(:warnings) { [] }
    let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
    let(:logging_adapter) do
      described_class.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: logger, endpoints: [general]
      ).replace_client(client)
    end

    before do
      allow(logger).to receive(:warn) { |&block| warnings << block.call }
      allow(logging_adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
    end

    it "names the attachment and says the download produced no file" do
      attachment = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png",
                                                    filename: "a.png")
      fetcher = Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { nil })
      logging_adapter.instance_variable_set(:@fetcher, fetcher)

      logging_adapter.deliver(outgoing.with(attachments: [attachment]), general)

      expect(warnings.join("\n")).to include("a.png")
      expect(warnings.join("\n")).to match(/download/)
    end

    it "names the attachment and says the webhook call returned no id, when the download succeeds but the post does not" do
      attachment = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png",
                                                    filename: "a.png")
      fetcher = Rubotty::Util::MediaFetcher.new(
        http: lambda { |_uri, _filename|
          StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
        }
      )
      logging_adapter.instance_variable_set(:@fetcher, fetcher)
      broken_hook = Class.new { define_method(:execute) { |*| Struct.new(:body).new("") } }.new
      allow(logging_adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(broken_hook)

      logging_adapter.deliver(outgoing.with(attachments: [attachment]), general)

      expect(warnings.join("\n")).to include("a.png")
      expect(warnings.join("\n")).to match(/webhook call/)
    end
  end

  # The multi file upload rides content and allowed_mentions in the same
  # payload_json part the files travel in (see Webhook#execute_files), so a
  # caption of "@everyone look" can go out on the same message as the photo
  # rather than needing a second message just to carry the whitelist safely.
  it "sends the caption on the same message as the file, still carrying the whitelist" do
    attachment = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png",
                                                  filename: "a.png")
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: lambda { |_uri, _filename|
        StringIO.new("PNG").tap { |io| io.define_singleton_method(:unlink) { nil } }
      }
    )
    adapter.instance_variable_set(:@fetcher, fetcher)
    captioned = outgoing.with(attachments: [attachment],
                              body: Rubotty::Core::RichText.plain("@everyone look"))
    adapter.deliver(captioned, general)

    expect(hook.executed.size).to eq(1)
    file_message = hook.executed.first
    expect(file_message[:content]).to include("@everyone look")
    expect(file_message[:files]).not_to be_empty
    expect(file_message[:allowed_mentions]).to eq(parse: [], users: [], roles: [])
  end

end
