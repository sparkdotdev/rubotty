# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "time"

RSpec.describe Rubotty::Core::AnnouncementScheduler, :control_plane do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:topo) { topology(room("r", tg, dc)) }

  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "s", logger: Rubotty::Log.null)
  end
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(adapters: adapters, session_id: "s", topology: topo, logger: Rubotty::Log.null)
  end

  let(:base) { Time.at(1_800_000_000) } # a fixed, epoch-aligned-friendly instant
  let(:clock) { -> { base } }

  subject(:service) do
    described_class.new(scheduler: scheduler, ephemeral: ephemeral, topology: topo, logger: Rubotty::Log.null, clock: clock)
  end

  before { Rubotty::ControlPlane::Migrator.run(db) }

  def jobs = db[:scheduled_jobs].where(kind: "announcement").all

  it "registers its job kind on the durable scheduler when constructed" do
    service
    expect(scheduler.handler?("announcement")).to be(true)
  end

  describe "a one-shot announcement" do
    it "schedules a future one-shot and posts it to its channels once due" do
      service.reconcile(community: "acme", announcements: [{ text: "hello world", channels: %w[tg], at: (base + 100).iso8601 }])
      expect(scheduler.pending).to eq(1)

      scheduler.run_due(now: base + 50)
      expect(adapter.delivered).to be_empty

      scheduler.run_due(now: base + 101)
      expect(adapter.delivered_to("tg").last.body.text).to eq("hello world")
      expect(scheduler.pending).to eq(0)
    end

    it "skips a one-shot whose time has already passed" do
      service.reconcile(community: "acme", announcements: [{ text: "stale", channels: %w[tg], at: (base - 100).iso8601 }])
      expect(scheduler.pending).to eq(0)
    end
  end

  describe "a recurring announcement" do
    let(:entry) { { text: "read the rules", channels: %w[tg dc], every: "1h" } }

    it "anchors the first run to the fixed epoch grid, not to now + interval" do
      service.reconcile(community: "acme", announcements: [entry])
      row = jobs.first
      expect(row[:recurrence]).to eq("3600")
      expect(row[:run_at].to_i % 3600).to eq(0)      # aligned to an hour boundary
      expect(row[:run_at].to_i).to be > base.to_i    # strictly in the future
    end

    it "posts to every channel and reschedules itself for the next slot" do
      service.reconcile(community: "acme", announcements: [entry])
      first_run = jobs.first[:run_at]

      scheduler.run_due(now: first_run + 1)
      expect(adapter.delivered_to("tg").last.body.text).to eq("read the rules")
      expect(adapter.delivered_to("dc").last.body.text).to eq("read the rules")

      expect(scheduler.pending).to eq(1)
      expect(jobs.first[:run_at].to_i).to eq(first_run.to_i + 3600)
    end

    it "is idempotent: reconciling again clears and recreates, never duplicating" do
      service.reconcile(community: "acme", announcements: [entry])
      service.reconcile(community: "acme", announcements: [entry])
      expect(scheduler.pending).to eq(1)
    end

    it "leaves another community's jobs alone when reconciling one" do
      service.reconcile(community: "one", announcements: [entry])
      service.reconcile(community: "two", announcements: [entry])
      service.reconcile(community: "one", announcements: [entry])
      expect(db[:scheduled_jobs].where(kind: "announcement").count).to eq(2)
    end
  end

  describe "malformed and unresolvable entries" do
    it "drops entries with no text, no channels, or neither a time nor an interval" do
      service.reconcile(community: "acme", announcements: [
        { channels: %w[tg], every: "1h" },
        { text: "no target", every: "1h" },
        { text: "no schedule", channels: %w[tg] }
      ])
      expect(scheduler.pending).to eq(0)
    end

    it "schedules an entry whose channel is unknown, but posts nothing when it fires" do
      service.reconcile(community: "acme", announcements: [{ text: "ghost", channels: %w[nope], every: "1h" }])
      scheduler.run_due(now: jobs.first[:run_at] + 1)
      expect(adapter.delivered).to be_empty
    end
  end

  describe "#reconcile_snapshot" do
    def community(slug:, enabled:, announcements: [])
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: 1, route_key: tg.id)
      Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: slug, name: slug, status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg)]), channels: [channel],
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "scheduled_announcements", enabled: enabled, config: { announcements: announcements }
          )
        ]
      )
    end

    it "reconciles only the communities that have the feature enabled" do
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [
        community(slug: "on", enabled: true, announcements: [{ text: "hi", channels: %w[tg], every: "1h" }]),
        community(slug: "off", enabled: false, announcements: [{ text: "no", channels: %w[tg], every: "1h" }])
      ])
      reconciled = service.reconcile_snapshot(snapshot)
      expect(reconciled).to eq(1)
      expect(scheduler.pending).to eq(1)
      expect(jobs.first[:community]).to eq("on")
    end

    # A recurring job reschedules itself forever and consults nothing about the
    # feature, so only an explicit forget can ever end one.
    it "cancels a recurring job it already scheduled once the feature is switched off" do
      entry = { text: "hi", channels: %w[tg], every: "1h" }
      snapshot_with = lambda do |enabled|
        Rubotty::ControlPlane::Snapshot.new(
          communities: [community(slug: "acme", enabled: enabled, announcements: [entry])]
        )
      end

      service.reconcile_snapshot(snapshot_with.call(true))
      expect(scheduler.pending).to eq(1)

      reconciled = service.reconcile_snapshot(snapshot_with.call(false))

      expect(reconciled).to eq(0)
      expect(scheduler.pending).to eq(0)
    end

    it "clears the community that was switched off without disturbing one still on" do
      both_on = Rubotty::ControlPlane::Snapshot.new(communities: [
        community(slug: "on", enabled: true, announcements: [{ text: "hi", channels: %w[tg], every: "1h" }]),
        community(slug: "off", enabled: true, announcements: [{ text: "no", channels: %w[tg], every: "1h" }])
      ])
      service.reconcile_snapshot(both_on)
      expect(scheduler.pending).to eq(2)

      service.reconcile_snapshot(Rubotty::ControlPlane::Snapshot.new(communities: [
        community(slug: "on", enabled: true, announcements: [{ text: "hi", channels: %w[tg], every: "1h" }]),
        community(slug: "off", enabled: false, announcements: [{ text: "no", channels: %w[tg], every: "1h" }])
      ]))

      expect(jobs.map { |job| job[:community] }).to eq(["on"])
    end
  end
end
