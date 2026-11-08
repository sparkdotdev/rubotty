# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Relay recovery regressions" do
  class RelayRecoveryIrcSocket
    def initialize
      @input = Queue.new
      @output = Queue.new
    end
    def write(data) = (@output << data)
    def gets = @input.pop
    def feed(data) = (@input << "#{data}\r\n")
    def next_write(timeout: 1) = @output.pop(timeout: timeout)
    def close = nil
  end

  let(:log) { Rubotty::Log.null }

  def database
    @database ||= Sequel.sqlite.tap { |db| Rubotty::ControlPlane.migrate!(db) }
  end

  it "leaves an active job with its holder during overlapping boot recovery" do
    store = Rubotty::Core::DurableSchedulerStore::Sequel.new(db: database)
    now = Time.now
    old = Rubotty::Core::DurableScheduler.new(store: store, session_id: "old-live", logger: log)
    fresh = Rubotty::Core::DurableScheduler.new(store: store, session_id: "new-live", logger: log)
    entered = Queue.new
    release = Queue.new
    effects = Queue.new
    old.register("send") { |job| effects << ["old", job.id]; entered << :ready; release.pop(timeout: 3) }
    fresh.register("send") { |job| effects << ["new", job.id] }
    id = old.schedule(kind: "send", run_at: now)
    runner = Thread.new { old.run_due(now: now) }
    expect(entered.pop(timeout: 3)).to eq(:ready)
    expect(store.find(id).claimed_by).to eq("old-live")
    fresh.recover(now: now)
    expect(effects.size).to eq(1)
    expect(store.find(id).status).to eq("claimed")
  ensure
    release << :go if release
    runner&.join(3)
  end

  it "reopens the automated-traffic breaker after its cooldown" do
    now = Time.now
    guard = Rubotty::Core::LoopGuard.new(clock: -> { now })
    expect(20.times.map { guard.check_post_rate("synthetic-room") }).to all(be_nil)
    expect(guard.check_post_rate("synthetic-room")).to eq(:tripped)
    now += 86_400
    expect(guard.check_post_rate("synthetic-room")).to be_nil
  end

  it "makes a failed chat eligible for replay after adapter recovery" do
    a, b = endpoint("a"), endpoint("b")
    storage = Rubotty::Storage::Memory.new
    adapter = Fakes::RecordingAdapter.new
    bridge = Rubotty::Features::Bridge.new(
      topology: topology(room("r", a, b)), adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new, logger: log,
      retry_policy: Rubotty::Core::RetryPolicy.new(attempts: 1, sleeper: ->(_) {})
    )
    original = message(a, text: "synthetic outage test")
    adapter.fail_next(Rubotty::AdapterError.new("temporary outage", adapter: :fake, retryable: true))
    bridge.call(Rubotty::Features::Context.new(message: original))
    expect(adapter.delivered).to eq([])
    expect(storage.relay_claimed?(source: original.ref, operation: "new", community: nil)).to be(false)
    bridge.call(Rubotty::Features::Context.new(message: original))
    expect(adapter.delivered.size).to eq(1)
  end

  it "keeps colliding album and single-message ids isolated by chat" do
    a = endpoint("tg-a", adapter: :telegram, settings: { chat_id: "-100111" })
    b = endpoint("tg-b", adapter: :telegram, settings: { chat_id: "-100222" })
    http = Fakes::TelegramHttp.new
    http.on("sendMediaGroup", [
      { "message_id" => 100, "chat" => { "id" => "-100111" } },
      { "message_id" => 101, "chat" => { "id" => "-100111" } }
    ])
    adapter = Rubotty::Adapters::Telegram::Adapter.new(account: "synthetic", settings: { token: "synthetic" },
      dispatcher: nil, logger: log, endpoints: [a, b])
    adapter.replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "synthetic", http: http))
    adapter.deliver(message(a, attachments: [photo_attachment, photo_attachment(url: "https://cdn.example/b.jpg")]), a)
    adapter.delete(b, "100")
    expect(http.calls("deleteMessage").map(&:params)).to eq([
      { "chat_id" => "-100222", "message_id" => 100 }
    ])
  end

  it "deletes a Telegram album after rebuilding the adapter from shared durable state" do
    target = endpoint("tg", adapter: :telegram, settings: { chat_id: "-100111" })
    storage = Rubotty::Storage::Memory.new
    http = Fakes::TelegramHttp.new.on("sendMediaGroup", [
      { "message_id" => 100, "chat" => { "id" => "-100111" } },
      { "message_id" => 101, "chat" => { "id" => "-100111" } }
    ])
    build = lambda do
      adapter = Rubotty::Adapters::Telegram::Adapter.new(account: "synthetic", settings: { token: "synthetic" },
        dispatcher: nil, logger: log, endpoints: [target])
      adapter.storage = storage
      adapter.delivery_state_ttl = 3600
      adapter.replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "synthetic", http: http))
    end
    receipt = build.call.deliver(message(target, attachments: [photo_attachment, photo_attachment]), target)
    build.call.delete(target, receipt.native_id)
    expect(http.calls("deleteMessage").map { |call| call.params["message_id"] }).to eq([100, 101])
  end

  it "replays only missing destinations after partial fan-out failure" do
    a, b, c = %w[a b c].map { |id| endpoint(id) }
    adapter = Fakes::RecordingAdapter.new
    original = adapter.method(:deliver)
    failure = true
    adapter.define_singleton_method(:deliver) do |msg, target|
      if target.id == "b" && failure
        failure = false
        raise Rubotty::AdapterError.new("temporary", adapter: :fake, retryable: true)
      end
      original.call(msg, target)
    end
    bridge = Rubotty::Features::Bridge.new(topology: topology(room("r", a, b, c)),
      adapters: Hash.new(adapter), storage: Rubotty::Storage::Memory.new,
      loop_guard: Rubotty::Core::LoopGuard.new, logger: log,
      retry_policy: Rubotty::Core::RetryPolicy.new(attempts: 1))
    msg = message(a)
    2.times { bridge.call(Rubotty::Features::Context.new(message: msg)) }
    expect(adapter.delivered.map(&:first)).to contain_exactly("b", "c")
  end

  it "expires an abandoned source lease and replays only missing destinations" do
    a, b, c = %w[a b c].map { |id| endpoint(id) }
    storage = Rubotty::Storage::Memory.new
    now = Time.now
    leases = Rubotty::Core::RelayLeases.new(storage: storage, clock: -> { now }, lease: 300)
    msg = message(a)
    storage.record(source: msg.ref, destination: ref("b", "9"), room_id: "r")
    abandoned = leases.claim(msg.ref, nil)
    expect(abandoned).not_to be_nil
    adapter = Fakes::RecordingAdapter.new
    bridge = Rubotty::Features::Bridge.new(topology: topology(room("r", a, b, c)),
      adapters: Hash.new(adapter), storage: storage, relay_leases: leases,
      loop_guard: Rubotty::Core::LoopGuard.new, logger: log)
    bridge.call(Rubotty::Features::Context.new(message: msg))
    expect(adapter.delivered).to be_empty
    expect(storage.relay_claimed?(source: msg.ref, operation: "new", community: nil)).to be(false)
    now += 301
    bridge.call(Rubotty::Features::Context.new(message: msg))
    expect(adapter.delivered.map(&:first)).to eq(["c"])
    expect(storage.relay_claimed?(source: msg.ref, operation: "new", community: nil)).to be(true)
  end

  it "fences an expired source owner from completing or releasing its replacement" do
    storage = Rubotty::Storage::Memory.new
    now = Time.now
    leases = Rubotty::Core::RelayLeases.new(storage: storage, clock: -> { now }, lease: 300)
    source = ref("source", "1")
    old = leases.claim(source, nil)
    now += 301
    replacement = leases.claim(source, nil)
    leases.finish(old, source: source, community: nil, completed: true, claim_ttl: 3600)
    expect(storage.relay_claimed?(source: source, operation: "new", community: nil)).to be(false)
    expect(leases.claim(source, nil)).to be_nil
    leases.finish(replacement, source: source, community: nil, completed: true, claim_ttl: 3600)
    expect(storage.relay_claimed?(source: source, operation: "new", community: nil)).to be(true)
  end

  it "refreshes a source lease while a long delivery is still running" do
    storage = Rubotty::Storage::Memory.new
    writes = Queue.new
    allow(storage).to receive(:put_state).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      writes << :written
      result
    end
    leases = Rubotty::Core::RelayLeases.new(storage: storage, lease: 0.6)
    source = ref("source", "1")
    owned = leases.claim(source, nil)
    writes.pop
    refresher = leases.start_refresh(owned)
    3.times { expect(writes.pop(timeout: 2)).to eq(:written) }
    expect(leases.claim(source, nil)).to be_nil
  ensure
    leases&.stop_refresh(refresher)
  end

  it "retries failed native deletions through a durable job after reconstruction" do
    a, b = endpoint("a", community_id: 7), endpoint("b", community_id: 7)
    storage = Rubotty::Storage::Memory.new
    storage.record(source: ref("a", "1"), destination: ref("b", "9"), room_id: "r")
    jobs = Rubotty::Core::DurableSchedulerStore::Sequel.new(db: database)
    scheduler = Rubotty::Core::DurableScheduler.new(store: jobs, session_id: "synthetic")
    adapter = Fakes::RecordingAdapter.new
    allow(adapter).to receive(:delete).and_raise(Rubotty::AdapterError.new("temporary", adapter: :fake, retryable: true))
    build = lambda do
      Rubotty::Features::Bridge.new(topology: topology(room("r", a, b, community_id: 7)), storage: storage,
        adapters: Hash.new(adapter), loop_guard: Rubotty::Core::LoopGuard.new, logger: log,
        retry_policy: Rubotty::Core::RetryPolicy.new(attempts: 1), durable_scheduler: scheduler)
    end
    community = Struct.new(:id).new(7)
    build.call.call(Rubotty::Features::Context.new(message: message(a, kind: :delete), community: community))
    expect(scheduler.pending(kind: Rubotty::Features::Bridge::DELETE_RETRY_KIND)).to eq(1)
    allow(adapter).to receive(:delete).and_call_original
    build.call
    expect(scheduler.run_due(now: Time.now + 11)).to eq(1)
    expect(adapter.deleted.map { |row| row[1] }).to eq(["9"])
    expect(storage.counterparts(ref("a", "1"))).to be_empty
    expect(jobs.find(database[:scheduled_jobs].first[:id]).payload).to eq({})
  end

  it "preserves a burst of distinct human messages above the automated loop ceiling" do
    a, b = endpoint("a"), endpoint("b")
    adapter = Fakes::RecordingAdapter.new
    bridge = Rubotty::Features::Bridge.new(topology: topology(room("r", a, b)),
      adapters: Hash.new(adapter), storage: Rubotty::Storage::Memory.new,
      loop_guard: Rubotty::Core::LoopGuard.new, logger: log)
    25.times do |id|
      bridge.call(Rubotty::Features::Context.new(message: message(a, native_id: id.to_s, text: "message #{id}")))
    end
    expect(adapter.delivered.size).to eq(25)
  end

  it "renegotiates CAP END when an IRC client reconnects" do
    client = Rubotty::Adapters::Irc::Client.new(server: "irc.example.org", nick: "test", logger: log)
    first, second = RelayRecoveryIrcSocket.new, RelayRecoveryIrcSocket.new
    allow(client).to receive(:open_socket).and_return(first, second)
    start = Thread.new { client.connect(ready_timeout: 1) }
    3.times { expect(first.next_write).not_to be_nil }
    first.feed(":server CAP * LS :message-tags")
    expect(first.next_write).to eq("CAP REQ :message-tags\r\n")
    first.feed(":server CAP test ACK :message-tags")
    expect(first.next_write).to eq("CAP END\r\n")
    first.feed(":server 001 test :Welcome")
    expect(start.value).to eq(client)
    client.close
    restarted = Thread.new do
      begin
        client.connect(ready_timeout: 0.25)
      rescue Rubotty::AdapterError => e
        e
      end
    end
    3.times { expect(second.next_write).not_to be_nil }
    second.feed(":server CAP * LS :message-tags")
    expect(second.next_write).to eq("CAP REQ :message-tags\r\n")
    second.feed(":server CAP test ACK :message-tags")
    expect(second.next_write).to eq("CAP END\r\n")
    second.feed(":server 001 test :Welcome")
    expect(restarted.value).to eq(client)
  ensure
    client&.close
    start&.kill
    restarted&.kill
  end

  it "orders messages sharing a room when one origin also belongs to another room" do
    a, b, c, x = %w[a b c x].map { |id| endpoint(id) }
    layout = topology(room("r1", a, x), room("r2", a, b, c))
    entered, release, seen_c = Queue.new, Queue.new, Queue.new
    adapter = Fakes::RecordingAdapter.new
    original_deliver = adapter.method(:deliver)
    adapter.define_singleton_method(:deliver) do |msg, target|
      if target.id == "x"
        entered << :blocked
        release.pop(timeout: 3)
      end
      seen_c << msg.body.text if target.id == "c"
      original_deliver.call(msg, target)
    end
    bridge = Rubotty::Features::Bridge.new(topology: layout, adapters: Hash.new(adapter),
      storage: Rubotty::Storage::Memory.new, loop_guard: Rubotty::Core::LoopGuard.new, logger: log)
    handler = Object.new
    handler.define_singleton_method(:handle) { |msg| bridge.call(Rubotty::Features::Context.new(message: msg)) }
    dispatcher = Rubotty::Core::Dispatcher.new(topology: layout, router: handler, logger: log).start
    dispatcher.call(message(a, native_id: "1", text: "first"))
    expect(entered.pop(timeout: 3)).to eq(:blocked)
    dispatcher.call(message(b, native_id: "2", text: "second"))
    expect(seen_c.pop(timeout: 0.05)).to be_nil
    release << :go
    expect(dispatcher.drain(timeout: 3)).to be(true)
    expect(seen_c.pop(timeout: 3)).to eq("first")
    expect(seen_c.pop(timeout: 3)).to eq("second")
  ensure
    release << :go if release
    dispatcher&.stop
  end

  it "retains failed deletion mappings and permits another attempt" do
    a, b = endpoint("a"), endpoint("b")
    storage = Rubotty::Storage::Memory.new
    storage.record(source: ref("a", "1"), destination: ref("b", "9"), room_id: "r")
    adapter = Fakes::RecordingAdapter.new
    allow(adapter).to receive(:delete).and_raise(Rubotty::AdapterError.new("transient", adapter: :fake, retryable: true))
    bridge = Rubotty::Features::Bridge.new(topology: topology(room("r", a, b)), adapters: Hash.new(adapter),
      storage: storage, loop_guard: Rubotty::Core::LoopGuard.new, logger: log,
      retry_policy: Rubotty::Core::RetryPolicy.new(attempts: 1))
    bridge.call(Rubotty::Features::Context.new(message: message(a, native_id: "1", kind: :delete)))
    expect(storage.counterparts(ref("a", "1"))).to eq([ref("b", "9")])
    expect(storage.relay_claimed?(source: ref("a", "1"), operation: "delete", community: nil)).to be(false)
    expect(adapter).to have_received(:delete).once
  end

  it "rejects IRC delivery while its socket is absent" do
    target = endpoint("irc", adapter: :irc, settings: { channel: "#synthetic" })
    adapter = Rubotty::Adapters::Irc::Adapter.new(account: "synthetic",
      settings: { server: "irc.example.org", nick: "test" }, dispatcher: nil, logger: log, endpoints: [target])
    adapter.stop
    expect(adapter.running?).to be(false)
    expect { adapter.deliver(message(target, text: "lost during reconnect"), target) }
      .to raise_error(Rubotty::AdapterError, /disconnected/)
  end

  it "redacts every Matrix event created for a logical message" do
    target = endpoint("mx", adapter: :matrix, settings: { room_id: "!room:example.org" })
    client = MatrixFakes::Client.new
    adapter = Rubotty::Adapters::Matrix::Adapter.new(account: "synthetic",
      settings: { token: "synthetic", homeserver: "https://example.org" },
      dispatcher: nil, logger: log, endpoints: [target]).replace_client(client)
    allow(adapter).to receive(:upload_attachment) do |file|
      { "msgtype" => "m.image", "body" => file.filename, "url" => "mxc://example.org/synthetic" }
    end
    receipt = adapter.deliver(message(target, text: "two photos",
      attachments: [photo_attachment, photo_attachment(url: "https://cdn.example/b.jpg")]), target)
    expect(client.sent_events.size).to eq(3)
    adapter.delete(target, receipt.native_id)
    expect(client.redactions.map { |row| row[:event] }).to eq(%w[$event-1 $event-2 $event-3])
  end

  it "retires workers for removed topology rooms" do
    origin = endpoint("source")
    live = Struct.new(:rooms).new([])
    live.define_singleton_method(:rooms_for) { |id| rooms.select { |r| r.include?(id) } }
    handler = Object.new
    handler.define_singleton_method(:handle) { |_| nil }
    dispatcher = Rubotty::Core::Dispatcher.new(topology: live, router: handler, logger: log).start
    20.times do |index|
      live.rooms = [room("temporary-#{index}", origin)]
      dispatcher.call(message(origin, native_id: index.to_s))
      expect(dispatcher.drain(timeout: 3)).to be(true)
    end
    expect(live.rooms.size).to eq(1)
    workers = dispatcher.instance_variable_get(:@threads)
    expect(workers.size).to eq(1)
    expect(workers.values).to all(be_alive)
  ensure
    dispatcher&.stop
  end

  it "fences an expired claim from settling the new holder" do
    store = Rubotty::Core::DurableSchedulerStore::Sequel.new(db: database)
    now = Time.now
    settlements = {
      complete: {}, reschedule: { run_at: now + 400 },
      retry_later: { run_at: now + 400, attempts: 1 }, mark_failed: { attempts: 1 }
    }
    settlements.each do |operation, arguments|
      id = store.enqueue(kind: "synthetic", run_at: now)
      old_claim = store.claim_next(now: now, session_id: "same-session")
      expect(old_claim.id).to eq(id)
      store.reclaim_stale(now: now + 301, lease: 300)
      replacement = store.claim_next(now: now + 301, session_id: "same-session")
      expect(replacement.id).to eq(id)
      store.public_send(operation, id, **arguments, claim_token: old_claim.claim_token)
      expect(store.find(id).status).to eq("claimed")
      expect(store.find(id).claim_token).to eq(replacement.claim_token)
      expect(store.touch_claim(id, session_id: "same-session", now: now + 302,
                                  claim_token: old_claim.claim_token)).to eq(0)
      store.complete(id, claim_token: replacement.claim_token)
    end
  end
end

RSpec.describe "Native source identity preservation", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }
  let(:snapshot) { registry.current }
  let(:ledger) { Rubotty::ControlPlane::RelayFingerprints.new(models: models) }
  let(:adapter) { Fakes::RecordingAdapter.new }
  let(:route) do
    Rubotty::Core::Router.new(topology: snapshot.topology, adapters: Hash.new(adapter),
      storage: Rubotty::Storage::Memory.new, loop_guard: Rubotty::Core::LoopGuard.new,
      logger: Rubotty::Log.null, registry: registry, relay_fingerprints: ledger)
  end

  it "preserves case-sensitive separate messages with different files" do
    origin = snapshot.topology.endpoints.find { |e| e.id == "tg-general" }
    time = Time.at((Time.now.to_i / 60) * 60 + 1)
    route.handle(message(origin, native_id: "1", text: "synthetic caption", timestamp: time,
      attachments: [photo_attachment(url: "https://cdn.example/a.jpg")]))
    route.handle(message(origin, native_id: "2", text: "SYNTHETIC caption", timestamp: time + 1,
      attachments: [photo_attachment(url: "https://cdn.example/b.jpg")]))
    copies = adapter.delivered_to("dc-general")
    expect(copies.size).to eq(2)
    expect(copies.flat_map(&:attachments).map(&:url)).to eq(["https://cdn.example/a.jpg", "https://cdn.example/b.jpg"])
  end
end
