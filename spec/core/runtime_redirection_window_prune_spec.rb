# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Runtime, "redirection window prune wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def runtime
    described_class.new(config: config, logger: Rubotty::Log.null, storage: sequel_store,
                        env: ControlPlaneHelpers::CONFIG_ENV).build
  end

  def prune_job(built)
    Rubotty::ControlPlane::Boot.db_of(built.storage)[:scheduled_jobs]
      .where(kind: Rubotty::ControlPlane::RedirectionWindow::PRUNE_KIND, status: "pending").first
  end

  it "registers one durable daily prune at UTC midnight" do
    built = runtime
    job = prune_job(built)

    expect(built.durable_scheduler.pending(kind: Rubotty::ControlPlane::RedirectionWindow::PRUNE_KIND)).to eq(1)
    expect(built.durable_scheduler.handler?(Rubotty::ControlPlane::RedirectionWindow::PRUNE_KIND)).to be(true)
    expect(job[:recurrence].to_i).to eq(Rubotty::ControlPlane::RedirectionWindow::PRUNE_INTERVAL)
    expect([job[:run_at].utc.hour, job[:run_at].utc.min, job[:run_at].utc.sec]).to eq([0, 0, 0])
  end

  it "uses the UTC date when finding the next midnight" do
    built = runtime
    local_evening = Time.new(2026, 8, 16, 23, 30, 0, "-05:00")

    expect(built.send(:next_utc_midnight, local_evening)).to eq(Time.utc(2026, 8, 18))
  end

  it "deletes rows which have passed the window" do
    built = runtime
    window = built.instance_variable_get(:@redirection_window)
    community = built.registry.current.communities.first
    window.record(
      community_id: community.id, room_key: "general", endpoint_id: "tg-general", native_id: "expired",
      body: Rubotty::Core::RichText.plain("gone")
    )
    rows = Rubotty::ControlPlane::Boot.db_of(built.storage)[:redirection_window_messages]
    rows.where(native_id: "expired").update(created_at: Time.now - Rubotty::ControlPlane::RedirectionWindow::TTL_SECONDS - 1)

    handler = built.durable_scheduler.instance_variable_get(:@handlers)[
      Rubotty::ControlPlane::RedirectionWindow::PRUNE_KIND
    ]
    handler.call(nil)

    expect(rows.where(native_id: "expired").count).to eq(0)
  end
end
