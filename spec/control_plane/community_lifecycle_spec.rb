# frozen_string_literal: true

require "spec_helper"

# Starting and stopping the bot in a community. These know nothing about
# messages or adapters, only rows and the live Registry.
RSpec.describe Rubotty::ControlPlane::CommunityLifecycle, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:community) { models.community.where(slug: "sample").first }

  let(:now) { Time.new(2026, 7, 23, 12, 0, 0) }

  subject(:lifecycle) do
    described_class.new(models: models, registry: registry, logger: Rubotty::Log.null, clock: -> { now })
  end

  # Whether the Snapshot resolves this channel's inbound address is the test of
  # whether the community is started.
  let(:a_channel) { models.channel.where(community_id: community.id).order(:id).first }

  describe "#stop" do
    it "sets the community status to suspended and bumps updated_at" do
      result = lifecycle.stop(community: community)

      expect(result.status).to eq(:stopped)
      expect(result.stopped?).to be(true)
      expect(result.changed?).to be(true)
      community.refresh
      expect(community.status).to eq("suspended")
      expect(community.updated_at).to be_within(1).of(now)
    end

    it "reloads the Snapshot so the community's channels stop resolving" do
      expect(registry.current.resolve(a_channel.adapter, a_channel.account, a_channel.route_key)).not_to be_nil

      lifecycle.stop(community: community)

      expect(registry.current.resolve(a_channel.adapter, a_channel.account, a_channel.route_key)).to be_nil
    end

    it "leaves the community queryable by slug after stopping, so it can be restarted" do
      lifecycle.stop(community: community)
      expect(registry.current.community("sample")).not_to be_nil
    end

    it "is idempotent: stopping an already-suspended community is a no-op" do
      lifecycle.stop(community: community)
      again = lifecycle.stop(community: community.refresh)

      expect(again.status).to eq(:already_suspended)
      expect(again.already_suspended?).to be(true)
      expect(again.changed?).to be(false)
    end
  end

  describe "#start" do
    it "sets a suspended community back to active and its channels resolve again" do
      lifecycle.stop(community: community)
      expect(registry.current.resolve(a_channel.adapter, a_channel.account, a_channel.route_key)).to be_nil

      result = lifecycle.start(community: community.refresh)

      expect(result.status).to eq(:started)
      expect(result.started?).to be(true)
      expect(community.refresh.status).to eq("active")
      expect(registry.current.resolve(a_channel.adapter, a_channel.account, a_channel.route_key)).not_to be_nil
    end

    it "is idempotent: starting an already-active community is a no-op" do
      result = lifecycle.start(community: community)

      expect(result.status).to eq(:already_active)
      expect(result.already_active?).to be(true)
      expect(result.changed?).to be(false)
    end
  end

  describe "resolution" do
    it "finds a community by its operator-assigned slug" do
      expect(lifecycle.community!("sample").id).to eq(community.id)
      expect(lifecycle.find_by_slug("sample").id).to eq(community.id)
    end

    it "raises Invalid with a clear message for an unknown slug" do
      expect { lifecycle.community!("nope") }
        .to raise_error(described_class::Invalid, /no community with slug "nope"/)
    end

    it "returns nil from find_by_slug for an unknown slug" do
      expect(lifecycle.find_by_slug("nope")).to be_nil
    end

    it "finds the community owning a coarse platform space (in-context resolution)" do
      connection = models.platform_connection.where(community_id: community.id).first
      found = lifecycle.community_for_space(
        adapter: connection.adapter, account: connection.account, external_id: connection.external_id
      )
      expect(found&.id).to eq(community.id)
    end

    it "returns nil for a space no community owns" do
      expect(lifecycle.community_for_space(adapter: "telegram", account: "telegram", external_id: "-100999")).to be_nil
    end

    it "reports whether a community is currently started" do
      expect(lifecycle.active?(community)).to be(true)
      lifecycle.stop(community: community)
      expect(lifecycle.active?(community.refresh)).to be(false)
    end
  end

  describe "without a registry" do
    subject(:lifecycle) do
      described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
    end

    it "still writes the status change, only skipping the live reload" do
      result = lifecycle.stop(community: community)
      expect(result.status).to eq(:stopped)
      expect(community.refresh.status).to eq("suspended")
    end
  end
end
