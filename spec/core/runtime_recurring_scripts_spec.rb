# frozen_string_literal: true

require "spec_helper"

# The schedule is rebuilt from scratch at every boot, forgetting every recurring
# wake for the WHOLE deployment first, so a single unusable row can cost every
# other community its scripts.
RSpec.describe Rubotty::Core::Runtime, "recurring script wakes", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  let(:runtime) do
    described_class.new(config: config, logger: Rubotty::Log.null, storage: sequel_store,
                        env: ControlPlaneHelpers::CONFIG_ENV).build
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }

  # The runtime's own scripts service has no smoke test behind it, so saving and
  # switching one on here goes through a service of its own over the SAME tables.
  let(:scripts) do
    Rubotty::ControlPlane::Scripts.new(
      models: runtime.send(:control_plane_models), logger: Rubotty::Log.null,
      smoke_test: Rubotty::Scripting::SmokeTest.new(pool: pool, logger: Rubotty::Log.null, timeout: SMOKE_TEST_SPEC_TIMEOUT)
    )
  end

  let(:scheduler) { runtime.instance_variable_get(:@durable_scheduler) }
  let(:community) { runtime.registry.current.communities.first }

  def live(name:, config:)
    row = scripts.save(community: community, name: name, kind: "processor",
                       source: 'return { action = "allow", reply = "the digest" }',
                       trigger_type: "recurring", trigger_config: config)
    scripts.verify(community, row.id)
    scripts.enable(community, row.id)
  end

  # Read straight from the table, since the store only claims and counts.
  def wakes
    jobs = scheduler.instance_variable_get(:@store).instance_variable_get(:@db)[:scheduled_jobs]
    jobs.where(kind: Rubotty::Features::Scripts::RECURRING_KIND).all.map do |row|
      JSON.parse(row[:payload].to_s)
    rescue StandardError
      {}
    end
  end

  before { skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil? }

  after do
    pool.close
    runtime.instance_variable_get(:@control_watcher)&.stop
  end

  # Regression for the gap where a script created or edited from the
  # dashboard after boot never got a durable wake until the whole process
  # restarted: nothing rebuilt the recurring schedule again once boot's own
  # call to {Rubotty::Core::Runtime#sync_recurring_scripts} had run.
  it "resyncs a live edit without a restart, once the control watcher is up" do
    runtime.send(:start_control_watcher)
    live(name: "digest", config: { "every" => "day", "at" => "09:00" })

    runtime.instance_variable_get(:@control_watcher).tick

    expect(wakes.length).to eq(1)
  end

  it "schedules one for a live recurring script" do
    live(name: "digest", config: { "every" => "day", "at" => "09:00" })
    runtime.send(:sync_recurring_scripts)

    expect(wakes.length).to eq(1)
  end

  # The room poster looks the key up, and an empty one matches nothing.
  it "names a room to wake in, rather than an empty key" do
    live(name: "digest", config: { "every" => "day", "at" => "09:00" })
    runtime.send(:sync_recurring_scripts)

    expect(wakes.first["room_key"].to_s).not_to be_empty
  end

  it "names the script, so the wake knows what to run" do
    live(name: "digest", config: { "every" => "day", "at" => "09:00" })
    runtime.send(:sync_recurring_scripts)

    expect(wakes.first["script"]).to eq("digest")
  end

  it "schedules nothing for a script that is switched off" do
    row = scripts.save(community: community, name: "digest", kind: "processor",
                       source: 'return { action = "allow" }', trigger_type: "recurring",
                       trigger_config: { "every" => "day" })
    scripts.verify(community, row.id)
    runtime.send(:sync_recurring_scripts)

    expect(wakes).to be_empty
  end

  it "schedules nothing for a live script woken by messages instead" do
    row = scripts.save(community: community, name: "guard", kind: "processor",
                       source: 'return { action = "allow" }', trigger_type: "always")
    scripts.verify(community, row.id)
    scripts.enable(community, row.id)
    runtime.send(:sync_recurring_scripts)

    expect(wakes).to be_empty
  end

  it "rebuilds rather than piling up, so booting twice leaves one wake" do
    live(name: "digest", config: { "every" => "day", "at" => "09:00" })
    3.times { runtime.send(:sync_recurring_scripts) }

    expect(wakes.length).to eq(1)
  end

  # A stored row with an hour of 25 predates the check that now refuses it, and
  # one of those used to take every other script down with it.
  it "keeps the others when one script cannot be scheduled" do
    live(name: "good", config: { "every" => "day", "at" => "09:00" })
    broken = scripts.save(community: community, name: "broken", kind: "processor",
                          source: 'return { action = "allow" }', trigger_type: "recurring",
                          trigger_config: { "every" => "day" })
    scripts.verify(community, broken.id)
    scripts.enable(community, broken.id)
    # Written straight past the check, the way an older row reached the table.
    broken.update(trigger_config: Rubotty::ControlPlane::Models.dump_json(
      { "every" => "day", "at" => "25:00" }
    ))

    runtime.send(:sync_recurring_scripts)

    expect(wakes.map { |payload| payload["script"] }).to include("good")
  end
end
