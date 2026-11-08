# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe Rubotty::ControlPlane::PendingSpaces, :control_plane do
  # Configurable per test so both "can leave" and "structurally cannot leave"
  # platforms are exercised with no network. Built fresh per call so nothing
  # leaks a global constant.
  def fake_pending_adapter(can_leave: true, can_notice: true, can_dm: true, leave_succeeds: true,
                           can_enumerate: true)
    Class.new do
      attr_reader :left, :notices, :dms, :enumerated

      define_method(:initialize) do
        @left = []
        @notices = []
        @dms = []
        @enumerated = []
      end

      define_method(:supports_space_enumeration?) { can_enumerate }
      define_method(:enumerate_space) do |external_id|
        @enumerated << external_id
        true
      end

      define_method(:supports_leave?) { can_leave }
      define_method(:leave_space) do |external_id, notice: nil|
        @left << { external_id: external_id, notice: notice }
        leave_succeeds
      end

      define_method(:supports_space_notice?) { can_notice }
      define_method(:post_space_notice) do |external_id, text|
        @notices << { external_id: external_id, text: text }
        true
      end

      define_method(:supports_admin_dm?) { can_dm }
      define_method(:send_admin_dm) do |native_id, text|
        @dms << { native_id: native_id, text: text }
        true
      end
    end.new
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:db) { seeded[0] }
  let(:authorization) { Rubotty::ControlPlane::AuthorizationDirectory.new(models: models) }
  let(:known_connection) { models.platform_connection.where(community_id: models.community.first.id).first }

  let(:base) { Time.utc(2026, 7, 24, 12, 0, 0) }
  let(:clock_time) { [base] }
  let(:clock) { -> { clock_time.first } }
  def advance(seconds) = clock_time[0] = clock_time.first + seconds

  let(:adapter) { fake_pending_adapter }
  let(:adapters) { { [:telegram, "bot"] => adapter } }

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s1",
      clock: clock, logger: Rubotty::Log.null
    )
  end

  subject(:service) do
    described_class.new(
      models: models, authorization: authorization, scheduler: scheduler, adapters: adapters,
      ttl: 1800, clock: clock, logger: Rubotty::Log.null
    )
  end

  before { scheduler.register(described_class::EXPIRE_KIND) { |job| service.expire(job) } }

  def join(external_id: "-100555", name: "Rando Group", inviter_native_id: "77",
           inviter_username: "rando", inviter_display: "Rando", member_count: 5,
           sample_channels: ["general"])
    service.on_join!(
      adapter: :telegram, account: "bot", external_id: external_id, name: name,
      inviter_native_id: inviter_native_id, inviter_username: inviter_username,
      inviter_display: inviter_display, member_count: member_count, sample_channels: sample_channels
    )
  end

  describe "migration 020" do
    it "creates the pending_spaces table with the dedupe/soft-blacklist unique index" do
      expect(db.table_exists?(:pending_spaces)).to be(true)
      indexes = db.indexes(:pending_spaces)
      dedupe = indexes[:pending_spaces_addr_idx]
      expect(dedupe).not_to be_nil
      expect(dedupe[:unique]).to be(true)
      expect(dedupe[:columns]).to eq(%i[adapter account external_id])
    end

    it "enforces the dedupe/soft-blacklist rule at the database level, not just in the service" do
      now = Time.now
      models.pending_space.create(
        adapter: "telegram", account: "bot", external_id: "-1", state: "pending",
        expires_at: now + 1800, created_at: now, updated_at: now
      )
      expect do
        models.pending_space.create(
          adapter: "telegram", account: "bot", external_id: "-1", state: "pending",
          expires_at: now + 1800, created_at: now, updated_at: now
        )
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  describe "#on_join!" do
    it "creates exactly one pending row and says to post the notice" do
      outcome = join
      expect(outcome.pending?).to be(true)
      expect(outcome.post_notice).to be(true)
      expect(models.pending_space.where(adapter: "telegram", external_id: "-100555").count).to eq(1)

      row = outcome.row
      expect(row.state).to eq("pending")
      expect(row.name).to eq("Rando Group")
      expect(row.inviter_native_id).to eq("77")
      expect(row.inviter_username).to eq("rando")
      expect(row.member_count).to eq(5)
      expect(row.json_value(:sample_channels)).to eq(["general"])
      # SQLite stores a naive datetime, so compare the wall clock rather than
      # an absolute instant.
      expect(row.expires_at.strftime("%Y-%m-%d %H:%M:%S")).to eq((base + 1800).strftime("%Y-%m-%d %H:%M:%S"))
    end

    it "dedupes: a second join for the same space touches the row instead of duplicating it" do
      first = join
      # Posting PENDING_NOTICE is what records the dedupe marker, so simulate
      # it here to evaluate the second join the way a real re-add would be.
      service.mark_notice_posted!(first.row)
      second = join(name: "Rando Group (renamed)")

      expect(models.pending_space.where(adapter: "telegram", external_id: "-100555").count).to eq(1)
      expect(second.row.id).to eq(first.row.id)
      expect(second.row.name).to eq("Rando Group (renamed)")
      expect(second.post_notice).to be(false)
      expect(second.row.expires_at).to eq(first.row.expires_at)
    end

    it "notifies the administrator once, on first creation only" do
      notifier = instance_double(Rubotty::ControlPlane::AdminNotifier)
      expect(notifier).to receive(:notify!).once
      svc = described_class.new(
        models: models, authorization: authorization, scheduler: scheduler, adapters: adapters,
        admin_notifier: notifier, clock: clock, logger: Rubotty::Log.null
      )
      svc.on_join!(adapter: :telegram, account: "bot", external_id: "-100555", name: "Rando")
      svc.on_join!(adapter: :telegram, account: "bot", external_id: "-100555", name: "Rando")
    end

    it "schedules the durable auto-leave timer on first creation" do
      join
      expect(scheduler.pending).to eq(1)
    end

    # A space mapping to a known community must never be pended. Exercised
    # against the real seeded control plane rather than a stub.
    describe "never pends a known community (SAMPLE safety net)" do
      it "does not create a row for a space the control plane already maps" do
        outcome = service.on_join!(
          adapter: known_connection.adapter, account: known_connection.account,
          external_id: known_connection.external_id, name: "SAMPLE"
        )
        expect(outcome.stay?).to be(true)
        expect(models.pending_space.where(
          adapter: known_connection.adapter, external_id: known_connection.external_id
        ).count).to eq(0)
      end

      # The whitelist protects a TITLE, and a title says nothing about who owns
      # the space, so a brand new group named after a core community is owned by
      # nobody yet and belongs on the board like any other unattributed space.
      # What the whitelist buys it is that nothing ever leaves it.
      it "still pends a space whose title is on the deployment-configured protected whitelist" do
        outcome = service.on_join!(adapter: :telegram, account: "bot", external_id: "-100999999",
                                   name: "SAMPLE - General")
        expect(outcome.pending?).to be(true)
        expect(models.pending_space.where(external_id: "-100999999").count).to eq(1)
      end

      it "schedules no auto-leave timer for a protected title, and posts no departure promise" do
        outcome = service.on_join!(adapter: :telegram, account: "bot", external_id: "-100999999",
                                   name: "SAMPLE - General")
        expect(outcome.post_notice).to be(false)
        expect(scheduler.pending).to eq(0)
      end

      # The row can be created nameless from a topic sighting and only learn its
      # protected title later, by which time the timer is already on the books.
      it "refuses to leave a protected space even when its timer does fire" do
        outcome = service.on_join!(adapter: :telegram, account: "bot", external_id: "-100999999",
                                   name: "Rando Group")
        outcome.row.update(name: "SAMPLE - General")
        advance(3600)
        scheduler.run_due

        expect(adapter.left).to be_empty
        expect(models.pending_space[outcome.row.id].state).to eq("pending")
      end

      it "never touches an already-APPROVED row even if on_join! is called again" do
        outcome = join
        service.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando Community")

        again = join
        expect(again.stay?).to be(true)
        expect(models.pending_space[outcome.row.id].state).to eq("approved")
      end
    end
  end

  describe "#on_traffic!" do
    def traffic(external_id: "-100777", name: "Quiet Group")
      service.on_traffic!(adapter: :telegram, account: "bot", external_id: external_id, name: name)
    end

    it "pends a space nothing could attribute, so a missed join event is recoverable" do
      row = traffic
      expect(row).not_to be_nil
      expect(row.state).to eq("pending")
      expect(row.name).to eq("Quiet Group")
      expect(models.pending_space.where(adapter: "telegram", external_id: "-100777").count).to eq(1)
    end

    it "stays silent, leaving the notice unposted so a later real join still posts it once" do
      row = traffic
      expect(row.notice_posted_at).to be_nil
      expect(adapter.notices).to be_empty

      outcome = join(external_id: "-100777")
      expect(outcome.post_notice).to be(true)
    end

    it "still starts the auto-leave timer, so a space noticed this way is not held forever" do
      row = traffic
      expect(row.expires_at.to_i).to eq((base + 1800).to_i)
      expect(row.job_id).not_to be_nil
    end

    it "writes nothing on repeated traffic, and never restarts the review clock" do
      first = traffic
      advance(600)
      expect(traffic).to be_nil
      expect(traffic).to be_nil

      row = models.pending_space[first.id]
      expect(models.pending_space.where(external_id: "-100777").count).to eq(1)
      expect(row.expires_at.to_i).to eq((base + 1800).to_i)
    end

    it "refuses a space that IS mapped to a community" do
      expect(service.on_traffic!(adapter: known_connection.adapter, account: known_connection.account,
                                 external_id: known_connection.external_id, name: "SAMPLE")).to be_nil
      expect(models.pending_space.where(external_id: known_connection.external_id).count).to eq(0)
    end

    it "leaves a denied space denied, rather than re-pending it or making any noise" do
      denied = traffic
      service.deny(id: denied.id, admin: "test")
      adapter.notices.clear

      expect(traffic).to be_nil
      expect(models.pending_space[denied.id].state).to eq("denied")
      expect(adapter.notices).to be_empty
    end

    it "caps how many spaces traffic alone may pend in one window, so it cannot flood the table" do
      described_class::TRAFFIC_LIMIT.times { |i| expect(traffic(external_id: "-10#{i}")).not_to be_nil }

      expect(traffic(external_id: "-1099999")).to be_nil
      expect(models.pending_space.count).to eq(described_class::TRAFFIC_LIMIT)
    end

    it "lets the window roll off, so a burst does not disable the fallback for good" do
      described_class::TRAFFIC_LIMIT.times { |i| traffic(external_id: "-10#{i}") }
      advance(described_class::TRAFFIC_WINDOW + 1)

      expect(traffic(external_id: "-1099999")).not_to be_nil
    end

    it "never rate-limits a real join event, however full the traffic budget is" do
      described_class::TRAFFIC_LIMIT.times { |i| traffic(external_id: "-10#{i}") }

      expect(join(external_id: "-1088888").pending?).to be(true)
    end

    it "ignores a blank external id" do
      expect(service.on_traffic!(adapter: :telegram, account: "bot", external_id: "")).to be_nil
      expect(models.pending_space.count).to eq(0)
    end
  end

  describe "#approve" do
    it "creates a NEW community and a platform_connections row, with no channel, room or feature enabled" do
      outcome = join
      result = service.approve(id: outcome.row.id, admin: "dashboard:administrator", new_community_name: "Rando")

      expect(result.status).to eq(:approved)
      expect(result.community.name).to eq("Rando")
      connection = models.platform_connection.where(adapter: "telegram", external_id: "-100555").first
      expect(connection.community_id).to eq(result.community.id)
      # Approval is presence and discovery only.
      expect(models.channel.where(community_id: result.community.id).count).to eq(0)
      expect(models.room.where(community_id: result.community.id).count).to eq(0)
      expect(models.feature_setting.where(community_id: result.community.id).count).to eq(0)

      row = models.pending_space[outcome.row.id]
      expect(row.state).to eq("approved")
      expect(row.community_id).to eq(result.community.id)
      expect(row.decided_by).to eq("dashboard:administrator")
    end

    it "ATTACHES to an EXISTING community instead, a second platform for the same community" do
      # Deliberately not named after SAMPLE, which would trip the protected-title
      # floor and short-circuit to :stay. The external_id differs from every
      # seeded connection, so this is genuinely a third one.
      before_count = models.platform_connection.where(community_id: models.community.first.id).count
      outcome = service.on_join!(adapter: :discord, account: "sample-discord-bot", external_id: "999888",
                                 name: "Second Platform Group")
      result = service.approve(id: outcome.row.id, admin: "test", community_id: models.community.first.id)

      expect(result.community.id).to eq(models.community.first.id)
      expect(models.platform_connection.where(community_id: models.community.first.id).count)
        .to eq(before_count + 1)
      expect(models.platform_connection.where(adapter: "discord", external_id: "999888").first.community_id)
        .to eq(models.community.first.id)
    end

    it "promotes the inviter to operator of the resulting community when asked" do
      outcome = join
      result = service.approve(
        id: outcome.row.id, admin: "test", new_community_name: "Rando", make_operator: true
      )
      identity = models.person_identity.where(adapter: "telegram", native_id: "77").first
      expect(identity).not_to be_nil
      operator = models.operator.where(community_id: result.community.id, person_id: identity.person_id).first
      expect(operator).not_to be_nil
    end

    it "does not promote anyone when make_operator is not asked for" do
      outcome = join
      result = service.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando")
      expect(models.operator.where(community_id: result.community.id).count).to eq(0)
    end

    it "is :invalid with neither an existing community nor a new name" do
      outcome = join
      result = service.approve(id: outcome.row.id, admin: "test")
      expect(result.status).to eq(:invalid)
      expect(models.pending_space[outcome.row.id].state).to eq("pending")
    end

    it "is :not_pending for an already-decided row" do
      outcome = join
      service.deny(id: outcome.row.id, admin: "test")
      result = service.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando")
      expect(result.status).to eq(:not_pending)
    end

    it "generates a readable, unique slug, even across a name collision" do
      first = join(external_id: "-1")
      second = join(external_id: "-2", name: "Rando Group")
      r1 = service.approve(id: first.row.id, admin: "test", new_community_name: "Rando Group")
      r2 = service.approve(id: second.row.id, admin: "test", new_community_name: "Rando Group")
      expect(r1.community.slug).not_to eq(r2.community.slug)
      expect(r2.community.slug).to match(/\Arando-group-\d+\z/)
    end
  end

  # Everything the adapter enumerated before approval had no platform connection
  # to be recorded against, so it was thrown away. Approval is what asks again.
  describe "the post-approval channel sweep" do
    it "asks a live adapter to enumerate the space it just authorized" do
      outcome = join
      service.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando")

      expect(adapter.enumerated).to eq(["-100555"])
    end

    it "does not sweep a space that was denied rather than approved" do
      outcome = join
      service.deny(id: outcome.row.id, admin: "test")

      expect(adapter.enumerated).to be_empty
    end

    it "schedules the sweep for a bot process when the approval was made where no adapter lives" do
      dashboard = described_class.new(
        models: models, authorization: authorization, scheduler: scheduler, adapters: {},
        ttl: 1800, clock: clock, logger: Rubotty::Log.null
      )
      outcome = dashboard.on_join!(adapter: :telegram, account: "bot", external_id: "-100777", name: "Rando")
      dashboard.approve(id: outcome.row.id, admin: "dashboard:administrator", new_community_name: "Rando")

      expect(scheduler.pending(kind: described_class::ENUMERATE_KIND)).to eq(1)
      expect(adapter.enumerated).to be_empty
    end

    it "carries out a dashboard approval's sweep in the process that holds the adapter" do
      dashboard = described_class.new(
        models: models, authorization: authorization, scheduler: scheduler, adapters: {},
        ttl: 1800, clock: clock, logger: Rubotty::Log.null
      )
      outcome = dashboard.on_join!(adapter: :telegram, account: "bot", external_id: "-100777", name: "Rando")
      dashboard.approve(id: outcome.row.id, admin: "dashboard:administrator", new_community_name: "Rando")

      scheduler.register(described_class::ENUMERATE_KIND) { |job| service.enumerate(job) }
      scheduler.run_due

      expect(adapter.enumerated).to eq(["-100777"])
    end

    it "does not raise on a platform that cannot enumerate a space at all" do
      quiet = fake_pending_adapter(can_enumerate: false)
      limited = described_class.new(
        models: models, authorization: authorization, scheduler: scheduler,
        adapters: { [:telegram, "bot"] => quiet }, ttl: 1800, clock: clock, logger: Rubotty::Log.null
      )
      outcome = limited.on_join!(adapter: :telegram, account: "bot", external_id: "-100888", name: "Rando")

      expect { limited.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando") }
        .not_to raise_error
      expect(quiet.enumerated).to be_empty
    end
  end

  # The Fluxer guild reached the board with no name, so its connection was
  # created with a blank label and nothing else would ever fill one in.
  describe "learning a space's name after it was approved" do
    def approved_space(name:, external_id: "-100555")
      outcome = service.on_join!(adapter: :telegram, account: "bot", external_id: external_id, name: name)
      service.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando")
      models.platform_connection.where(adapter: "telegram", external_id: external_id).first
    end

    it "fills in a blank connection label from a later join carrying the name" do
      connection = approved_space(name: nil)
      expect(connection.label).to be_nil

      service.on_join!(adapter: :telegram, account: "bot", external_id: "-100555",
                       name: "Example Gaming Community")

      expect(connection.refresh.label).to eq("Example Gaming Community")
    end

    it "fills in the pending row's blank name too, so the board stops reading unnamed" do
      outcome = service.on_join!(adapter: :telegram, account: "bot", external_id: "-100555", name: nil)
      service.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando")

      service.on_join!(adapter: :telegram, account: "bot", external_id: "-100555", name: "CloudNine")

      expect(models.pending_space[outcome.row.id].name).to eq("CloudNine")
    end

    it "never rewrites a label somebody already has" do
      connection = approved_space(name: "Original Name")

      service.on_join!(adapter: :telegram, account: "bot", external_id: "-100555", name: "Renamed Later")

      expect(connection.refresh.label).to eq("Original Name")
    end

    it "leaves a blank label blank when the later join carries no name either" do
      connection = approved_space(name: nil)

      service.on_join!(adapter: :telegram, account: "bot", external_id: "-100555", name: "   ")

      expect(connection.refresh.label).to be_nil
    end
  end

  describe "#deny" do
    it "leaves at once when the adapter can, and records the denial" do
      outcome = join
      result = service.deny(id: outcome.row.id, admin: "dashboard:administrator")

      expect(result.status).to eq(:denied)
      expect(adapter.left.size).to eq(1)
      expect(adapter.left.first[:external_id]).to eq("-100555")
      row = models.pending_space[outcome.row.id]
      expect(row.state).to eq("denied")
      expect(row.decided_by).to eq("dashboard:administrator")
      expect(row.left_at).not_to be_nil
      expect(row.inert_notice_posted_at).to be_nil
    end

    it "falls back to the maintainer-specified INERT_NOTICE, posted once, when the platform cannot leave" do
      cannot_leave = fake_pending_adapter(can_leave: false)
      svc = described_class.new(models: models, authorization: authorization, scheduler: scheduler,
                                adapters: { [:telegram, "bot"] => cannot_leave }, clock: clock,
                                logger: Rubotty::Log.null)
      outcome = svc.on_join!(adapter: :telegram, account: "bot", external_id: "-1", name: "No Leave")
      result = svc.deny(id: outcome.row.id, admin: "test")

      expect(result.status).to eq(:denied)
      expect(cannot_leave.left).to be_empty
      expect(cannot_leave.notices.size).to eq(1)
      expect(cannot_leave.notices.first[:text]).to eq(described_class::INERT_NOTICE)
      row = models.pending_space[outcome.row.id]
      expect(row.state).to eq("denied")
      expect(row.inert_notice_posted_at).not_to be_nil
    end

    it "falls back to inert when the leave call itself fails" do
      failing = fake_pending_adapter(leave_succeeds: false)
      svc = described_class.new(models: models, authorization: authorization, scheduler: scheduler,
                                adapters: { [:telegram, "bot"] => failing }, clock: clock, logger: Rubotty::Log.null)
      outcome = svc.on_join!(adapter: :telegram, account: "bot", external_id: "-2", name: "Fails")
      svc.deny(id: outcome.row.id, admin: "test")

      expect(failing.left.size).to eq(1)   # it tried
      expect(failing.notices.size).to eq(1) # and fell back
    end

    it "never posts the inert notice twice for the same space" do
      cannot_leave = fake_pending_adapter(can_leave: false)
      svc = described_class.new(models: models, authorization: authorization, scheduler: scheduler,
                                adapters: { [:telegram, "bot"] => cannot_leave }, clock: clock,
                                logger: Rubotty::Log.null)
      outcome = svc.on_join!(adapter: :telegram, account: "bot", external_id: "-3", name: "Repeat")
      svc.deny(id: outcome.row.id, admin: "test")
      # A nuisance re-add of the now-denied space tries again, silently.
      svc.reconfirm_denied!(models.pending_space[outcome.row.id])
      svc.reconfirm_denied!(models.pending_space[outcome.row.id])

      expect(cannot_leave.notices.size).to eq(1)
    end

    it "records the decision at once even with no live adapter (the dashboard process), and defers the platform action" do
      svc = described_class.new(models: models, authorization: authorization, scheduler: scheduler,
                                adapters: {}, clock: clock, logger: Rubotty::Log.null)
      outcome = svc.on_join!(adapter: :telegram, account: "bot", external_id: "-4", name: "Dashboard Deny")
      result = svc.deny(id: outcome.row.id, admin: "dashboard:administrator")

      expect(result.status).to eq(:denied)
      row = models.pending_space[outcome.row.id]
      expect(row.state).to eq("denied") # decided immediately
      expect(row.left_at).to be_nil     # but not yet actually carried out here
      expect(scheduler.pending).to be >= 1 # a job is durably queued for whichever process IS live
    end

    it "is :not_pending for an already-decided row" do
      outcome = join
      service.deny(id: outcome.row.id, admin: "test")
      result = service.deny(id: outcome.row.id, admin: "test")
      expect(result.status).to eq(:not_pending)
    end

    # ProtectedCommunities is documented as a whitelist the dashboard can never
    # override, so a misclicked Deny on a row that happens to be protected must
    # not actually leave, the same guard #expire already holds.
    it "records the denial but never leaves a space whose title is protected" do
      outcome = service.on_join!(adapter: :telegram, account: "bot", external_id: "-100999999",
                                 name: "SAMPLE - General")
      result = service.deny(id: outcome.row.id, admin: "dashboard:administrator")

      expect(result.status).to eq(:denied)
      expect(adapter.left).to be_empty
      row = models.pending_space[outcome.row.id]
      expect(row.state).to eq("denied")
      expect(row.left_at).to be_nil
    end

    # The deny guard above only closes the dashboard's own button. #on_join!
    # answers a re-add of a DENIED row with action: :leave, and every adapter
    # hands that straight to #reconfirm_denied!, which needs the same guard or
    # the next re-add makes the bot actually leave a protected space.
    it "never leaves a protected space handed back through reconfirm_denied! after a deny" do
      outcome = service.on_join!(adapter: :telegram, account: "bot", external_id: "-100999998",
                                 name: "SAMPLE - General")
      service.deny(id: outcome.row.id, admin: "test")

      service.reconfirm_denied!(models.pending_space[outcome.row.id])

      expect(adapter.left).to be_empty
      expect(adapter.notices).to be_empty
    end
  end

  describe "the soft, clearable blacklist" do
    it "re-adding a denied space does not create a new pending row" do
      outcome = join
      service.deny(id: outcome.row.id, admin: "test")

      again = join
      expect(again.leave?).to be(true)
      expect(models.pending_space.where(external_id: "-100555").count).to eq(1)
      expect(models.pending_space[outcome.row.id].state).to eq("denied")
    end

    it "#clear removes a denied entry so a future join is reviewed again" do
      outcome = join
      service.deny(id: outcome.row.id, admin: "test")
      expect(service.clear(id: outcome.row.id)).to be(true)
      expect(models.pending_space[outcome.row.id]).to be_nil

      fresh = join
      expect(fresh.pending?).to be(true)
    end

    it "#clear refuses a row that is not denied" do
      outcome = join
      expect(service.clear(id: outcome.row.id)).to be(false)
      expect(models.pending_space[outcome.row.id]).not_to be_nil
    end
  end

  describe "the durable auto-leave timer" do
    it "leaves and denies a still-pending space once its window expires" do
      outcome = join
      advance(1801)
      ran = scheduler.run_due
      expect(ran).to eq(1)

      expect(adapter.left.size).to eq(1)
      row = models.pending_space[outcome.row.id]
      expect(row.state).to eq("denied")
      expect(row.decided_by).to eq("auto-expired")
      expect(row.left_at).not_to be_nil
    end

    it "never leaves a space approved before the timer fires" do
      outcome = join
      service.approve(id: outcome.row.id, admin: "test", new_community_name: "Rando")
      advance(1801)
      scheduler.run_due

      expect(adapter.left).to be_empty
      expect(models.pending_space[outcome.row.id].state).to eq("approved")
    end

    it "is idempotent: running the handler again on an already-settled row does nothing further" do
      outcome = join
      advance(1801)
      scheduler.run_due
      # A stale duplicate of the same job must not leave twice.
      service.expire(fake_job(outcome.row.id))
      expect(adapter.left.size).to eq(1)
    end

    it "survives a simulated restart: a fresh session recovers and leaves the lapsed pending space" do
      outcome = join
      advance(1801)

      fresh = Rubotty::Core::DurableScheduler.new(
        store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s2",
        clock: clock, logger: Rubotty::Log.null
      )
      fresh.register(described_class::EXPIRE_KIND) { |job| service.expire(job) }
      fresh.recover(alive_session_ids: ["s2"], now: clock.call)

      expect(adapter.left.size).to eq(1)
      row = models.pending_space[outcome.row.id]
      expect(row.state).to eq("denied")
    end

    def fake_job(pending_space_id)
      Struct.new(:payload).new({ "pending_space_id" => pending_space_id })
    end
  end
end
