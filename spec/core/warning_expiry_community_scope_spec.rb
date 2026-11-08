# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Issue #1779, the sibling of the announcement hole in #1778 and of the leak in
# #1767, with a moderation reversal on the end instead of a post: the expiry
# handler resolved the payload's endpoint ids against the merged topology and
# unbanned or unmuted on whatever came back, never reading the job's community.
module WarningExpiryCommunityScopeSupport
end

RSpec.describe Rubotty::Core::Warnings::Service, "reversing a sanction only inside the job's community" do
  let(:snapshot) { colliding_snapshot }
  let(:registry) { colliding_registry(snapshot) }
  let(:topo) { snapshot.topology }

  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot") }
  let(:adapters) { Hash.new(adapter) }

  # Every reversal the handler performs, as the endpoint it landed on.
  def reversed = adapter.moderations.map { |m| m[:endpoint_id] }

  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "s", logger: Rubotty::Log.null)
  end

  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "info", io: logs) }

  subject(:service) do
    described_class.new(
      store: Rubotty::Core::WarningsStore.for(Rubotty::Storage::Memory.new, logger: Rubotty::Log.null),
      scheduler: scheduler, topology: topo, adapters: adapters,
      registry: registry, logger: logger
    )
  end

  WarningExpiryCommunityScopeSupport::Job = Struct.new(:id, :community, :payload, keyword_init: true)

  def expire(community, endpoints)
    service.expire(WarningExpiryCommunityScopeSupport::Job.new(
                     id: 7, community: community,
                     payload: { "action" => "ban", "community" => community,
                                "native_id" => "55", "endpoints" => endpoints }
                   ))
  end

  it "reverses on beta's own endpoint" do
    expire("beta", %w[beta-telegram])

    expect(reversed).to eq(%w[beta-telegram])
  end

  it "reverses on alpha's own endpoint too, so the other case is not a coincidence" do
    expire("alpha", %w[alpha-telegram])

    expect(reversed).to eq(%w[alpha-telegram])
  end

  it "refuses to lift a sanction on another community's endpoint, loudly" do
    expire("beta", %w[alpha-telegram])

    expect(reversed).to be_empty
    expect(logs.string).to match(/ERROR.*REFUSED.*alpha-telegram.*community 1.*not 2/)
  end

  it "still reverses on its own endpoint when the payload also names a foreign one" do
    expire("beta", %w[alpha-telegram beta-telegram])

    expect(reversed).to eq(%w[beta-telegram])
  end

  it "reverses nothing for a job whose slug names no live community" do
    expire("ghost", %w[alpha-telegram])

    expect(reversed).to be_empty
    expect(logs.string).to match(/names no live community/)
  end

  # One community and nothing to cross into: the config-file path is unchanged.
  it "reverses as before with no registry to scope by" do
    plain = described_class.new(
      store: Rubotty::Core::WarningsStore.for(Rubotty::Storage::Memory.new, logger: Rubotty::Log.null),
      scheduler: scheduler, topology: topo, adapters: adapters, logger: Rubotty::Log.null
    )
    plain.expire(WarningExpiryCommunityScopeSupport::Job.new(id: 7, community: "alpha",
                         payload: { "action" => "ban", "community" => "alpha",
                                    "native_id" => "55", "endpoints" => %w[alpha-telegram] }))

    expect(reversed).to eq(%w[alpha-telegram])
  end
end
