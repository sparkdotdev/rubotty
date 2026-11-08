# frozen_string_literal: true

# The control-plane migration contract on a REAL Sequel database, shared by the
# Postgres and MariaDB storage specs. Included with `include_examples` so the
# connection and the drop/restore hooks are shared with any backend-specific
# example a caller adds alongside it.
RSpec.shared_examples "the control-plane migration contract" do |driver, url_env|
  let(:control_tables) do
    %i[communities platform_connections channels rooms room_channels
       people person_identities operators operator_requests feature_settings
       observed_identities]
  end

  # Built exactly the way the app builds it, so the dialect setup (utf8mb4 and the
  # kept TEXT defaults on MariaDB) is exercised here too.
  subject(:db) do
    Rubotty::Storage::Factory.build(
      { driver: driver, url_env: url_env, auto_migrate: false }, env: ENV
    ).db
  end

  # Leave the database as we found it, dropping in the reverse of
  # Transfer::CONTROL_PLANE_TABLES' foreign-key-safe insertion order so a second
  # hand-maintained drop order cannot drift out of sync with it.
  def drop_control_plane(database)
    database.drop_table?(*Rubotty::Storage::Transfer::CONTROL_PLANE_TABLES.reverse)
    database.drop_table?(:schema_info)
  end

  before { drop_control_plane(db) }
  after do
    drop_control_plane(db)
    db.disconnect
  end

  it "applies every table" do
    Rubotty::ControlPlane::Migrator.run(db)
    control_tables.each do |table|
      expect(db.table_exists?(table)).to be(true), "expected #{table} on #{driver}"
    end
    expect(Rubotty::ControlPlane::Migrator.current?(db)).to be(true)
  end

  it "rolls back cleanly" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    control_tables.each { |table| expect(db.table_exists?(table)).to be(false) }
  end

  include_examples "stable grant rollback safety"

  it "seeds and projects an equivalent topology" do
    Rubotty::ControlPlane::Migrator.run(db)
    model = Rubotty::Config::Loader.load_file(
      File.expand_path("../fixtures/control_plane/sample.config.yaml", __dir__),
      env: { "TELEGRAM_BOT_TOKEN" => "tg", "DISCORD_BOT_TOKEN" => "dc" }
    )
    models = Rubotty::ControlPlane.models(db)
    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "sample")
    snapshot = Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts).current

    community = snapshot.community("sample")
    expect(community.channels.size).to eq(16)
    expect(community.rooms.size).to eq(8)
    expect(community.topology.endpoint("dc-general").settings[:webhook]).to eq(:auto)
    expect(community.operators.resolve(:telegram, "80000012")&.name).to eq("sample_owner")
  end

  # The guest endpoint exists ONLY in the snapshot, synthesised from a
  # feature_settings row, so it is the projection step most exposed to how a
  # backend hands back a boolean and a foreign-key id.
  it "synthesises a guest endpoint for a room whose guest access is enabled" do
    Rubotty::ControlPlane::Migrator.run(db)
    model = Rubotty::Config::Loader.load_file(
      File.expand_path("../fixtures/control_plane/sample.config.yaml", __dir__),
      env: { "TELEGRAM_BOT_TOKEN" => "tg", "DISCORD_BOT_TOKEN" => "dc" }
    )
    models = Rubotty::ControlPlane.models(db)
    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "sample")
    community = models.community.where(slug: "sample").first
    room = models.room.where(community_id: community.id, room_key: "general").first

    # Written through the shared operations core, exactly as the Guests tab does.
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    controls.enable(community: community, selector: "general", feature: "guest_portal")
    controls.set(community: community, selector: "general", feature: "guest_portal",
                 key: "who_can_invite", value: "operators")

    # The panel's own reader and the projection must agree on this backend.
    policy = Rubotty::ControlPlane::GuestInvites.new(models: models)
                                                .room_policy(community: community, room: room)
    expect(policy[:allowed]).to be(true)

    guest_key = Rubotty::Adapters::Guest.endpoint_key_for(room.id)
    topology = Rubotty::ControlPlane::SnapshotBuilder.build(models).community("sample").topology
    expect(topology.endpoint(guest_key)).not_to be_nil, "expected a guest endpoint on #{driver}"
    expect(topology.endpoint(guest_key).settings[:room_id]).to eq(room.id)
    expect(topology.endpoints.map(&:id).grep(/\Aguest:/)).to eq([guest_key])

    controls.disable(community: community, selector: "general", feature: "guest_portal")
    after_off = Rubotty::ControlPlane::SnapshotBuilder.build(models).community("sample").topology
    expect(after_off.endpoints.map(&:id).grep(/\Aguest:/)).to be_empty
  end

  # Core::EphemeralStore::Sequel#add must go through Storage::Dialect#upsert:
  # MariaDB's Sequel dataset does not implement an inline ON CONFLICT at all, and
  # the SQLite suite stays green while every durable write raises in production.
  it "records and re-records an ephemeral pending deletion through the dialect seam" do
    Rubotty::ControlPlane::Migrator.run(db)
    store = Rubotty::Core::EphemeralStore::Sequel.new(db: db)
    tg = endpoint("tg", account: "a")
    dc = endpoint("dc", account: "b")
    adapter = Fakes::ReactingAdapter.new
    now = Time.now
    service = Rubotty::Core::EphemeralMessage.new(
      adapters: Hash.new(adapter), session_id: "contract",
      store: store, topology: topology(room("r", tg, dc)),
      logger: Rubotty::Log.null, clock: -> { now }
    )

    # The insert half: one durable row per copy, all under one group.
    group = service.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)
    expect(group.copies.size).to eq(2), "expected both copies to post on #{driver}"
    expect(store.count).to eq(2)
    copy = group.copies.first
    expect(store.group_id_for(endpoint_id: copy.endpoint.id, native_id: copy.native_id))
      .to eq(group.id)

    # The conflict half: the same unique key again, which must update in place.
    store.add(group_id: "regrouped", endpoint_id: copy.endpoint.id, native_id: copy.native_id,
              delete_at: now + 300, session_id: "contract-2", channel: "{}")
    expect(store.count).to eq(2), "expected the upsert to update in place on #{driver}"

    row = store.members("regrouped").first
    expect(row).not_to be_nil, "expected the conflicting row to be updated on #{driver}"
    expect(row.endpoint_id).to eq(copy.endpoint.id)
    expect(row.native_id).to eq(copy.native_id)
    expect(row.session_id).to eq("contract-2")
    expect(row.channel).to eq("{}")

    expect(store.forget("regrouped")).to eq(1)
    expect(store.forget(group.id)).to eq(1)
  end

  # A handler runs outside the drain lock, so what keeps a long one from being
  # reclaimed mid-flight is an UPDATE guarded by the holder's own session id.
  # Whether that guard matches, and how many rows it reports, is per-backend
  # behaviour worth proving on a real connection.
  it "refreshes only the claim its own session still holds" do
    Rubotty::ControlPlane::Migrator.run(db)
    scheduler_store = Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db)
    started = Time.now
    id = scheduler_store.enqueue(kind: "noop", run_at: started)
    scheduler_store.claim_next(now: started, session_id: "s1")
    claimed_at = scheduler_store.find(id).claimed_at

    expect(scheduler_store.touch_claim(id, session_id: "s2", now: started + 300)).to eq(0)
    expect(scheduler_store.find(id).claimed_at.to_i).to eq(claimed_at.to_i)

    expect(scheduler_store.touch_claim(id, session_id: "s1", now: started + 300)).to eq(1)
    refreshed = scheduler_store.find(id)
    expect(refreshed.status).to eq("claimed"), "expected the row still claimed on #{driver}"
    expect(refreshed.claimed_at.to_i).to be > claimed_at.to_i,
                                         "expected the refresh to move claimed_at on #{driver}"

    # MariaDB reports zero rows changed for a write of what is already stored,
    # which must not read as a claim this session has lost.
    expect(scheduler_store.touch_claim(id, session_id: "s1", now: started + 300))
      .to eq(1), "expected an unchanged refresh to still hold the claim on #{driver}"
  end

  # The model call counters are added in the database rather than read, added
  # in Ruby and written back, onto a row keyed by a DATE and three short
  # strings. Both halves are per-backend behaviour worth proving for real.
  it "adds to a model call counter in place rather than losing one to a read" do
    Rubotty::ControlPlane::Migrator.run(db)
    models = Rubotty::ControlPlane.models(db)
    now = Time.now
    community = models.community.create(slug: "contract", name: "Contract", status: "active",
                                        created_at: now, updated_at: now)
    stats = Rubotty::ControlPlane::ModelCallStats.new(models: models)

    3.times { stats.record(community_id: community.id, feature: "content_policy", seconds: 0.3) }
    stats.record(community_id: community.id, feature: "content_policy", seconds: 90.0, failed: true)
    stats.flush

    feature = stats.report(community: community).fetch(:features).first
    expect(feature).to include(calls: 4, failures: 1), "expected every count to land on #{driver}"
    expect(feature[:latency].sum { |row| row[:count] }).to eq(4)
  end

  # A settle write reuses a connection that just sat idle through the
  # scheduler's own handler call, so a database error there is usually a
  # stale pooled connection going away, not a real conflict; proven here
  # against a real connection instead of a double.
  it "recovers a durable job's completion write from a transient database error" do
    Rubotty::ControlPlane::Migrator.run(db)
    scheduler_store = Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db)
    id = scheduler_store.enqueue(kind: "noop", run_at: Time.now)
    scheduler_store.claim_next(now: Time.now, session_id: "s1")

    real_dataset = scheduler_store.send(:dataset)
    failures = 0
    allow(scheduler_store).to receive(:dataset) do
      failures += 1
      raise Sequel::DatabaseError, "Lost connection to MySQL server during query" if failures < 3

      real_dataset
    end

    expect { scheduler_store.complete(id) }.not_to raise_error
    expect(scheduler_store.find(id).status).to eq("done"), "expected the retry to land on #{driver}"
  end
end
