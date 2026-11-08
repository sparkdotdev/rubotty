# frozen_string_literal: true

require "spec_helper"

# A remote HTTP system bridged as a first party platform: REST in, signed
# webhook POST out. These specs build the adapter directly rather than
# through Core::Runtime, and inject a fake Client so nothing here opens a
# real socket.
RSpec.describe Rubotty::Adapters::ApiWrapper::Adapter, :control_plane do
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:models) { seeded_sample[1] }
  let(:events) { Rubotty::ControlPlane::ApiWrapperEvents.new(models: models) }
  let(:client) { Fakes::ApiWrapperClient.new }
  # Named "support_endpoint" rather than "endpoint": Builders#endpoint is the
  # shared constructor every spec in this suite calls, and a `let` of the
  # same name would shadow it inside its own block.
  let(:support_endpoint) do
    endpoint("acme:support-42", adapter: :api_wrapper, account: "acme", settings: { channel_id: "support-42" })
  end

  subject(:adapter) do
    described_class.new(
      account: "acme", settings: { webhook_url: "https://example.invalid/hook", signing_secret: "whsec_x" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [support_endpoint]
    ).replace_client(client)
  end

  before { adapter.inbound_events = events }

  # The floor claims edits, deletes, reactions and seven moderation verbs, and
  # the remote behind one account is any HTTP system at all. Without a way to
  # declare less, a game server that cannot edit is held to a promise it cannot
  # keep, which is what blocked bridging one through here.
  describe "an account that declares less than the floor" do
    subject(:narrowed) do
      described_class.new(
        account: "acme",
        settings: { webhook_url: "https://example.invalid/hook", signing_secret: "whsec_x",
                    unsupported: %w[edits reactions ban] },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [support_endpoint]
      ).replace_client(client)
    end

    it "turns off the named capabilities and leaves the rest" do
      expect(narrowed.capabilities.edits?).to be(false)
      expect(narrowed.capabilities.reactions?).to be(false)
      expect(narrowed.capabilities.deletes?).to be(true)
    end

    it "drops only the named moderation verb" do
      expect(narrowed.capabilities.moderates?(:ban)).to be(false)
      expect(narrowed.capabilities.moderates?(:kick)).to be(true)
    end

    it "answers unsupported for a verb the account said it does not have" do
      ban = Rubotty::Core::Moderation::Command.new(
        action: :ban, issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: support_endpoint, target_user_id: "u1"
      )
      expect(narrowed.moderate(ban, support_endpoint, nil).status).to eq(:unsupported)
    end

    it "leaves an account that named nothing on the full floor" do
      expect(adapter.capabilities.to_h).to eq(described_class::CAPABILITIES.to_h)
    end

    it "ignores a name that is not a capability rather than raising" do
      quiet = described_class.new(
        account: "acme",
        settings: { webhook_url: "https://example.invalid/hook", signing_secret: "whsec_x",
                    unsupported: %w[nonesuch] },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [support_endpoint]
      )
      expect(quiet.capabilities.to_h).to eq(described_class::CAPABILITIES.to_h)
    end
  end

  describe "class contract" do
    it "declares a unique adapter name" do
      expect(described_class.adapter_name).to eq(:api_wrapper)
    end

    it "stays dormant with no secret, like every other credentialed adapter" do
      expect(described_class.dormant_on_missing_secret?).to be(true)
    end

    it "refuses a webhook_url that is not https" do
      problems = described_class.validate_account({ webhook_url: "http://example.invalid/hook" }, "accounts.acme")
      expect(problems).not_to be_empty
    end

    it "reads route_key_for off the configured channel_id" do
      expect(described_class.route_key_for(support_endpoint)).to eq("support-42")
    end
  end

  describe "#own_account_id" do
    it "is populated and stable, distinct from any real user id" do
      adapter.start
      expect(adapter.own_account_id).to eq("rubotty-api-wrapper")
      adapter.stop
    end
  end

  describe "#deliver" do
    it "declines quietly when there is nothing to send" do
      blank = message(support_endpoint, text: "")

      expect(adapter.deliver(blank, support_endpoint)).to eq(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(client.calls).to be_empty
    end

    it "signs and posts a message.created event, and returns a receipt with a minted native id" do
      outgoing = message(support_endpoint, text: "hello from elsewhere", author: author(native_id: "u9", username: "bea"))

      receipt = adapter.deliver(outgoing, support_endpoint)

      expect(receipt.endpoint_id).to eq(support_endpoint.id)
      expect(receipt.native_id).not_to be_empty
      call = client.calls.first
      expect(call.type).to eq("message.created")
      expect(call.data["channel_id"]).to eq("support-42")
      expect(call.data["body"]).to eq("hello from elsewhere")
      expect(call.data["message_id"]).to eq(receipt.native_id)
    end

    it "raises AdapterError, retryable, on a 5xx" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 503, body: "down"))
      outgoing = message(support_endpoint, text: "hi")

      expect { adapter.deliver(outgoing, support_endpoint) }.to raise_error(Rubotty::AdapterError) do |e|
        expect(e.retryable?).to be(true)
      end
    end

    it "raises AdapterError, not retryable, on a 4xx other than 410" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 400, body: "bad"))
      outgoing = message(support_endpoint, text: "hi")

      expect { adapter.deliver(outgoing, support_endpoint) }.to raise_error(Rubotty::AdapterError) do |e|
        expect(e.retryable?).to be(false)
      end
    end
  end

  describe "#edit and #delete" do
    it "posts message.edited and returns a receipt" do
      receipt = adapter.edit(message(support_endpoint, text: "fixed"), support_endpoint, "abc123")

      expect(receipt.native_id).to eq("abc123")
      expect(client.calls.first.type).to eq("message.edited")
    end

    it "answers nil, not a raise, when the remote reports 410 gone" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 410, body: ""))

      expect(adapter.edit(message(support_endpoint, text: "fixed"), support_endpoint, "abc123")).to be_nil
    end

    it "#delete posts message.deleted and does not raise on 410" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 410, body: ""))

      expect { adapter.delete(support_endpoint, "abc123") }.not_to raise_error
      expect(client.calls.first.type).to eq("message.deleted")
    end

    it "#delete raises on a genuine failure" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 500, body: "boom"))

      expect { adapter.delete(support_endpoint, "abc123") }.to raise_error(Rubotty::AdapterError)
    end
  end

  describe "#sync_reactions" do
    it "posts one reaction.added per newly desired reaction" do
      thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")

      adapter.sync_reactions(support_endpoint, "m1", desired: [thumbs], previous: [])

      expect(client.calls.map(&:type)).to eq(["reaction.added"])
    end

    it "posts reaction.removed for what dropped out of the desired set" do
      thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")

      adapter.sync_reactions(support_endpoint, "m1", desired: [], previous: [thumbs])

      expect(client.calls.map(&:type)).to eq(["reaction.removed"])
    end

    it "raises on a refusal, since a swallowed one leaves storage believing in an emoji that is not there" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 403, body: "no"))
      thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")

      expect do
        adapter.sync_reactions(support_endpoint, "m1", desired: [thumbs], previous: [])
      end.to raise_error(Rubotty::AdapterError)
    end

    it "swallows an already-gone 410 rather than raising" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 410, body: ""))
      thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")

      expect do
        adapter.sync_reactions(support_endpoint, "m1", desired: [thumbs], previous: [])
      end.not_to raise_error
    end
  end

  describe "#moderate" do
    def command(action, target_user_id: nil)
      Rubotty::Core::Moderation::Command.new(
        action: action, issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: support_endpoint, target_user_id: target_user_id
      )
    end

    it "answers :done on a 2xx" do
      result = adapter.moderate(command(:delete), support_endpoint, "m1")

      expect(result.status).to eq(:done)
      expect(client.calls.first.type).to eq("moderation.delete")
    end

    it "answers :forbidden on a 403" do
      client.queue(Rubotty::Adapters::ApiWrapper::Client::Response.new(status: 403, body: "no"))

      expect(adapter.moderate(command(:ban, target_user_id: "u1"), support_endpoint, nil).status).to eq(:forbidden)
    end

    it "answers :failed rather than raising when the client cannot reach the remote at all" do
      allow(client).to receive(:post).and_raise(
        Rubotty::AdapterError.new("unreachable", adapter: :api_wrapper, retryable: true)
      )

      expect(adapter.moderate(command(:kick, target_user_id: "u1"), support_endpoint, nil).status).to eq(:failed)
    end
  end

  describe "#receive_pending" do
    it "does nothing, quietly, with no inbound_events (no control plane)" do
      adapter.inbound_events = nil

      expect { adapter.receive_pending }.not_to raise_error
      expect(dispatcher.messages).to be_empty
    end

    it "emits a queued message as a chat message carrying the real remote author" do
      events.enqueue_message(account: "acme", channel_id: "support-42", body: "hi there",
                             author: { native_id: "u1", display_name: "Remote Ada" })

      adapter.receive_pending

      incoming = dispatcher.last
      expect(incoming.kind).to eq(:chat)
      expect(incoming.origin.id).to eq(support_endpoint.id)
      expect(incoming.body.text).to eq("hi there")
      expect(incoming.author.native_id).to eq("u1")
      expect(incoming.author.display_name).to eq("Remote Ada")
    end

    it "carries attachments and a reply_to onto the canonical message" do
      events.enqueue_message(account: "acme", channel_id: "support-42", body: "see this",
                             author: { native_id: "u1" }, reply_to: "17",
                             attachments: [{ url: "https://example.invalid/cat.png", kind: "photo" }])

      adapter.receive_pending

      incoming = dispatcher.last
      expect(incoming.reply_to).to eq(Rubotty::Core::MessageRef.new(support_endpoint.id, "17"))
      expect(incoming.attachments.first.url).to eq("https://example.invalid/cat.png")
      expect(incoming.attachments.first.kind).to eq(:photo)
    end

    it "emits an edit as an :edit message naming the earlier message_id" do
      events.enqueue_edit(account: "acme", channel_id: "support-42", target_native_id: "42",
                          body: "corrected", author: { native_id: "u1" })

      adapter.receive_pending

      incoming = dispatcher.last
      expect(incoming.kind).to eq(:edit)
      expect(incoming.ref).to eq(Rubotty::Core::MessageRef.new(support_endpoint.id, "42"))
      expect(incoming.body.text).to eq("corrected")
    end

    it "emits a delete as a :delete message" do
      events.enqueue_delete(account: "acme", channel_id: "support-42", target_native_id: "42",
                            author: { native_id: "u1" })

      adapter.receive_pending

      expect(dispatcher.last.kind).to eq(:delete)
    end

    it "emits a reaction add and remove with the reaction attached" do
      events.enqueue_reaction_add(account: "acme", channel_id: "support-42", target_native_id: "42",
                                  author: { native_id: "u1" }, reaction: { emoji: "\u{1F44D}" })
      events.enqueue_reaction_remove(account: "acme", channel_id: "support-42", target_native_id: "42",
                                     author: { native_id: "u1" }, reaction: { emoji: "\u{1F44D}" })

      adapter.receive_pending

      expect(dispatcher.messages.map(&:kind)).to eq(%i[reaction_add reaction_remove])
      expect(dispatcher.messages.map { |m| m.reaction.emoji }).to eq(["\u{1F44D}", "\u{1F44D}"])
    end

    # A game server's stream is mostly people arriving and going, and a room
    # that renders those as somebody talking cannot tell the two apart.
    it "emits a join and a leave as membership messages, not as chat" do
      events.enqueue_join(account: "acme", channel_id: "support-42",
                          author: { native_id: "u1", display_name: "Remote Ada" })
      events.enqueue_leave(account: "acme", channel_id: "support-42",
                           author: { native_id: "u2", display_name: "Remote Bo" })

      adapter.receive_pending

      expect(dispatcher.messages.map(&:kind)).to eq(%i[join leave])
      expect(dispatcher.messages.map { |m| m.author.native_id }).to eq(%w[u1 u2])
      expect(dispatcher.messages.map { |m| m.author.display_name }).to eq(["Remote Ada", "Remote Bo"])
    end

    it "gives a membership message the endpoint it arrived on and an empty body" do
      events.enqueue_join(account: "acme", channel_id: "support-42", author: { native_id: "u1" })

      adapter.receive_pending

      expect(dispatcher.last.origin.id).to eq(support_endpoint.id)
      expect(dispatcher.last.body.text).to eq("")
      expect(dispatcher.last.ref.endpoint_id).to eq(support_endpoint.id)
    end

    it "takes a row as it emits, so a second pass never relays it twice" do
      events.enqueue_message(account: "acme", channel_id: "support-42", body: "once",
                             author: { native_id: "u1" })

      adapter.receive_pending
      adapter.receive_pending

      expect(dispatcher.messages.size).to eq(1)
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end

    it "only drains its own account's rows, never another account sharing the table" do
      events.enqueue_message(account: "someone-else", channel_id: "other-channel", body: "not ours",
                             author: { native_id: "u1" })

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_wrapper_pending_event.count).to eq(1)
    end

    it "leaves a row queued when its channel_id has no endpoint yet" do
      events.enqueue_message(account: "acme", channel_id: "not-mapped-yet", body: "waiting",
                             author: { native_id: "u1" })

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_wrapper_pending_event.count).to eq(1)
    end

    it "drops a row once it has waited past the maximum" do
      row = events.enqueue_message(account: "acme", channel_id: "support-42", body: "too old",
                                   author: { native_id: "u1" })
      row.update(created_at: Time.now - (Rubotty::ControlPlane::ApiWrapperEvents::MAX_WAIT_SECONDS + 1))

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_wrapper_pending_event[row.id]).to be_nil
    end

    it "does not raise when a pass fails, so the receive loop survives it" do
      allow(events).to receive(:pending).and_raise(Sequel::DatabaseError, "boom")

      expect { adapter.receive_pending }.not_to raise_error
    end
  end

  describe "#start and #stop" do
    it "drains once on start and is safe to stop twice" do
      events.enqueue_message(account: "acme", channel_id: "support-42", body: "drained at start",
                             author: { native_id: "u1" })

      adapter.start
      expect(dispatcher.messages.map { |m| m.body.text }).to eq(["drained at start"])

      adapter.stop
      expect { adapter.stop }.not_to raise_error
      expect(adapter.running?).to be(false)
    end

    it "joins the poll thread rather than killing it, so an event already claimed still reaches the dispatcher" do
      stub_const("#{described_class}::POLL_INTERVAL", 0.02)
      claimed = Queue.new
      release = Queue.new
      allow(events).to receive(:retire).and_wrap_original do |original, row|
        original.call(row)
        claimed << :claimed
        release.pop
      end

      adapter.start
      events.enqueue_message(account: "acme", channel_id: "support-42", body: "in flight",
                             author: { native_id: "u1" })
      claimed.pop # the poll thread has claimed the row and is now stuck before emit

      stopper = Thread.new { adapter.stop }
      sleep 0.05 # give the old kill-first behaviour a chance to land before we let it proceed
      release << :go
      stopper.join

      expect(dispatcher.messages.map { |m| m.body.text }).to eq(["in flight"])
      expect(adapter.running?).to be(false)
    end
  end
end
