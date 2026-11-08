# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Named at the top level on purpose: a constant assigned inside an example
# group lands on Object, which has collided in this suite before.
SanctionJob = Struct.new(:id, :community, :payload, keyword_init: true)

# Issue #1803. WarningsStore lifted a sanction and deactivated a warning by
# bare row id, so the caller that checked the community and the caller that
# did not looked identical. #1817 scoped the endpoints an expiry reverses on
# but left the row write alone, which is why a refused expiry still lifted.
RSpec.describe Rubotty::Core::WarningsStore, "held to one community" do
  let(:db) do
    database = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(database)
    database
  end

  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "info", io: logs) }

  subject(:store) { described_class::Sequel.new(db: db, logger: logger) }

  def sanction_in(slug)
    store.record_sanction(community: slug, adapter: :telegram, subject_native_id: "u1",
                          action: :mute, until_at: Time.now + 3600, endpoints: %w[tg])
  end

  def warning_in(slug)
    store.record_warning(community: slug, adapter: :telegram, subject_native_id: "u1", reason: "spam")
  end

  def sanction_active?(id) = db[:active_sanctions].where(id: id).get(:active)

  def warning_active?(id) = db[:warnings].where(id: id).get(:active)

  describe "a sanction belonging to another community" do
    let!(:beta_sanction) { sanction_in("beta") }

    it "reads as nil, the same answer a bad id gives" do
      expect(store.find_sanction(community: "alpha", id: beta_sanction.id)).to be_nil
      expect(store.find_sanction(community: "alpha", id: 9_999)).to be_nil
    end

    it "still reads for the community that owns it" do
      expect(store.find_sanction(community: "beta", id: beta_sanction.id).id).to eq(beta_sanction.id)
    end

    it "is not lifted, and says so at error level" do
      expect(store.lift_sanction(community: "alpha", id: beta_sanction.id)).to be(false)

      expect(sanction_active?(beta_sanction.id)).to be(true)
      expect(logs.string).to match(/ERROR.*refusing lifting sanction #{beta_sanction.id}/)
    end

    it "is lifted by the community that owns it" do
      expect(store.lift_sanction(community: "beta", id: beta_sanction.id)).to be(true)
      expect(sanction_active?(beta_sanction.id)).to be(false)
    end
  end

  describe "a warning belonging to another community" do
    let!(:beta_warning) { warning_in("beta") }

    it "is not deactivated, and says so at error level" do
      expect(store.deactivate_warning(community: "alpha", id: beta_warning.id)).to be(false)

      expect(warning_active?(beta_warning.id)).to be(true)
      expect(logs.string).to match(/ERROR.*refusing deactivating warning #{beta_warning.id}/)
    end

    it "is deactivated by the community that owns it" do
      expect(store.deactivate_warning(community: "beta", id: beta_warning.id)).to be(true)
      expect(warning_active?(beta_warning.id)).to be(false)
    end

    # An already-cleared warning is an ordinary at-least-once retry, so it must
    # not be reported as a tenancy refusal.
    it "logs nothing when the same community clears one twice" do
      store.deactivate_warning(community: "beta", id: beta_warning.id)
      logs.truncate(logs.rewind)

      expect(store.deactivate_warning(community: "beta", id: beta_warning.id)).to be(false)
      expect(logs.string).not_to include("refusing")
    end
  end
end

# The expiry handler is where a bare sanction id actually reached the store in
# production, straight off the job payload with nothing checked.
RSpec.describe Rubotty::Core::Warnings::Service, "lifting only its own community's sanction" do
  let(:snapshot) { colliding_snapshot }
  let(:registry) { colliding_registry(snapshot) }

  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot") }
  let(:adapters) { Hash.new(adapter) }

  let(:db) do
    database = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(database)
    database
  end

  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "info", io: logs) }
  let(:store) { Rubotty::Core::WarningsStore::Sequel.new(db: db, logger: logger) }

  let(:scheduler_db) { Sequel.sqlite }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: scheduler_db),
      session_id: "s", logger: Rubotty::Log.null
    )
  end

  subject(:service) do
    described_class.new(store: store, scheduler: scheduler, topology: snapshot.topology,
                        adapters: adapters, registry: registry, logger: logger)
  end

  let!(:beta_sanction) do
    store.record_sanction(community: "beta", adapter: :telegram, subject_native_id: "55",
                          action: :ban, until_at: Time.now + 3600, endpoints: %w[beta-telegram])
  end

  def expire(slug, endpoints, sanction_id)
    service.expire(SanctionJob.new(
                     id: 7, community: slug,
                     payload: { "action" => "ban", "community" => slug, "native_id" => "55",
                                "endpoints" => endpoints, "sanction_id" => sanction_id }
                   ))
  end

  def sanction_active?(id) = db[:active_sanctions].where(id: id).get(:active)

  it "lifts its own community's sanction when the reversal runs" do
    expire("beta", %w[beta-telegram], beta_sanction.id)

    expect(sanction_active?(beta_sanction.id)).to be(false)
    expect(adapter.moderations.map { |m| m[:endpoint_id] }).to eq(%w[beta-telegram])
  end

  it "does not lift a sanction belonging to another community" do
    expire("alpha", %w[alpha-telegram], beta_sanction.id)

    expect(sanction_active?(beta_sanction.id)).to be(true)
    expect(logs.string).to match(/refusing lifting sanction #{beta_sanction.id}/)
  end

  # The half #1817 left open: it refused every endpoint and then fell through
  # to the lift regardless, so the row read as served while nothing was.
  it "lifts nothing for a job whose slug names no live community" do
    expire("ghost", %w[beta-telegram], beta_sanction.id)

    expect(sanction_active?(beta_sanction.id)).to be(true)
    expect(adapter.moderations).to be_empty
    expect(logs.string).to match(/names no live community/)
  end
end
