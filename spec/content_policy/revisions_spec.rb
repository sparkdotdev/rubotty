# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ContentPolicy::Revisions, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:community) { seeded[1].community.first }
  let(:source) { endpoint("policy-source") }
  let(:now) { Time.utc(2026, 11, 5, 12) }
  let(:ledger) { described_class.new(db: db, retention: 600, clock: -> { now }) }

  def observe(text, kind: :chat, endpoint: source, native_id: "17", enabled: true)
    ledger.observe(community_id: community.id, enabled: enabled,
      message: message(endpoint, native_id: native_id, text: text, kind: kind))
  end

  def current?(text, endpoint: source, native_id: "17", store: ledger)
    store.current?(community_id: community.id, endpoint_id: endpoint.id, native_id: native_id,
      digest: described_class.digest(text))
  end

  it "keeps the latest edit across store instances and ignores a redelivered original" do
    observe("old text")
    observe("clean edit", kind: :edit)
    observe("old text")
    reopened = described_class.new(db: db, retention: 600, clock: -> { now })

    expect(current?("old text", store: reopened)).to be(false)
    expect(current?("clean edit", store: reopened)).to be(true)
    expect(db[:content_policy_revisions].count).to eq(1)
  end

  it "keeps a delete tombstone even when an old edit arrives afterwards" do
    observe("original")
    observe("", kind: :delete)
    observe("original", kind: :edit)

    expect(current?("original")).to be(false)
    expect(db[:content_policy_revisions].first[:digest]).to be_nil
  end

  it "isolates native IDs by endpoint and community" do
    peer = endpoint("policy-peer")
    other = seeded[1].community.create(slug: "other-policy", name: "Other", status: "active",
      settings: "{}", created_at: now, updated_at: now)
    observe("source text")
    observe("peer text", endpoint: peer)
    ledger.observe(community_id: other.id, message: message(source, native_id: "17", text: "other text"))

    expect(current?("source text")).to be(true)
    expect(current?("peer text", endpoint: peer)).to be(true)
    expect(current?("other text")).to be(false)
  end

  it "stores digests without retaining the message body" do
    observe("private source text")
    row = db[:content_policy_revisions].first

    expect(row[:digest]).to eq(described_class.digest("private source text"))
    expect(row.values.join).not_to include("private source text")
  end

  it "expires reads and prunes only a bounded batch" do
    stub_const("Rubotty::ContentPolicy::Revisions::PRUNE_LIMIT", 2)
    3.times { |id| observe("text", native_id: id.to_s) }
    later = described_class.new(db: db, retention: 600, clock: -> { now + 601 })

    expect(current?("text", native_id: "1", store: later)).to be(false)
    expect(later.prune).to eq(2)
    expect(db[:content_policy_revisions].count).to eq(1)
  end

  it "can track a fresh observation after an old tombstone has expired" do
    observe("", kind: :delete)
    later = described_class.new(db: db, retention: 600, clock: -> { now + 601 })
    later.observe(community_id: community.id, message: message(source, native_id: "17", text: "new"))

    expect(current?("new", store: later)).to be(true)
  end

  it "does not start tracking disabled rooms but still invalidates an existing check" do
    observe("untracked", enabled: false)
    expect(db[:content_policy_revisions].count).to eq(0)
    observe("tracked")
    observe("new clean text", kind: :edit, enabled: false)

    expect(current?("tracked")).to be(false)
  end
end

RSpec.describe "Content policy revision integration", :control_plane do
  class PolicyRevisionScheduler
    attr_reader :jobs
    def initialize = @jobs = []
    def register(*) = nil
    def schedule(**job) = (@jobs << job; @jobs.length)
  end

  class PolicyRevisionClient
    attr_reader :calls
    attr_accessor :on_complete
    def initialize = @calls = 0
    def complete_answer(**)
      @calls += 1
      on_complete&.call
      Rubotty::OpenArc::Client::Answer.new(
        text: '{"matches":[{"name":"policy","confidence":1,"reasoning":"synthetic"}]}',
        finish_reason: "stop", completion_tokens: 10
      )
    end
  end

  PolicyRevisionCommunity = Struct.new(:id, :slug, :name, :rooms) do
    def feature_enabled?(*_args) = true
    def feature_config(*_args) = { entries: [{ name: "policy", description: "synthetic", action: "delete" }] }
    def room_key_of(_channel) = rooms.first.id
    def operators = nil
  end
  PolicyRevisionContext = Struct.new(:message, :community, :channel) do
    def operators = nil
    def command_prefixes = Rubotty::Core::CommandPrefix.new
  end
  PolicyRevisionJob = Struct.new(:payload, :community)

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:source) { endpoint("policy-source") }
  let(:room) { Rubotty::Core::Room.new(id: "policy-room", endpoints: [source]) }
  let(:community) { PolicyRevisionCommunity.new(seeded[1].community.first.id, "policy", "Policy", [room]) }
  let(:registry) { Struct.new(:current).new(Struct.new(:communities).new([community])) }
  let(:scheduler) { PolicyRevisionScheduler.new }
  let(:client) { PolicyRevisionClient.new }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:adapters) { Hash.new(adapter) }
  let(:ledger) { Rubotty::ContentPolicy::Revisions.new(db: db, retention: 600) }
  let(:service) { build_service(ledger) }

  def build_service(revisions)
    Rubotty::ContentPolicy::Service.new(
      registry: registry, scheduler: scheduler, client: client, revisions: revisions,
      adapters: adapters, settings: Struct.new(:configured?).new(true),
      topology: topology(room), storage: Rubotty::Storage::Memory.new,
      ephemeral: Rubotty::Core::EphemeralMessage.new(adapters: adapters, session_id: "policy-spec",
        topology: topology(room), logger: Rubotty::Log.null), logger: Rubotty::Log.null
    )
  end

  def context(text, kind: :chat)
    PolicyRevisionContext.new(message(source, native_id: "17", text: text, kind: kind), community, source.id)
  end

  def run_first(svc = service)
    svc.run(PolicyRevisionJob.new(scheduler.jobs.first[:payload], community.slug))
  end

  it "discards an old violating body after a clean acknowledgement edit, including after restart" do
    service.enqueue(context("original violation"))
    service.enqueue(context("thanks", kind: :edit))
    restarted = build_service(Rubotty::ContentPolicy::Revisions.new(db: db, retention: 600))

    run_first(restarted)

    expect(client.calls).to eq(0)
    expect(adapter.deleted).to be_empty
  end

  it "rechecks after inference so an edit arriving during the request prevents removal" do
    service.enqueue(context("original violation"))
    client.on_complete = -> { service.observe(context("clean edit", kind: :edit).message, community) }

    run_first

    expect(client.calls).to eq(1)
    expect(adapter.deleted).to be_empty
  end

  %i[edit delete].each do |kind|
    it "observes #{kind} before an earlier feature consumes the event" do
      service.enqueue(context("original violation"))
      channel = Struct.new(:community_id).new(community.id)
      snapshot = double("snapshot", channel_by_endpoint_key: channel, community_by_id: community)
      pipeline_registry = Struct.new(:current).new(snapshot)
      halter = Class.new(Rubotty::Features::Base) do
        def self.feature_name = "consume"
        def call(_context) = Rubotty::Features::Outcome.halt([])
      end.new
      pipeline = Rubotty::Features::Pipeline.new(features: [halter], registry: pipeline_registry,
        content_policy_observer: service)

      pipeline.handle(context("/help", kind: kind).message)
      run_first

      expect(client.calls).to eq(0)
      expect(adapter.deleted).to be_empty
    end
  end

  it "still acts on the current revision" do
    service.enqueue(context("current violation"))

    run_first

    expect(client.calls).to eq(1)
    expect(adapter.deleted).to eq([[source.id, "17"]])
  end

  it "suppresses pending decisions when a newer observation could not be persisted" do
    service.enqueue(context("original violation"))
    allow(ledger).to receive(:observe).and_raise(Sequel::DatabaseError, "synthetic outage")

    expect { service.observe(context("clean edit", kind: :edit).message, community) }.not_to raise_error
    run_first

    expect(client.calls).to eq(0)
    expect(adapter.deleted).to be_empty
  end

  it "discards old unversioned jobs after the durable ledger is enabled" do
    service.enqueue(context("current violation"))
    scheduler.jobs.first[:payload].delete("revision")

    run_first

    expect(client.calls).to eq(0)
    expect(adapter.deleted).to be_empty
  end
end
