# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The ladder escalates across a configured threshold to an auto-expiring
# temp-mute or temp-ban, reversed through the durable scheduler so an expiry
# survives a restart.
RSpec.describe Rubotty::Core::Warnings do
  # MySQL refuses a GET_LOCK name past 64 characters outright, and the only CI
  # job pointed at MariaDB never reaches the warnings store, so the length is
  # pinned here instead.
  describe ".subject_lock_name" do
    it "stays inside the MySQL lock-name limit however long the subject is" do
      name = described_class.subject_lock_name("a" * 120, "telegram", "@somebody:homeserver.example.org")
      expect(name.length).to be <= 64
    end

    it "is stable for one subject and different for another" do
      first = described_class.subject_lock_name("sample", :telegram, "u1")
      expect(described_class.subject_lock_name("sample", :telegram, "u1")).to eq(first)
      expect(described_class.subject_lock_name("sample", :telegram, "u2")).not_to eq(first)
      expect(described_class.subject_lock_name("other", :telegram, "u1")).not_to eq(first)
    end

    it "reads a symbol platform the same as its string, since a durable payload gives back strings" do
      expect(described_class.subject_lock_name("sample", :telegram, "u1"))
        .to eq(described_class.subject_lock_name("sample", "telegram", "u1"))
    end
  end

  describe Rubotty::Core::Warnings::Ladder do
    def parse(rungs)
      described_class.parse({ ladder: rungs }, logger: Rubotty::Log.null)
    end

    it "parses a ladder and sorts it by threshold, tolerating string keys" do
      ladder = parse([{ "threshold" => 5, "action" => "ban", "duration" => "1d" },
                      { threshold: 3, action: "mute", duration: "1h" }])
      expect(ladder.rules.map(&:threshold)).to eq([3, 5])
      expect(ladder.rules.map(&:action)).to eq(%i[mute ban])
      expect(ladder.rules.map(&:duration)).to eq([3600, 86_400])
    end

    it "drops a rung with an unknown action, a bad threshold, or an unreadable duration" do
      ladder = parse([{ threshold: 3, action: "obliterate", duration: "1h" },
                      { threshold: 0, action: "mute", duration: "1h" },
                      { threshold: 2, action: "mute", duration: "forever" },
                      { threshold: 4, action: "ban", duration: 60 }])
      expect(ladder.rules.map(&:threshold)).to eq([4])
    end

    it "returns the rung a warning crossed, and nothing between or above the rungs" do
      ladder = parse([{ threshold: 3, action: "mute", duration: "1h" },
                      { threshold: 5, action: "ban", duration: "1d" }])
      expect(ladder.for_count(2)).to be_nil
      expect(ladder.for_count(3).action).to eq(:mute)
      expect(ladder.for_count(4)).to be_nil
      expect(ladder.for_count(5).action).to eq(:ban)
      expect(ladder.for_count(6)).to be_nil
    end

    it "is empty for a config with no ladder" do
      expect(described_class.parse({}).empty?).to be(true)
    end

    it "reads a kick rung with no duration at all, for removal from the community" do
      ladder = parse([{ threshold: 7, action: "kick" }])
      expect(ladder.for_count(7).action).to eq(:kick)
      expect(ladder.for_count(7).duration).to be_nil
    end

    it "reads a mute or ban rung with no duration as permanent" do
      ladder = parse([{ threshold: 4, action: "mute" }, { threshold: 6, action: "ban" }])
      expect(ladder.for_count(4).duration).to be_nil
      expect(ladder.for_count(6).duration).to be_nil
    end
  end

  describe Rubotty::Core::Warnings::Service do
    let(:db) do
      db = Sequel.sqlite
      Rubotty::ControlPlane::Migrator.run(db)
      db
    end
    let(:store) { Rubotty::Core::WarningsStore::Sequel.new(db: db) }
    let(:sched_store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
    let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db) }

    let(:base) { Time.utc(2026, 7, 23, 12, 0, 0) }
    let(:clock_time) { [base] }
    let(:clock) { -> { clock_time.first } }
    def advance(seconds) = clock_time[0] = clock_time.first + seconds

    let(:reacting) { Fakes::ReactingAdapter.new(own_id: "bot") }
    let(:plain) { Fakes::RecordingAdapter.new(own_id: "bot2") }
    # A DM-capable twin of +reacting+, for the specs that need the DM to
    # actually land instead of exercising the failure path.
    let(:dm_reacting) { Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: true) }

    # A moderation-capable endpoint plus a sibling that cannot moderate, so
    # capability gating is observable within one room.
    let(:supported) { endpoint("tg", account: "a") }
    let(:unsupported) { endpoint("tg2", account: "b") }
    let(:adapters) { { [:fake, "a"] => reacting, [:fake, "b"] => plain } }
    let(:dm_adapters) { { [:fake, "a"] => dm_reacting, [:fake, "b"] => plain } }
    let(:room_topology) { topology(room("r", supported, unsupported)) }
    let(:message_storage) { Rubotty::Storage::Memory.new }

    let(:scheduler) do
      Rubotty::Core::DurableScheduler.new(
        store: sched_store, session_id: "session-1", clock: clock, logger: Rubotty::Log.null
      )
    end

    let(:service) do
      described_class.new(
        store: store, scheduler: scheduler, topology: room_topology, adapters: adapters,
        storage: message_storage, audit: audit, logger: Rubotty::Log.null, clock: clock
      )
    end

    # A service over the SAME room and store, whose subject's platform can
    # actually take a DM, for the specs that check delivered content rather
    # than the failure path.
    let(:dm_service) do
      described_class.new(
        store: store, scheduler: scheduler, topology: room_topology, adapters: dm_adapters,
        storage: message_storage, audit: audit, logger: Rubotty::Log.null, clock: clock
      )
    end

    before do
      scheduler.register(Rubotty::Core::Warnings::EXPIRE_KIND) { |job| service.expire(job) }
      scheduler.register(Rubotty::Core::Warnings::DECAY_KIND) { |job| service.decay(job) }
    end

    let(:subject_author) { author(native_id: "u9", username: "troll") }

    def ladder(rungs = [{ threshold: 3, action: "mute", duration: "1h" },
                        { threshold: 5, action: "ban", duration: "1d" }])
      Rubotty::Core::Warnings::Ladder.parse({ ladder: rungs }, logger: Rubotty::Log.null)
    end

    def warn(community: "sample", reason: nil, issued_by: "Op", rungs: nil, max: nil, expire_after: nil)
      service.warn(
        community: community, subject: subject_author, origin: supported,
        ladder: rungs ? ladder(rungs) : ladder, max: max, expire_after: expire_after,
        reason: reason, issued_by: issued_by
      )
    end

    describe "issuing, listing and clearing" do
      it "records a warning and returns the running active count" do
        outcome = warn(reason: "spam")
        expect(outcome.count).to eq(1)
        expect(outcome.warning.reason).to eq("spam")
        expect(outcome.escalated?).to be(false)
      end

      it "lists a subject's active warnings on their platform" do
        warn(reason: "first")
        warn(reason: "second")
        listed = service.list(community: "sample", subject: subject_author, adapter: :fake)
        expect(listed.map(&:reason)).to eq(%w[first second])
      end

      it "clears the latest, or all, of a subject's warnings" do
        warn
        warn
        expect(service.clear(community: "sample", subject: subject_author, adapter: :fake, scope: :latest)).to eq(1)
        expect(service.clear(community: "sample", subject: subject_author, adapter: :fake, scope: :all)).to eq(1)
        expect(service.list(community: "sample", subject: subject_author, adapter: :fake)).to be_empty
      end

      it "returns nil without a community to scope to, so a no-control-plane call is inert" do
        expect(warn(community: nil)).to be_nil
      end

      it "records a durable audit event an operator can see on the dashboard, not just the process log" do
        warn(reason: "spam", issued_by: "telegram:alice")
        event = audit.query(community: "sample", action: "warn").first
        expect(event.source).to eq("warnings")
        expect(event.subject_native_id).to eq("u9")
        expect(event.subject).to eq(subject_author.any_name)
        expect(event.reason).to eq("spam")
        expect(event.actor).to eq("telegram:alice")
        expect(event.outcome).to eq("1 active")
      end
    end

    describe "the escalation ladder" do
      it "does nothing below the first threshold" do
        warn
        warn
        expect(reacting.moderations).to be_empty
        expect(store.active_sanctions(community: "sample", adapter: :fake, subject_native_id: "u9")).to be_empty
      end

      it "applies a mute when a warning crosses the mute threshold" do
        2.times { warn }
        outcome = warn # the 3rd strike
        expect(outcome.escalated?).to be(true)
        expect(outcome.sanction.action).to eq(:mute)
        mute = reacting.moderations.last
        expect(mute[:action]).to eq(:mute)
        expect(mute[:target_user_id]).to eq("u9")
      end

      it "applies a ban when a warning crosses the higher ban threshold" do
        5.times { warn }
        actions = reacting.moderations.map { |m| m[:action] }
        expect(actions).to include(:mute) # at 3
        expect(actions.last).to eq(:ban)  # at 5
      end

      it "records a durable audit event for the auto-sanction, distinct from the warn events under it" do
        3.times { warn }
        event = audit.query(community: "sample", action: "mute").first
        expect(event.source).to eq("warnings")
        expect(event.subject_native_id).to eq("u9")
        expect(event.actor).to include("warnings ladder")
        expect(event.outcome).to eq("applied to tg")
        expect(audit.query(community: "sample", action: "warn").length).to eq(3)
      end
    end

    describe "concurrent warnings on the same subject" do
      # A store whose #active_count pauses right where the real race lives: after
      # the insert has committed, before the count is read back. Without the
      # advisory lock around both calls, two threads racing #warn both insert
      # and then both read the post-both-inserts count.
      def paused_count_store(inner, gate)
        Class.new do
          define_method(:initialize) { @inner = inner }

          define_method(:active_count) do |**kwargs|
            gate.call
            @inner.active_count(**kwargs)
          end

          define_method(:method_missing) do |name, *args, **kwargs, &block|
            @inner.public_send(name, *args, **kwargs, &block)
          end

          define_method(:respond_to_missing?) do |name, include_private = false|
            @inner.respond_to?(name, include_private) || super(name, include_private)
          end
        end.new
      end

      it "gives two racing warnings their own sequential count instead of both reading the combined total" do
        paused = paused_count_store(store, -> { sleep 0.05 })
        racer = described_class.new(
          store: paused, scheduler: scheduler, topology: room_topology, adapters: adapters,
          storage: message_storage, audit: audit, logger: Rubotty::Log.null, clock: clock
        )

        counts = []
        results_mutex = Mutex.new
        threads = Array.new(2) do
          Thread.new do
            outcome = racer.warn(
              community: "sample", subject: subject_author, origin: supported,
              ladder: ladder([{ threshold: 2, action: "mute", duration: "1h" }]), issued_by: "Op"
            )
            results_mutex.synchronize { counts << outcome.count }
          end
        end
        threads.each(&:join)

        expect(counts.sort).to eq([1, 2])
        # Only the warning that actually reached count 2 should have escalated.
        expect(reacting.moderations.map { |m| m[:action] }).to eq([:mute])
      end
    end

    describe "capability gating" do
      it "applies the sanction only where the platform supports it, skipping the rest" do
        outcome = warn(rungs: [{ threshold: 1, action: "mute", duration: "1h" }])
        # The recorded sanction names only the endpoint it landed on.
        expect(outcome.sanction.endpoints).to eq(%w[tg])
        expect(reacting.moderations.map { |m| m[:endpoint_id] }).to eq(%w[tg])
        expect(plain.deleted).to be_empty
      end

      it "still records and schedules the sanction when no endpoint can carry it out, so the bridge can " \
         "enforce it where the platform could not" do
        only_plain = described_class.new(
          store: store, scheduler: scheduler, topology: topology(room("r", unsupported)),
          adapters: adapters, logger: Rubotty::Log.null, clock: clock
        )
        result = only_plain.sanction(
          community: "sample", subject: subject_author, origin: unsupported,
          action: :mute, duration: 3600
        )
        expect(result.applied?).to be(false)
        expect(result.record).not_to be_nil
        expect(sched_store.count).to eq(1)
        expect(store.active_sanctions(community: "sample", adapter: :fake, subject_native_id: "u9")).not_to be_empty
      end

      it "refuses to apply a sanction it cannot scope to a community, so no permanent mute is stranded" do
        result = service.sanction(
          community: nil, subject: subject_author, origin: supported, action: :mute, duration: 3600
        )
        expect(result.applied?).to be(false)
        expect(reacting.moderations).to be_empty
        expect(sched_store.count).to eq(0)
      end
    end

    describe "expiry through the durable scheduler" do
      before { warn(rungs: [{ threshold: 1, action: "mute", duration: "1h" }]) }

      it "schedules the reversal as an expire_sanction job carrying what it needs to reverse" do
        expect(scheduler.pending).to eq(1)
        job = sched_store.find(db[:scheduled_jobs].max(:id))
        expect(job.kind).to eq("expire_sanction")
        # SQLite stores a naive datetime, so compare the wall clock rather than
        # an absolute instant.
        expect(job.run_at.strftime("%H:%M")).to eq("13:00")
        expect(job.payload["action"]).to eq("mute")
        expect(job.payload["native_id"]).to eq("u9")
        expect(job.payload["endpoints"]).to eq(["tg"])
      end

      it "unmutes when the expiry fires, and lifts the sanction row" do
        advance(3601)
        ran = scheduler.run_due
        expect(ran).to eq(1)
        expect(reacting.moderations.map { |m| m[:action] }).to include(:unmute)
        expect(store.active_sanctions(community: "sample", adapter: :fake, subject_native_id: "u9")).to be_empty
      end

      it "records a durable audit event when the expiry reverses the sanction" do
        advance(3601)
        scheduler.run_due
        event = audit.query(community: "sample", action: "unmute").first
        expect(event.subject_native_id).to eq("u9")
        expect(event.outcome).to eq("sanction expired")
      end

      it "survives a simulated restart: a fresh session recovers and lifts the lapsed sanction" do
        # A new process: its own session id over the SAME database, recovering
        # a mute that lapsed during the downtime.
        fresh = Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
          session_id: "session-2", clock: clock, logger: Rubotty::Log.null
        )
        fresh.register(Rubotty::Core::Warnings::EXPIRE_KIND) { |job| service.expire(job) }

        advance(3601)
        fresh.recover(alive_session_ids: ["session-2"], now: clock.call)

        expect(reacting.moderations.map { |m| m[:action] }).to include(:unmute)
        expect(store.active_sanctions(community: "sample", adapter: :fake, subject_native_id: "u9")).to be_empty
      end
    end

    describe "a temp-ban expiry reverses with unban" do
      it "unbans when a ban's expiry fires" do
        warn(rungs: [{ threshold: 1, action: "ban", duration: "1d" }])
        advance(86_401)
        scheduler.run_due
        actions = reacting.moderations.map { |m| m[:action] }
        expect(actions).to include(:ban)
        expect(actions).to include(:unban)
      end
    end

    describe "expiry against an adapter with an asymmetric moderates? set" do
      # Declares mute but not its own reverse, unlike every real adapter today,
      # to prove #expire checks moderates?(reverse) rather than firing it blind.
      let(:asymmetric_caps) do
        Rubotty::Adapters::Capabilities.new(edits: true, deletes: true, replies: true, moderation: %i[mute ban kick])
      end
      let(:asymmetric) do
        caps = asymmetric_caps
        adapter = Fakes::ReactingAdapter.new(own_id: "bot")
        adapter.define_singleton_method(:capabilities) { caps }
        adapter
      end
      let(:asym_adapters) { { [:fake, "a"] => asymmetric, [:fake, "b"] => plain } }
      let(:asym_service) do
        described_class.new(
          store: store, scheduler: scheduler, topology: room_topology, adapters: asym_adapters,
          storage: message_storage, audit: audit, logger: Rubotty::Log.null, clock: clock
        )
      end

      before { scheduler.register(Rubotty::Core::Warnings::EXPIRE_KIND) { |job| asym_service.expire(job) } }

      it "does not fire the reverse action where the adapter never declared it" do
        asym_service.warn(
          community: "sample", subject: subject_author, origin: supported,
          ladder: ladder([{ threshold: 1, action: "mute", duration: "1h" }]), issued_by: "Op"
        )
        expect(asymmetric.moderations.map { |m| m[:action] }).to eq([:mute])

        advance(3601)
        scheduler.run_due

        expect(asymmetric.moderations.map { |m| m[:action] }).to eq([:mute])
      end
    end

    describe "the DM" do
      it "tells the subject the reason and their level, phrased against the configured max" do
        dm_service.warn(
          community: "sample", subject: subject_author, origin: supported, ladder: ladder,
          max: 3, reason: "spam", issued_by: "Op"
        )
        text = dm_reacting.dms_sent.last[:text]
        expect(text).to include("Reason: spam.")
        expect(text).to include("You are now at warning level 1 of 3")
      end

      # A member has to know how long a strike is held against them to know
      # whether they are close to the next rung or nearly clear of the last.
      it "says how long the warning stays on their record" do
        dm_service.warn(community: "sample", subject: subject_author, origin: supported,
                        ladder: ladder, reason: "spam", expire_after: 90 * 86_400)

        expect(dm_reacting.dms_sent.last[:text])
          .to include("This warning stays on your record for 90 days, then it expires on its own.")
      end

      it "says nothing about a record that never expires" do
        dm_service.warn(community: "sample", subject: subject_author, origin: supported,
                        ladder: ladder, reason: "spam")

        expect(dm_reacting.dms_sent.last[:text]).not_to include("stays on your record")
      end

      # The operator who issued it is never named: the invocation is taken away
      # at once so the room cannot work out who called it, and naming them in
      # the one message the member is sure to read would undo that.
      it "never names the operator who issued it" do
        dm_service.warn(community: "sample", subject: subject_author, origin: supported,
                        ladder: ladder, reason: "spam", issued_by: "Quillsharp", max: 3)

        expect(dm_reacting.dms_sent.last[:text]).not_to include("Quillsharp")
      end

      it "adds a forward notice only when the next level actually carries a penalty" do
        two_rung = ladder([{ threshold: 2, action: "mute", duration: "1h" }])
        dm_service.warn(community: "sample", subject: subject_author, origin: supported,
                        ladder: two_rung, reason: "spam")
        expect(dm_reacting.dms_sent.last[:text]).to include("If you are warned again, you will be muted for 1h.")
      end

      it "omits the forward notice once the level itself already carried the only configured penalty" do
        two_rung = ladder([{ threshold: 2, action: "mute", duration: "1h" }])
        2.times do
          dm_service.warn(community: "sample", subject: subject_author, origin: supported,
                          ladder: two_rung, reason: "spam")
        end
        text = dm_reacting.dms_sent.last[:text]
        expect(text).not_to include("If you are warned again")
        expect(text).to include("You have been muted for 1h")
      end

      it "records a durable trace when the DM cannot be delivered, so a closed-DM member is never silently missed" do
        warn(reason: "spam")
        event = audit.query(community: "sample", action: "dm_failed").first
        expect(event.subject_native_id).to eq("u9")
        expect(event.outcome).to include("a warning")
      end

      it "reports the DM failure back on the outcome" do
        expect(warn(reason: "spam").dm_sent).to be(false)
      end
    end

    describe "removal from the community" do
      it "kicks on a kick rung, DMs the removal, and schedules nothing to reverse it" do
        outcome = dm_service.warn(
          community: "sample", subject: subject_author, origin: supported,
          ladder: ladder([{ threshold: 1, action: "kick" }]), reason: "spam"
        )
        expect(outcome.sanction.action).to eq(:kick)
        expect(dm_reacting.moderations.last[:action]).to eq(:kick)
        expect(sched_store.count).to eq(0)
        expect(dm_reacting.dms_sent.last[:text]).to include("removed from the community")
      end

      it "names the community rather than repeating the word when kicked directly (not through a warn)" do
        dm_service.sanction(community: "sample", subject: subject_author, origin: supported, action: :kick)
        expect(dm_reacting.dms_sent.last[:text]).to eq("You have been removed from sample.")
      end
    end

    describe "a permanent mute or ban" do
      it "has no until_at, schedules nothing to reverse it, and reaches the adapter as its own maximum" do
        outcome = dm_service.warn(
          community: "sample", subject: subject_author, origin: supported,
          ladder: ladder([{ threshold: 1, action: "mute" }]), reason: "spam"
        )
        expect(outcome.sanction.until_at).to be_nil
        expect(sched_store.count).to eq(0)
        max_minutes = (Rubotty::Core::Warnings::PERMANENT_MUTE_ARGUMENT_SECONDS / 60.0).ceil.to_s
        expect(dm_reacting.moderations.last[:arguments]).to eq([max_minutes])
        expect(dm_reacting.dms_sent.last[:text]).to include("muted permanently")
      end

      it "still records the sanction row so the bridge can enforce it, unlike a kick" do
        outcome = dm_service.warn(
          community: "sample", subject: subject_author, origin: supported,
          ladder: ladder([{ threshold: 1, action: "ban" }]), reason: "spam"
        )
        expect(outcome.sanction.record).not_to be_nil
        expect(dm_reacting.dms_sent.last[:text]).to include("banned permanently")
      end
    end

    describe "warning decay" do
      it "drops the level after the configured expiry and DMs the decrease" do
        scheduler.register(Rubotty::Core::Warnings::DECAY_KIND) { |job| dm_service.decay(job) }
        dm_service.warn(community: "sample", subject: subject_author, origin: supported,
                        max: 3, expire_after: 86_400, reason: "first")
        advance(60) # stagger the second warning's decay a minute later than the first's
        dm_service.warn(community: "sample", subject: subject_author, origin: supported,
                        max: 3, expire_after: 86_400, reason: "second")
        expect(store.active_count(community: "sample", adapter: :fake, subject_native_id: "u9")).to eq(2)

        advance(86_341)
        expect(scheduler.run_due).to eq(1) # only the first warning's decay is due yet
        expect(store.active_count(community: "sample", adapter: :fake, subject_native_id: "u9")).to eq(1)
        text = dm_reacting.dms_sent.last[:text]
        expect(text).to include("has expired")
        expect(text).to include("warning level 1 of 3")
      end

      it "records a durable decay audit event" do
        scheduler.register(Rubotty::Core::Warnings::DECAY_KIND) { |job| service.decay(job) }
        warn(reason: "spam", expire_after: 86_400)
        advance(86_401)
        scheduler.run_due
        event = audit.query(community: "sample", action: "decay").first
        expect(event.subject_native_id).to eq("u9")
        expect(event.outcome).to eq("0 active")
      end

      it "is idempotent: a warning already cleared by hand does not decay a second time" do
        scheduler.register(Rubotty::Core::Warnings::DECAY_KIND) { |job| service.decay(job) }
        warn(reason: "spam", expire_after: 86_400)
        service.clear(community: "sample", subject: subject_author, adapter: :fake, scope: :all)
        advance(86_401)
        expect { scheduler.run_due }.not_to raise_error
        expect(audit.query(community: "sample", action: "decay")).to be_empty
      end
    end

    describe "#suppress?" do
      def chat = message(supported, native_id: "77", author: subject_author)

      it "is false without an active mute" do
        expect(service.suppress?(message: chat, community: "sample")).to be(false)
      end

      it "deletes the message and DMs the subject when muted, even where the platform itself could not mute them" do
        service.sanction(
          community: "sample", subject: subject_author, origin: unsupported, action: :mute, duration: 3600
        )
        expect(dm_service.suppress?(message: chat, community: "sample")).to be(true)
        expect(dm_reacting.deleted).not_to be_empty
        expect(dm_reacting.dms_sent.last[:text]).to include("was not delivered because you are muted")
      end

      it "stops suppressing once until_at has passed, even before the expiry job has run" do
        service.sanction(
          community: "sample", subject: subject_author, origin: unsupported, action: :mute, duration: 3600
        )
        advance(3601)
        expect(service.suppress?(message: chat, community: "sample")).to be(false)
      end

      # A mute enforced by dropping messages is invisible to the person it is
      # enforced against, and the people a bot cannot DM are exactly the people
      # most likely to be muted without ever learning why.
      describe "#suppress? where no DM can reach the author" do
        def chat = message(supported, native_id: "77", author: subject_author)

        let(:poster) do
          Rubotty::Core::EphemeralMessage.new(
            adapters: adapters, session_id: "s", topology: room_topology, logger: Rubotty::Log.null
          )
        end
        let(:announcing) do
          described_class.new(
            store: store, scheduler: scheduler, topology: room_topology, adapters: adapters,
            storage: message_storage, audit: audit, ephemeral: poster,
            logger: Rubotty::Log.null, clock: clock
          )
        end

        before do
          service.sanction(
            community: "sample", subject: subject_author, origin: unsupported, action: :mute, duration: 3600
          )
        end

        it "says so in the room instead, naming how long the mute has left" do
          expect(announcing.suppress?(message: chat, community: "sample")).to be(true)

          notice = reacting.delivered_to("tg").last
          expect(notice.body.text).to include("your message was removed because you are muted")
          expect(notice.body.text).to include("it lifts in 1h")
        end

        # Somebody muted mid-argument can send a dozen messages a minute, and a
        # notice for each would be the room shouting rather than informing.
        it "posts one notice per author within the cooldown, however much they say" do
          3.times { announcing.suppress?(message: chat, community: "sample") }

          notices = reacting.delivered_to("tg").count { |m| m.body.text.include?("because you are muted") }
          expect(notices).to eq(1)
        end

        it "says it again once the cooldown has passed, since the mute still stands" do
          announcing.suppress?(message: chat, community: "sample")
          advance(Rubotty::Core::Warnings::DROP_NOTICE_COOLDOWN + 1)
          announcing.suppress?(message: chat, community: "sample")

          notices = reacting.delivered_to("tg").count { |m| m.body.text.include?("because you are muted") }
          expect(notices).to eq(2)
        end
      end

      it "keeps suppressing indefinitely for a permanent mute" do
        service.sanction(
          community: "sample", subject: subject_author, origin: unsupported, action: :mute, duration: nil
        )
        advance(999_999)
        expect(service.suppress?(message: chat, community: "sample")).to be(true)
      end
    end
  end
end
