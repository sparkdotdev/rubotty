# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "time"

# Issue #1778, the sibling of the leak in #1767. A due announcement resolved
# the endpoint ids in its payload against the merged topology and posted to
# whatever came back, without ever checking the community the job carries.
RSpec.describe Rubotty::Core::AnnouncementScheduler, "posting only inside the job's community" do
  let(:snapshot) { colliding_snapshot }
  let(:registry) { colliding_registry(snapshot) }
  let(:topo) { snapshot.topology }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "s", logger: Rubotty::Log.null)
  end
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(adapters: adapters, session_id: "s", topology: topo,
                                        logger: Rubotty::Log.null)
  end

  let(:base) { Time.at(1_800_000_000) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "info", io: logs) }

  subject(:service) do
    described_class.new(scheduler: scheduler, ephemeral: ephemeral, topology: topo,
                        registry: registry, logger: logger, clock: -> { base })
  end

  before { Rubotty::ControlPlane::Migrator.run(db) }

  def announce(community, channels)
    service.reconcile(
      community: community,
      announcements: [{ text: "rules", channels: channels, at: (base + 100).iso8601 }]
    )
    scheduler.run_due(now: base + 101)
  end

  # The whole point of the fixture: both tenants own a room keyed "general", so
  # nothing about the endpoint ids alone says which community a job meant.
  it "posts alpha's announcement to alpha's own endpoints" do
    announce("alpha", %w[alpha-telegram])

    expect(adapter.delivered_to("alpha-telegram").last.body.text).to eq("rules")
  end

  it "posts beta's announcement to beta's own endpoints" do
    announce("beta", %w[beta-telegram])

    expect(adapter.delivered_to("beta-telegram").last.body.text).to eq("rules")
  end

  it "refuses an endpoint of another community, loudly, rather than posting to it" do
    announce("beta", %w[alpha-telegram])

    expect(adapter.delivered).to be_empty
    expect(logs.string).to match(/ERROR.*REFUSED.*alpha-telegram.*community 1.*not 2/)
  end

  # A mixed payload must not lose the endpoints it is entitled to.
  it "still posts to its own endpoint when the payload also names a foreign one" do
    announce("beta", %w[alpha-telegram beta-telegram])

    expect(adapter.delivered_to("beta-telegram").last.body.text).to eq("rules")
    expect(adapter.delivered_to("alpha-telegram")).to be_empty
  end

  it "posts nothing at all for a job whose slug names no live community" do
    announce("ghost", %w[alpha-telegram])

    expect(adapter.delivered).to be_empty
    expect(logs.string).to match(/names no live community/)
  end

  # Without a registry there is one community and nothing to cross into, so the
  # config-file deployment keeps working exactly as before.
  it "posts as before with no registry to scope by" do
    plain = described_class.new(scheduler: scheduler, ephemeral: ephemeral, topology: topo,
                                logger: Rubotty::Log.null, clock: -> { base })
    plain.reconcile(community: "alpha",
                    announcements: [{ text: "rules", channels: %w[alpha-telegram], at: (base + 100).iso8601 }])
    scheduler.run_due(now: base + 101)

    expect(adapter.delivered_to("alpha-telegram").last.body.text).to eq("rules")
  end
end
