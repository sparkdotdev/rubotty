# frozen_string_literal: true

require "spec_helper"

# The operator startup DM: orthogonal to the room banner, its own
# per-community switch, sharing the banner's suppression claim rather than
# keeping a second one.
RSpec.describe Rubotty::Core::Runtime, "operator startup DM", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def build_runtime(store:, logger: Rubotty::Log.null, env: ControlPlaneHelpers::CONFIG_ENV)
    described_class.new(config: config, logger: logger, storage: store, env: env).build
  end

  # Every community's feature toggle lives in feature_settings; "all" is the
  # community-wide selector, exactly as the room banner's own switch works.
  def enable_feature(store, runtime, feature:, slugs: nil)
    models = build_models(store.db)
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    models.community.all.each do |row|
      next if slugs && !slugs.include?(row.slug)

      controls.enable(community: row, selector: "all", feature: feature)
    end
    runtime.registry.reload
  end

  # Record every room-banner post without delivering.
  def capture_posts(runtime)
    posted = []
    allow(runtime.ephemeral).to receive(:post) do |endpoints:, **_rest|
      posted << endpoints.map(&:id)
      instance_double(Rubotty::Core::EphemeralMessage::Group, any?: false, delete_now: nil, id: "stub-room-group")
    end
    posted
  end

  # Record every operator-DM post without delivering. +copies+ controls what
  # the stubbed Group reports back landed, so a test can simulate every
  # target refusing the ephemeral DM, "cannot be made ephemeral so it is
  # not sent", without a real adapter in the loop.
  def capture_dms(runtime, copies: 1)
    posted = []
    allow(runtime.ephemeral).to receive(:post_dm) do |targets:, delete_after:, **_rest|
      posted << { native_ids: targets.map(&:native_id), delete_after: delete_after }
      instance_double(
        Rubotty::Core::EphemeralMessage::Group,
        any?: copies.positive?, delete_now: nil, copies: Array.new(copies) { double("copy") }, id: "stub-dm-group"
      )
    end
    posted
  end

  describe "the per-community switch" do
    it "is a known feature, off by default, independent of the room banner" do
      expect(Rubotty::Features::Catalog.known?("operator_startup_dm")).to be(true)
      expect(Rubotty::Features::OperatorStartupDm.default_enabled?).to be(false)
    end

    it "posts nothing until a community turns it on" do
      store = sequel_store
      runtime = build_runtime(store: store)
      posted = capture_dms(runtime)
      capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(posted).to be_empty
    end

    it "DMs the operators without posting the room banner, when only this switch is on" do
      store = sequel_store
      runtime = build_runtime(store: store)
      enable_feature(store, runtime, feature: "operator_startup_dm")
      dms = capture_dms(runtime)
      banners = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(dms.size).to eq(1)
      expect(dms.first[:native_ids]).to contain_exactly("80000012", "80000000000000013")
      expect(banners).to be_empty
    end

    it "posts the room banner without DMing anyone, when only that switch is on" do
      store = sequel_store
      runtime = build_runtime(store: store)
      enable_feature(store, runtime, feature: "startup_banner")
      dms = capture_dms(runtime)
      banners = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(banners.size).to eq(1)
      expect(dms).to be_empty
    end

    it "does both from the same restart when both switches are on" do
      store = sequel_store
      runtime = build_runtime(store: store)
      enable_feature(store, runtime, feature: "startup_banner")
      enable_feature(store, runtime, feature: "operator_startup_dm")
      dms = capture_dms(runtime)
      banners = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(banners.size).to eq(1)
      expect(dms.size).to eq(1)
    end
  end

  describe "the DM's lifetime" do
    it "multiplies announce_delete_after by OPERATOR_DM_DELETE_MULTIPLIER rather than reusing the room banner delay" do
      store = sequel_store
      runtime = build_runtime(store: store)
      enable_feature(store, runtime, feature: "operator_startup_dm")
      dms = capture_dms(runtime)

      runtime.send(:announce_startup)

      expected = config.announce_delete_after * Rubotty::Core::Runtime::OPERATOR_DM_DELETE_MULTIPLIER
      expect(dms.first[:delete_after]).to eq(expected)
      expect(Rubotty::Core::Runtime::OPERATOR_DM_DELETE_MULTIPLIER).to eq(3)
    end
  end

  describe "shared suppression with the room banner" do
    it "suppresses the DM under the SAME claim a pre-existing banner suppression already made" do
      store = sequel_store
      runtime = build_runtime(store: store)
      enable_feature(store, runtime, feature: "operator_startup_dm")

      # As if the room banner (or a previous boot with both switches on) had
      # already claimed this community's suppression record this build.
      Rubotty::Core::Announcement::Suppressor.new(
        storage: store, window: config.announce_suppress_window,
        version: "#{Rubotty::VERSION}+#{Rubotty::Core::BuildInfo.commit}", scope: "sample"
      ).claim
      dms = capture_dms(runtime)
      capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(dms).to be_empty
    end

    it "posts both, then suppresses both on an immediate re-announce, from one claim" do
      store = sequel_store
      runtime = build_runtime(store: store)
      enable_feature(store, runtime, feature: "startup_banner")
      enable_feature(store, runtime, feature: "operator_startup_dm")
      dms = capture_dms(runtime)
      banners = capture_posts(runtime)

      runtime.send(:announce_startup)
      expect(dms.size).to eq(1)
      expect(banners.size).to eq(1)

      dms.clear
      banners.clear
      runtime.send(:announce_startup)

      expect(dms).to be_empty
      expect(banners).to be_empty
    end
  end

  describe "an operator reachable nowhere" do
    it "logs and skips rather than posting to nobody" do
      io = StringIO.new
      store = sequel_store
      runtime = build_runtime(store: store, logger: Rubotty::Log.build(level: "info", io: io))
      enable_feature(store, runtime, feature: "operator_startup_dm")
      models = build_models(store.db)
      # Reachable nowhere means exactly that. Dropping the grants alone no
      # longer empties the audience: the deployment-configured floor is owner-level here
      # whether or not a row says so, and it resolves through the platform
      # accounts on file, so those have to go with them.
      community = models.community.first
      models.operator.where(community_id: community.id).delete
      models.person_identity.where(community_id: community.id).delete
      dms = capture_dms(runtime)

      runtime.send(:announce_startup)

      expect(dms).to be_empty
      expect(io.string).to include("no operator reachable by DM, skipping the startup DM")
    end
  end

  describe "an operator reachable only where a DM cannot be made ephemeral" do
    # Simulated by the ephemeral primitive itself refusing every target,
    # "cannot be made ephemeral so it is not sent", which is exactly what
    # EphemeralMessage#post_dm does for real when an adapter answers false
    # to #supports_admin_dm_delete?.
    it "logs and posts nothing, rather than sending a DM that would never go away" do
      io = StringIO.new
      store = sequel_store
      runtime = build_runtime(store: store, logger: Rubotty::Log.build(level: "info", io: io))
      enable_feature(store, runtime, feature: "operator_startup_dm")
      capture_dms(runtime, copies: 0)

      runtime.send(:announce_startup)

      expect(io.string).to include("no operator reachable by an ephemeral admin DM, skipping the startup DM")
    end
  end
end
