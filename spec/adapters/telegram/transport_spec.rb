# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A minimal stand in for the state KV: offset persistence needs only get and put.
class FakeStateStore
  def initialize(seed = {})
    @state = seed.dup
  end

  def get_state(key) = @state[key.to_s]

  def put_state(key, value, expires_at: nil)
    @state[key.to_s] = value
    nil
  end
end

# Both transports are driven through the same contract and must produce
# identical canonical messages.
RSpec.describe "Telegram transports" do
  let(:http) { Fakes::TelegramHttp.new }
  let(:client) { Rubotty::Adapters::Telegram::ApiClient.new(token: "t", http: http) }
  let(:received) { [] }
  let(:on_update) { ->(update) { received << update } }

  def sample(update_id)
    { "update_id" => update_id, "message" => { "message_id" => update_id, "text" => "hi" } }
  end

  describe Rubotty::Adapters::Telegram::Transport::LongPolling do
    subject(:transport) do
      described_class.new(client: client, logger: Rubotty::Log.null, on_update: on_update,
                          settings: { poll_timeout: 0, skip_backlog: false })
    end

    # Telegram refuses getUpdates while a webhook is registered, so a leftover
    # one from a previous run silently starves the poller.
    it "clears any leftover webhook before polling" do
      http.on("deleteWebhook", true).default_result([])
      transport.start
      sleep 0.05
      transport.stop
      expect(http.called?("deleteWebhook")).to be(true)
    end

    it "delivers updates it receives" do
      http.on("deleteWebhook", true).on("getUpdates", [sample(1), sample(2)]).default_result([])
      transport.start
      sleep 0.1
      transport.stop
      expect(received.map { |u| u["update_id"] }).to start_with([1, 2])
    end

    # Both transports ask for the same list, so a poll button that works over a
    # webhook has to work here too.
    it "asks for callback_query, without which no poll button press ever arrives" do
      http.on("deleteWebhook", true).on("getUpdates", []).default_result([])
      transport.start
      sleep 0.1
      transport.stop
      expect(http.last("getUpdates").params["allowed_updates"]).to include("callback_query")
    end

    it "advances the offset so Telegram does not redeliver" do
      http.on("deleteWebhook", true).on("getUpdates", [sample(7)]).default_result([])
      transport.start
      sleep 0.1
      transport.stop
      second = http.calls("getUpdates")[1]
      expect(second.params["offset"]).to eq(8)
    end

    it "skips the backlog when asked to" do
      skipping = described_class.new(
        client: client, logger: Rubotty::Log.null, on_update: on_update,
        settings: { poll_timeout: 0, skip_backlog: true }
      )
      http.on("deleteWebhook", true).on("getUpdates", [sample(40)]).default_result([])
      skipping.start
      sleep 0.1
      skipping.stop
      # The backlog probe consumed update 40 without relaying it.
      expect(received.map { |u| u["update_id"] }).not_to include(40)
      expect(http.calls("getUpdates").first.params["offset"]).to eq(-1)
    end

    it "keeps going after a transient failure instead of exiting" do
      http.on("deleteWebhook", true)
      http.error_on("getUpdates", code: 502, description: "Bad Gateway")
      http.on("getUpdates", [sample(3)]).default_result([])
      transport.start
      sleep 1.5
      transport.stop
      expect(received.map { |u| u["update_id"] }).to include(3)
    end

    # Telegram queues unacknowledged updates for about 24h, so a persisted offset
    # lets a restart replay the gap that opened while the bridge was down.
    describe "durable offset" do
      let(:key) { "telegram:getUpdates:offset:tg" }

      def polling(store, **overrides)
        described_class.new(
          client: client, logger: Rubotty::Log.null, on_update: on_update,
          storage: store, account: "tg",
          settings: { poll_timeout: 0, skip_backlog: true }.merge(overrides)
        )
      end

      it "reseeds the offset from the persisted value on boot, over skip-to-now" do
        store = FakeStateStore.new(key => JSON.generate("offset" => 500, "saved_at" => Time.now.to_i))
        http.on("deleteWebhook", true).default_result([])
        transport = polling(store)
        transport.start
        sleep 0.1
        transport.stop
        # Resumed at the persisted cursor rather than probing -1 to skip the backlog.
        expect(http.calls("getUpdates").first.params["offset"]).to eq(500)
      end

      it "persists the offset as it advances so the next boot resumes here" do
        store = FakeStateStore.new
        http.on("deleteWebhook", true).on("getUpdates", [sample(7)]).default_result([])
        transport = polling(store, skip_backlog: false)
        transport.start
        sleep 0.1
        transport.stop
        expect(JSON.parse(store.get_state(key))["offset"]).to eq(8)
      end

      it "discards a persisted offset older than the retention window and skips to now" do
        stale = Time.now.to_i - (25 * 60 * 60)
        store = FakeStateStore.new(key => JSON.generate("offset" => 500, "saved_at" => stale))
        http.on("deleteWebhook", true).on("getUpdates", [sample(40)]).default_result([])
        transport = polling(store)
        transport.start
        sleep 0.1
        transport.stop
        # Fell back to the skip-to-now probe rather than replaying a stale day.
        expect(http.calls("getUpdates").first.params["offset"]).to eq(-1)
        expect(received.map { |u| u["update_id"] }).not_to include(40)
      end

      it "is a no-op without a durable store, resuming exactly as before" do
        nostore = described_class.new(
          client: client, logger: Rubotty::Log.null, on_update: on_update,
          settings: { poll_timeout: 0, skip_backlog: false }
        )
        http.on("deleteWebhook", true).on("getUpdates", [sample(9)]).default_result([])
        nostore.start
        sleep 0.1
        nostore.stop
        # No store to read a persisted offset from, so it starts from nil.
        expect(http.calls("getUpdates").first.params["offset"]).to be_nil
        expect(received.map { |u| u["update_id"] }).to include(9)
      end
    end

    # Telegram serves only one getUpdates long poll per bot and 409s the other,
    # so Storage::Memory stands in here for its real #with_advisory_lock.
    describe "the poll lock" do
      def locked_polling(store, client_for: client, **overrides)
        described_class.new(
          client: client_for, logger: Rubotty::Log.null, on_update: on_update,
          storage: store, account: "tg",
          settings: { poll_timeout: 0, skip_backlog: false }.merge(overrides)
        )
      end

      it "takes the poll lock, named for the account, around each getUpdates round trip" do
        storage = Rubotty::Storage::Memory.new
        names = []
        allow(storage).to receive(:with_advisory_lock).and_wrap_original do |original, name, **kwargs, &block|
          names << name
          original.call(name, **kwargs, &block)
        end
        http.on("deleteWebhook", true).on("getUpdates", []).default_result([])

        transport = locked_polling(storage)
        transport.start
        sleep 0.1
        transport.stop

        expect(names).to include("telegram:getUpdates:poll:tg")
      end

      # A second instance that cannot take the lock never calls getUpdates, so it
      # cannot trip Telegram's own 409.
      it "stands by, without calling getUpdates or erroring, when another instance already holds the poll lock" do
        storage = instance_double(Rubotty::Storage::Memory)
        allow(storage).to receive(:with_advisory_lock).and_raise(Rubotty::LockUnavailable, "busy")
        http.on("deleteWebhook", true)

        transport = locked_polling(storage)
        transport.start
        sleep 0.1
        transport.stop

        expect(http.called?("getUpdates")).to be(false)
        expect(received).to be_empty
      end

      # Two pollers over one lockable store stand in for two processes polling
      # the same bot.
      it "never lets two poller instances be mid-poll at once over a shared store" do
        storage = Rubotty::Storage::Memory.new
        entered = Queue.new
        release = Queue.new
        active = 0
        max_active = 0
        guard = Mutex.new

        slow_client = instance_double(Rubotty::Adapters::Telegram::ApiClient)
        allow(slow_client).to receive(:call) do |method, *|
          next true unless method == "getUpdates"

          guard.synchronize { active += 1; max_active = [max_active, active].max }
          entered << :in
          release.pop
          guard.synchronize { active -= 1 }
          []
        end

        quick_client = instance_double(Rubotty::Adapters::Telegram::ApiClient)
        allow(quick_client).to receive(:call) do |method, *|
          next true unless method == "getUpdates"

          guard.synchronize { active += 1; max_active = [max_active, active].max }
          guard.synchronize { active -= 1 }
          []
        end

        a = locked_polling(storage, client_for: slow_client)
        b = locked_polling(storage, client_for: quick_client)

        thread = Thread.new { a.send(:poll_once) }
        entered.pop # a is now mid-poll, holding the lock

        releaser = Thread.new { sleep 0.1; release << :go }
        # Contends for the same poll lock a is holding, so it has to wait.
        b.send(:poll_once)
        thread.join
        releaser.join

        expect(max_active).to eq(1)
      end
    end
  end

  describe Rubotty::Adapters::Telegram::Transport::Webhook do
    subject(:transport) do
      described_class.new(
        client: client, logger: Rubotty::Log.null, on_update: on_update,
        settings: { webhook_url: "https://bridge.example.com/telegram/webhook",
                    webhook_secret: "s3cret", webhook_port: 0 }
      )
    end

    it "refuses to start without a public URL" do
      naked = described_class.new(client: client, logger: Rubotty::Log.null,
                                  on_update: on_update, settings: { webhook_port: 0 })
      expect { naked.start }.to raise_error(Rubotty::ConfigError, /webhook_url/)
      naked.stop
    end

    it "registers the webhook with a secret token" do
      http.on("setWebhook", true)
      transport.start
      call = http.last("setWebhook")
      expect(call.params["url"]).to eq("https://bridge.example.com/telegram/webhook")
      expect(call.params["secret_token"]).to eq("s3cret")
      transport.stop
    end

    it "removes the webhook on shutdown so Telegram stops posting into a void" do
      http.on("setWebhook", true).on("deleteWebhook", true)
      transport.start
      transport.stop
      expect(http.called?("deleteWebhook")).to be(true)
    end

    it "delivers a posted update" do
      transport.send(:instance_variable_set, :@secret, "s3cret")
      transport.handle_body(JSON.generate(sample(11)))
      expect(received.map { |u| u["update_id"] }).to eq([11])
    end

    it "discards a malformed body without crashing the server" do
      expect(transport.handle_body("not json")).to be(false)
      expect(received).to be_empty
    end

    it "asks Telegram only for the update types the bridge handles" do
      http.on("setWebhook", true)
      transport.start
      expect(http.last("setWebhook").params["allowed_updates"])
        .to contain_exactly("message", "edited_message", "channel_post", "edited_channel_post",
                            "message_reaction", "message_reaction_count", "my_chat_member",
                            "callback_query")
      transport.stop
    end

    it "opts in to callback_query, without which no poll button press ever arrives" do
      # It is in Telegram's default set, and naming any list at all replaces
      # that set, so leaving it out here would switch the vote buttons off.
      http.on("setWebhook", true)
      transport.start
      expect(http.last("setWebhook").params["allowed_updates"]).to include("callback_query")
      transport.stop
    end

    it "opts in to message_reaction, which Telegram excludes from its defaults" do
      # Without this, reactions never reach the bridge at all.
      http.on("setWebhook", true)
      transport.start
      expect(http.last("setWebhook").params["allowed_updates"]).to include("message_reaction")
      transport.stop
    end

    it "opts in to message_reaction_count, the only update an anonymous chat sends" do
      # A channel, or a group past the size threshold, sends this INSTEAD of
      # message_reaction, so without it those chats relay no reaction at all.
      http.on("setWebhook", true)
      transport.start
      expect(http.last("setWebhook").params["allowed_updates"]).to include("message_reaction_count")
      transport.stop
    end

    # Telegram queues undelivered updates the same way for a webhook as for
    # long polling, so a restart should resume rather than discard, same as
    # the durable getUpdates offset above.
    describe "durable backlog handling" do
      let(:key) { "telegram:webhook:registered:tg" }

      def webhook(store, **overrides)
        described_class.new(
          client: client, logger: Rubotty::Log.null, on_update: on_update,
          storage: store, account: "tg",
          settings: { webhook_url: "https://bridge.example.com/telegram/webhook",
                      webhook_secret: "s3cret", webhook_port: 0 }.merge(overrides)
        )
      end

      it "drops the backlog on a first ever registration" do
        store = FakeStateStore.new
        http.on("setWebhook", true)
        transport = webhook(store)
        transport.start
        expect(http.last("setWebhook").params["drop_pending_updates"]).to be(true)
        transport.stop
      end

      it "persists that it registered, so a later restart resumes instead of dropping" do
        store = FakeStateStore.new
        http.on("setWebhook", true).on("deleteWebhook", true)
        first = webhook(store)
        first.start
        first.stop

        http.on("setWebhook", true)
        second = webhook(store)
        second.start
        expect(http.last("setWebhook").params["drop_pending_updates"]).to be(false)
        second.stop
      end

      it "never drops the backlog when skip_backlog is off, registered or not" do
        store = FakeStateStore.new
        http.on("setWebhook", true)
        transport = webhook(store, skip_backlog: false)
        transport.start
        expect(http.last("setWebhook").params["drop_pending_updates"]).to be(false)
        transport.stop
      end

      it "logs how many queued updates it is about to drop" do
        logs = StringIO.new
        store = FakeStateStore.new
        http.on("getWebhookInfo", "pending_update_count" => 12).on("setWebhook", true)
        transport = described_class.new(
          client: client, logger: Rubotty::Log.build(level: "info", io: logs), on_update: on_update,
          storage: store, account: "tg",
          settings: { webhook_url: "https://bridge.example.com/telegram/webhook",
                      webhook_secret: "s3cret", webhook_port: 0 }
        )
        transport.start
        expect(logs.string).to include("12")
        transport.stop
      end

      it "is a no-op without a durable store, dropping on every restart same as before" do
        http.on("setWebhook", true)
        transport = described_class.new(
          client: client, logger: Rubotty::Log.null, on_update: on_update,
          settings: { webhook_url: "https://bridge.example.com/telegram/webhook",
                      webhook_secret: "s3cret", webhook_port: 0 }
        )
        transport.start
        expect(http.last("setWebhook").params["drop_pending_updates"]).to be(true)
        transport.stop
      end
    end

    describe "request authentication" do
      before { transport.send(:instance_variable_set, :@secret, "s3cret") }

      def request(header_value)
        instance_double(WEBrick::HTTPRequest).tap do |req|
          allow(req).to receive(:[]) { |name| name.to_s.downcase == described_class::SECRET_HEADER ? header_value : nil }
        end
      end

      it "accepts a request carrying the shared secret" do
        expect(transport.send(:authentic?, request("s3cret"))).to be(true)
      end

      it "rejects a request with the wrong secret" do
        expect(transport.send(:authentic?, request("guess"))).to be(false)
      end

      # Without this check, anyone who learns the webhook URL can inject
      # arbitrary messages into every bridged room.
      it "rejects a request with no secret at all" do
        expect(transport.send(:authentic?, request(nil))).to be(false)
      end

      it "rejects a secret of the wrong length without leaking timing" do
        expect(transport.send(:authentic?, request("s3cre"))).to be(false)
      end
    end
  end

  describe "equivalence" do
    let(:dispatcher) { Fakes::RecordingDispatcher.new }
    let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100999" }) }

    def adapter_for(transport)
      Rubotty::Adapters::Telegram::Adapter.new(
        account: "tg",
        settings: { token: "t", transport: transport, webhook_url: "https://x.example/w", webhook_port: 0 },
        dispatcher: dispatcher,
        logger: Rubotty::Log.null,
        endpoints: [place]
      ).replace_client(client)
    end

    let(:payload) do
      {
        "update_id" => 1,
        "message" => {
          "message_id" => 5,
          "date" => 1_700_000_000,
          "chat" => { "id" => -100_999 },
          "from" => { "id" => 3, "first_name" => "Ada", "username" => "ada" },
          "text" => "hi"
        }
      }
    end

    it "produces an identical canonical message whichever transport carried it" do
      polled = adapter_for(:long_polling).handle_update(payload)
      hooked = adapter_for(:webhook).handle_update(payload)

      expect(polled.ref).to eq(hooked.ref)
      expect(polled.body.text).to eq(hooked.body.text)
      expect(polled.author.to_h).to eq(hooked.author.to_h)
      expect(polled.origin.id).to eq(hooked.origin.id)
    end
  end
end
