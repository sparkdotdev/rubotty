# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rubotty/storage/schema"

# The Analytics message-volume panel showed 0 relayed messages for a community
# that was relaying every day. Earlier tests seeded relay_claims by hand, so
# they only proved the reader agreed with the fixture, not with what the real
# bridge writes; nothing here hand-seeds a claim.
RSpec.describe "analytics message volume over the real relay path", :control_plane do
  let(:model) { sample_model }
  let(:seeded) { seeded_sample(slug: "sample") }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts) }
  let(:adapter) { Fakes::RecordingAdapter.new }

  # The bot half: the message map on the same database the dashboard reads, as
  # the deployment runs it.
  let(:storage) do
    Rubotty::Storage::SequelStore.new(db: db, logger: Rubotty::Log.null).migrate!
  end

  # The dashboard half, built exactly as Deps builds it.
  let(:analytics) { Rubotty::ControlPlane::Analytics.new(db: db, models: models) }
  let(:community) { models.community.where(slug: "sample").first }

  subject(:router) do
    Rubotty::Core::Router.new(
      topology: registry.current.topology,
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      ttl: 3600,
      registry: registry
    )
  end

  def origin(endpoint_key) = registry.current.topology.endpoint(endpoint_key)

  def relay(endpoint_key, native_id:)
    router.handle(message(origin(endpoint_key), text: "hi", native_id: native_id))
  end

  it "counts a message the bridge actually relayed" do
    relay("tg-general", native_id: "e2e-1")
    expect(adapter.delivered.map(&:first)).to eq(["dc-general"])

    expect(analytics.overview(community: community)[:messages]).to include(available: true, total: 1)
  end

  it "counts every relayed message on the cross-community landing row" do
    relay("tg-general", native_id: "e2e-1")
    relay("dc-general", native_id: "e2e-2")
    relay("tg-gaming", native_id: "e2e-3")

    row = analytics.community_rows.find { |candidate| candidate[:community].slug == "sample" }
    expect(row[:messages_recent]).to eq(3)
  end

  it "attributes relayed messages to the originating channel and platform" do
    relay("tg-general", native_id: "e2e-1")
    relay("tg-general", native_id: "e2e-2")
    relay("dc-general", native_id: "e2e-3")

    messages = analytics.overview(community: community)[:messages]
    expect(messages[:by_channel]).to include(label: "tg-general", count: 2)
    expect(messages[:by_channel]).to include(label: "dc-general", count: 1)
    expect(messages[:by_platform]).to include(label: "telegram", count: 2)
    expect(messages[:by_platform]).to include(label: "discord", count: 1)
  end

  # The reader must scope to one community rather than count every claim in the table.
  it "does not attribute one community's relayed messages to another" do
    other = models.community.create(
      slug: "other", name: "Other", status: "active", settings: "{}",
      created_at: Time.now, updated_at: Time.now
    )
    relay("tg-general", native_id: "e2e-1")

    expect(analytics.overview(community: community)[:messages][:total]).to eq(1)
    expect(analytics.overview(community: other)[:messages][:total]).to eq(0)
  end

  # The claim is keyed by the community's row id, which Core::Backfill also looks
  # it up by. The reader has to agree with that key rather than with the slug.
  it "keys the claim the bridge wrote by the community row id" do
    relay("tg-general", native_id: "e2e-1")

    row = db[:relay_claims].where(operation: "new").first
    expect(row[:community]).to eq(community.id.to_s)
  end

  # A room with exactly one endpoint has nothing to fan out to: Room#targets_for
  # answers empty for it by design. The worry was that Features::Bridge only
  # wrote the "new" claim once fan-out found a target, leaving single-platform
  # traffic uncounted; #handle_new actually claims before the fan-out loop runs.
  context "with a single-endpoint room" do
    let(:solo_yaml) do
      <<~YAML
        name: solo platform test
        accounts:
          telegram:
            adapter: telegram
            token_env: TELEGRAM_BOT_TOKEN
        rooms:
          - id: solo
            label: SOLO
            endpoints:
              - id: tg-solo
                adapter: telegram
                account: telegram
                chat_id: "-1009999999"
      YAML
    end
    let(:solo_model) { Rubotty::Config::Loader.load_string(solo_yaml, env: ControlPlaneHelpers::CONFIG_ENV) }
    let(:db) { migrated_db }
    let(:models) { build_models(db) }
    let(:community) { models.community.where(slug: "solo").first }
    let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: solo_model.accounts) }

    before { Rubotty::ControlPlane::Seed.from_model(solo_model, models: models, slug: "solo") }

    it "counts a message with no fan-out target as relayed traffic" do
      relay("tg-solo", native_id: "solo-1")

      expect(adapter.delivered).to be_empty
      expect(analytics.overview(community: community)[:messages]).to include(available: true, total: 1)
    end
  end
end
