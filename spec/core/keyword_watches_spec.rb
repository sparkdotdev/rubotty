# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Driven against a migrated in-memory control plane, a fake clock and the REAL
# durable scheduler, so a watch that lapses during downtime is exercised rather
# than assumed.
RSpec.describe Rubotty::Core::KeywordWatches::Service do
  CommunityStub = Struct.new(:id, :slug, keyword_init: true)

  let(:db) do
    db = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(db)
    db
  end
  let(:models) { Rubotty::ControlPlane.models(db) }
  let(:store) { Rubotty::Core::KeywordWatchStore::Sequel.new(db: db) }
  let(:sched_store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }

  # Time.new rather than Time.utc: the store hands a DateTime column's WALL-CLOCK
  # DIGITS back tagged with this process's local zone, so a UTC fake clock breaks
  # #notify's cooldown arithmetic.
  let(:base) { Time.new(2026, 7, 26, 12, 0, 0) }
  let(:clock_time) { [base] }
  let(:clock) { -> { clock_time.first } }
  def advance(seconds) = clock_time[0] = clock_time.first + seconds

  # Telegram: the subscriber's home platform, able to both mention and DM them.
  def dm_capable_adapter(own_id: "bot-tg")
    Class.new(Fakes::ReactingAdapter) do
      def initialize(**opts)
        super
        @dms = []
      end

      attr_reader :dms

      def supports_admin_dm? = true

      def send_admin_dm(native_id, text)
        @dms << { native_id: native_id, text: text }
        true
      end
    end.new(own_id: own_id)
  end

  let(:tg) { endpoint("tg", adapter: :telegram, account: "tg") }
  let(:dc) { endpoint("dc", adapter: :discord, account: "dc") }
  let(:tg_adapter) { dm_capable_adapter }
  # Discord: deliver-only, so a fallback always lands back on the subscriber's
  # own Telegram DM.
  let(:dc_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-dc") }
  let(:adapters) { { [:telegram, "tg"] => tg_adapter, [:discord, "dc"] => dc_adapter } }

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: sched_store, session_id: "session-1", clock: clock, logger: Rubotty::Log.null
    )
  end

  let(:identity_directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models, clock: clock) }

  let(:service) do
    described_class.new(
      store: store, scheduler: scheduler, adapters: adapters,
      identity_directory: identity_directory, logger: Rubotty::Log.null, clock: clock
    )
  end

  # The caller wires the expiry handler, so every spec that exercises expiry
  # registers it explicitly.
  before { scheduler.register(Rubotty::Core::KeywordWatches::EXPIRE_KIND) { |job| service.expire(job) } }

  def new_community(slug: "sample")
    stamp = Time.now
    id = db[:communities].insert(slug: slug, name: slug.upcase, status: "active",
                                 settings: "{}", created_at: stamp, updated_at: stamp)
    CommunityStub.new(id: id, slug: slug)
  end

  let(:community) { new_community }
  let(:subscriber) { author(native_id: "u9", username: "watcher") }

  def subscribe(keyword: "aoe3", duration: nil, notify_via: "mention", who: subscriber, origin: tg,
               community: self.community)
    service.subscribe(community: community, subscriber: who, origin: origin, keyword: keyword,
                      duration: duration, notify_via: notify_via)
  end

  # Sequel is pinned to UTC, so a round-tripped `expires_at` comes back as the
  # instant it was written and compares directly.
  def expect_duration(watch, seconds)
    expect(watch.expires_at).to eq(base + seconds)
  end

  describe "#subscribe" do
    it "records a watch with the default duration when none is given" do
      result = subscribe
      expect(result.ok?).to be(true)
      expect(result.watch.keyword).to eq("aoe3")
      expect_duration(result.watch, Rubotty::Core::KeywordWatches::DEFAULT_DURATION)
      expect(result.watch.notify_via).to eq("mention")
    end

    it "honours an explicit duration" do
      result = subscribe(duration: "2h")
      expect_duration(result.watch, 7200)
    end

    it "clamps a duration below the floor up to the minimum" do
      result = subscribe(duration: "10s")
      expect_duration(result.watch, Rubotty::Core::KeywordWatches::MIN_DURATION)
    end

    it "clamps a duration above the ceiling down to the maximum" do
      result = subscribe(duration: "40d") # 40 days, past the 30 day ceiling
      expect_duration(result.watch, Rubotty::Core::KeywordWatches::MAX_DURATION)
    end

    it "records the notify mode, defaulting to mention" do
      result = subscribe(notify_via: "dm")
      expect(result.watch.notify_via).to eq("dm")
    end

    it "refuses an unknown notify mode" do
      result = subscribe(notify_via: "carrier-pigeon")
      expect(result.ok?).to be(false)
      expect(result.error).to include("mention").and include("dm")
    end

    it "refuses a keyword that is too short or too long, with a reason" do
      expect(subscribe(keyword: "a").error).to include("at least")
      expect(subscribe(keyword: "x" * 101).error).to include("under")
    end

    it "refuses a duplicate subscription to the same keyword, case-insensitively" do
      subscribe(keyword: "aoe3")
      result = subscribe(keyword: "AOE3")
      expect(result.ok?).to be(false)
      expect(result.error).to include("already watching")
    end

    it "returns a clear refusal without a resolvable community or subscriber" do
      expect(subscribe(community: nil).ok?).to be(false)
      expect(subscribe(who: nil).ok?).to be(false)
    end
  end

  describe "the per-subscriber cap" do
    it "allows up to the max active watches and refuses the next one, naming the current set" do
      10.times { |n| subscribe(keyword: "kw#{n}") }
      expect(service.list(community: community, subscriber: subscriber, adapter: :telegram).size).to eq(10)

      result = subscribe(keyword: "kw10")
      expect(result.ok?).to be(false)
      expect(result.error).to include("10 active watches")
      expect(result.error).to include("kw0")
    end

    it "frees a slot when a watch is stopped or expires" do
      10.times { |n| subscribe(keyword: "kw#{n}") }
      service.stop(community: community, subscriber: subscriber, adapter: :telegram, keyword: "kw0")
      expect(subscribe(keyword: "kw10").ok?).to be(true)
    end
  end

  describe "#list" do
    it "returns a subscriber's active watches, oldest first" do
      subscribe(keyword: "first")
      subscribe(keyword: "second")
      listed = service.list(community: community, subscriber: subscriber, adapter: :telegram)
      expect(listed.map(&:keyword)).to eq(%w[first second])
    end

    it "is empty for a subscriber with no watches, and without a community" do
      expect(service.list(community: community, subscriber: subscriber, adapter: :telegram)).to be_empty
      expect(service.list(community: nil, subscriber: subscriber, adapter: :telegram)).to be_empty
    end
  end

  describe "#stop" do
    it "ends an active watch and returns true" do
      subscribe(keyword: "aoe3")
      expect(service.stop(community: community, subscriber: subscriber, adapter: :telegram, keyword: "aoe3"))
        .to be(true)
      expect(service.list(community: community, subscriber: subscriber, adapter: :telegram)).to be_empty
    end

    it "returns false for a keyword the subscriber is not watching" do
      expect(service.stop(community: community, subscriber: subscriber, adapter: :telegram, keyword: "nope"))
        .to be(false)
    end

    it "reads a LIKE wildcard as a character, so it cannot end somebody's watch by accident" do
      subscribe(keyword: "aoe3")

      expect(service.stop(community: community, subscriber: subscriber, adapter: :telegram, keyword: "%"))
        .to be(false)
      expect(service.stop(community: community, subscriber: subscriber, adapter: :telegram, keyword: "aoe_"))
        .to be(false)
      expect(service.list(community: community, subscriber: subscriber, adapter: :telegram).size).to eq(1)
    end

    it "still ends a watch whose keyword really does hold a wildcard" do
      subscribe(keyword: "50%")

      expect(service.stop(community: community, subscriber: subscriber, adapter: :telegram, keyword: "50%"))
        .to be(true)
    end

    it "cancels the durable expiry job along with the watch" do
      subscribe(keyword: "aoe3")
      expect(scheduler.pending).to eq(1)
      service.stop(community: community, subscriber: subscriber, adapter: :telegram, keyword: "aoe3")
      expect(scheduler.pending).to eq(0)
    end
  end

  describe "the anti-stalking rule (issue #255)" do
    before do
      identity_directory.record(community_id: community.id, adapter: :discord, native_id: "1", username: "alex")
    end

    it "refuses a keyword that collides with a known identity at subscribe time" do
      result = subscribe(keyword: "alex")
      expect(result.ok?).to be(false)
      expect(result.error).to include("name or handle")
    end

    it "rechecks the SAME rule at notify time: a keyword safe at subscribe time can start colliding later" do
      result = subscribe(keyword: "newbie")
      expect(result.ok?).to be(true)

      # A "newbie" joins after the watch was registered.
      identity_directory.record(community_id: community.id, adapter: :discord, native_id: "2", username: "newbie")

      msg = message(tg, text: "hey newbie welcome", author: author(native_id: "someone-else"))
      sent = service.notify(result.watch, message: msg, origin: tg, community: community)
      expect(sent).to be(false)
      expect(tg_adapter.dms).to be_empty
    end
  end

  describe "#notify" do
    let(:watch) { subscribe(keyword: "aoe3", notify_via: "dm").watch }
    let(:stranger) { author(native_id: "someone-else", username: "stranger") }

    it "never notifies a subscriber of their own message" do
      msg = message(tg, text: "aoe3 anyone?", author: subscriber)
      expect(service.notify(watch, message: msg, origin: tg, community: community)).to be(false)
      expect(tg_adapter.dms).to be_empty
    end

    describe "the cooldown (issue #255: a burst pings once, not five times)" do
      it "suppresses a second notification within the cooldown window, then allows another after it passes" do
        msg = message(tg, text: "aoe3 go", author: stranger)
        expect(service.notify(watch, message: msg, origin: tg, community: community)).to be(true)
        expect(tg_adapter.dms.size).to eq(1)

        expect(service.notify(watch, message: msg, origin: tg, community: community)).to be(false)
        expect(tg_adapter.dms.size).to eq(1)

        advance(Rubotty::Core::KeywordWatches::COOLDOWN_SECONDS + 1)
        expect(service.notify(watch, message: msg, origin: tg, community: community)).to be(true)
        expect(tg_adapter.dms.size).to eq(2)
      end
    end

    describe "delivery, mention vs dm" do
      it "DMs the subscriber on their own platform in dm mode" do
        msg = message(tg, text: "aoe3 go", author: stranger)
        service.notify(watch, message: msg, origin: tg, community: community)
        expect(tg_adapter.dms.first[:native_id]).to eq("u9")
        expect(tg_adapter.dms.first[:text]).to include("aoe3")
      end

      it "pings the subscriber natively in the room the keyword was said, in mention mode" do
        mention_watch = subscribe(keyword: "warcraft", notify_via: "mention").watch
        # Known on discord under the SAME handle, so the mention resolves there.
        identity_directory.record(community_id: community.id, adapter: :discord, native_id: "u9-dc",
                                  username: "watcher")
        msg = message(dc, text: "warcraft tonight?", author: stranger, native_id: "m1")

        sent = service.notify(mention_watch, message: msg, origin: dc, community: community)
        expect(sent).to be(true)
        expect(dc_adapter.delivered_to("dc").size).to eq(1)
        expect(tg_adapter.dms).to be_empty
      end

      it "falls back to a DM on the subscriber's own platform when they cannot be resolved where it was said" do
        mention_watch = subscribe(keyword: "warcraft", notify_via: "mention").watch
        # No identity recorded for "watcher" on discord: unresolvable there.
        msg = message(dc, text: "warcraft tonight?", author: stranger, native_id: "m1")

        sent = service.notify(mention_watch, message: msg, origin: dc, community: community)
        expect(sent).to be(true)
        expect(dc_adapter.delivered_to("dc")).to be_empty
        expect(tg_adapter.dms.size).to eq(1)
      end
    end
  end

  describe "expiry through the durable scheduler" do
    it "schedules an expire_keyword_watch job at the watch's expiry" do
      subscribe(keyword: "aoe3", duration: "1h")
      expect(scheduler.pending).to eq(1)
      job = sched_store.find(db[:scheduled_jobs].max(:id))
      expect(job.kind).to eq("expire_keyword_watch")
      expect(job.run_at).to eq(base + 3600)
      expect(job.payload["watch_id"]).to be_a(Integer)
    end

    it "ends the watch when its expiry fires" do
      subscribe(keyword: "aoe3", duration: "1h")
      advance(3601)
      ran = scheduler.run_due
      expect(ran).to eq(1)
      expect(service.list(community: community, subscriber: subscriber, adapter: :telegram)).to be_empty
    end

    it "survives a simulated restart: a fresh session recovers and ends the lapsed watch" do
      subscribe(keyword: "aoe3", duration: "1h")

      fresh = Rubotty::Core::DurableScheduler.new(
        store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
        session_id: "session-2", clock: clock, logger: Rubotty::Log.null
      )
      fresh.register(Rubotty::Core::KeywordWatches::EXPIRE_KIND) { |job| service.expire(job) }

      advance(3601)
      fresh.recover(alive_session_ids: ["session-2"], now: clock.call)

      expect(service.list(community: community, subscriber: subscriber, adapter: :telegram)).to be_empty
    end

    it "leaves a still-active watch enforced across a restart" do
      subscribe(keyword: "aoe3", duration: "1h")

      fresh = Rubotty::Core::DurableScheduler.new(
        store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
        session_id: "session-2", clock: clock, logger: Rubotty::Log.null
      )
      fresh.register(Rubotty::Core::KeywordWatches::EXPIRE_KIND) { |job| service.expire(job) }

      advance(1800) # 30 minutes: not due yet
      fresh.recover(alive_session_ids: ["session-2"], now: clock.call)

      expect(service.list(community: community, subscriber: subscriber, adapter: :telegram).size).to eq(1)
    end
  end
end
