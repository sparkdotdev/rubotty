# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"

# The dashboard's dependency bundle wires the SAME control-plane services the bot
# uses over one connection. These assert the wiring and the two lookups the app
# leans on.
RSpec.describe Rubotty::Dashboard::Deps, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  subject(:deps) { described_class.new(db: db, logger: Rubotty::Log.null) }

  it "exposes the reused control-plane services, not reimplementations" do
    expect(deps.models).to be_a(Rubotty::ControlPlane::Models)
    expect(deps.feature_controls).to be_a(Rubotty::ControlPlane::FeatureControls)
    expect(deps.lifecycle).to be_a(Rubotty::ControlPlane::CommunityLifecycle)
    expect(deps.operators).to be_a(Rubotty::ControlPlane::OperatorFlow)
    expect(deps.audit).to be_a(Rubotty::Core::AuditLog::Sequel)
    expect(deps.identities).to be_a(Rubotty::ControlPlane::IdentityDirectory)
  end

  it "exposes channel mapping (issues #38, #213), the same service the DM console's map command drives" do
    expect(deps.channel_mapper).to be_a(Rubotty::ControlPlane::ChannelMapper)
  end

  it "exposes manual mute/unmute (issue #164), wired to a real durable scheduler" do
    expect(deps.moderation).to be_a(Rubotty::ControlPlane::ModerationActions)

    community = deps.models.community.where(slug: "sample").first
    record = deps.moderation.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
    expect(record.action).to eq("mute")
    # A dashboard mute schedules its reversal on the SAME scheduled_jobs table a
    # running bot polls, so the row is visible straight off the shared connection.
    expect(db[:scheduled_jobs].where(kind: "expire_sanction").count).to eq(1)
  end

  it "exposes the read-only analytics aggregator (issue #53)" do
    expect(deps.analytics).to be_a(Rubotty::ControlPlane::Analytics)
  end

  it "exposes dashboard action permissions (issues #270, #342)" do
    expect(deps.action_permissions).to be_a(Rubotty::Dashboard::ActionPermissions)
    # Nothing granted until an administrator says so.
    expect(deps.action_permissions.operator_write_actions).to be_empty
    expect(Rubotty::Dashboard::ActionPermissions::ACTIONS).to have_key(:configure_word_filter)
  end

  it "exposes API key issuance (issue #238)" do
    expect(deps.api_keys).to be_a(Rubotty::ControlPlane::ApiKeys)
  end

  it "resolves a community by slug and lists them" do
    expect(deps.community("sample").slug).to eq("sample")
    expect(deps.community("nope")).to be_nil
    expect(deps.communities.map(&:slug)).to include("sample")
  end
end

RSpec.describe Rubotty::Dashboard::App do
  describe ".derive_session_secret" do
    it "derives a stable 128-char secret from the configured env value" do
      one = described_class.derive_session_secret(env: { "S" => "stable" }, name: "S")
      two = described_class.derive_session_secret(env: { "S" => "stable" }, name: "S")
      expect(one).to eq(two)
      expect(one.length).to eq(128)
    end

    it "falls back to a random secret when the env var is unset" do
      one = described_class.derive_session_secret(env: {}, name: "S", logger: Rubotty::Log.null)
      two = described_class.derive_session_secret(env: {}, name: "S", logger: Rubotty::Log.null)
      expect(one).not_to eq(two)
      expect(one.length).to eq(128)
    end
  end
end
