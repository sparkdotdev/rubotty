# frozen_string_literal: true

require "spec_helper"

# The count comes off the durable api_request_log, so the limit survives a
# restart and is deterministic under an injected clock.
RSpec.describe Rubotty::ControlPlane::ApiRateLimiter, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:api_keys) { Rubotty::ControlPlane::ApiKeys.new(models: models, clock: clock) }
  let(:api_key) { api_keys.issue(scope: "developer", community: community, label: "Test key").key_row }

  let(:now) { Time.at(Time.new(2026, 7, 24, 12, 0, 0).to_i) }
  let(:clock) { -> { @now } }
  before { @now = now }

  subject(:limiter) { described_class.new(models: models, max: 3, window_seconds: 15, clock: clock) }

  it "defaults to 60 requests per 60 second window" do
    default_limiter = described_class.new(models: models)
    expect(default_limiter.max).to eq(60)
    expect(default_limiter.window_seconds).to eq(60)
  end

  it "allows requests up to the limit and refuses the one that would exceed it" do
    3.times do
      expect(limiter.allow?(api_key)).to be(true)
      limiter.record!(api_key)
    end
    expect(limiter.allow?(api_key)).to be(false)
  end

  it "allows requests again once the window has passed" do
    3.times { limiter.record!(api_key) }
    expect(limiter.allow?(api_key)).to be(false)

    @now = now + 16
    expect(limiter.allow?(api_key)).to be(true)
  end

  it "limits each key independently" do
    other_key = api_keys.issue(scope: "administrator", label: "Other key").key_row
    3.times { limiter.record!(api_key) }
    expect(limiter.allow?(api_key)).to be(false)
    expect(limiter.allow?(other_key)).to be(true)
  end

  it "reports the whole window as the retry-after value" do
    expect(limiter.retry_after).to eq(15)
  end

  describe "#record!" do
    it "writes one durable row per call, surviving past this process" do
      expect { limiter.record!(api_key) }
        .to change { models.api_request_log.where(api_key_id: api_key.id).count }.by(1)
    end
  end

  describe "#prune" do
    it "removes rows older than the given instant and keeps newer ones" do
      @now = now
      limiter.record!(api_key)
      @now = now + 3600
      limiter.record!(api_key)

      removed = limiter.prune(older_than: now + 1)

      expect(removed).to eq(1)
      expect(models.api_request_log.where(api_key_id: api_key.id).count).to eq(1)
      expect(models.api_request_log.first.created_at.to_i).to eq((now + 3600).to_i)
    end

    it "is a no-op when nothing is old enough to prune" do
      limiter.record!(api_key)
      expect(limiter.prune(older_than: now - 1)).to eq(0)
      expect(models.api_request_log.count).to eq(1)
    end
  end
end

# Every API request leaves a durable row behind, so something has to delete
# them or the table grows without bound wherever the API is served.
RSpec.describe Rubotty::Core::Runtime, "pruning the API request log", :control_plane do
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

  it "builds a limiter to prune with, since only this process has a purge tick" do
    expect(runtime.instance_variable_get(:@api_rate_limiter))
      .to be_a(Rubotty::ControlPlane::ApiRateLimiter)
  end

  it "drops a row older than the retention and keeps a recent one" do
    models = runtime.send(:control_plane_models)
    issued = Rubotty::ControlPlane::ApiKeys.new(models: models).issue(scope: "administrator", label: "k")
    row = issued.key_row
    retention = described_class::API_REQUEST_LOG_RETENTION
    models.api_request_log.create(api_key_id: row.id, created_at: Time.now - retention - 60)
    models.api_request_log.create(api_key_id: row.id, created_at: Time.now)

    runtime.send(:prune_api_request_log)

    expect(models.api_request_log.count).to eq(1)
  end

  it "keeps far more than the limiter's own window, so a prune never refunds a budget" do
    expect(described_class::API_REQUEST_LOG_RETENTION)
      .to be > Rubotty::ControlPlane::ApiRateLimiter::DEFAULT_WINDOW_SECONDS
  end
end
