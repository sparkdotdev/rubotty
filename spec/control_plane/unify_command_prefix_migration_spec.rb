# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "json"

# Migration 067: folds the seven per-feature prefixes/prefix copies into
# one "commands" feature_settings row per (community, room) scope, and
# strips the retired keys from the legacy rows.
RSpec.describe "unify_command_prefix_setting migration", :control_plane do
  let(:db) { Sequel.sqlite }
  let(:now) { Time.now }

  before { Rubotty::ControlPlane::Migrator.new(db).run(target: 66) }

  let(:community_id) do
    db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}", created_at: now, updated_at: now)
  end

  def insert_setting(feature:, config:, room_id: nil)
    db[:feature_settings].insert(
      community_id: community_id, room_id: room_id, feature: feature, enabled: true,
      config: JSON.generate(config), created_at: now, updated_at: now
    )
  end

  def run_migration! = Rubotty::ControlPlane::Migrator.new(db).run(target: 67)

  def config_for(feature, room_id: nil)
    row = db[:feature_settings].where(community_id: community_id, room_id: room_id, feature: feature).first
    row && JSON.parse(row[:config])
  end

  it "carries a non-default prefixes value on a declaring feature into the new commands row" do
    insert_setting(feature: "utility_commands", config: { "prefixes" => ["#"] })
    run_migration!

    expect(config_for("commands")["prefixes"]).to eq(["#"])
  end

  it "carries the legacy singular prefix the same way" do
    insert_setting(feature: "faq", config: { "prefix" => "?" })
    run_migration!

    expect(config_for("commands")["prefix"]).to eq("?")
  end

  it "leaves a scope with only the untouched default alone, writing no commands row" do
    insert_setting(feature: "utility_commands", config: { "prefixes" => ["/", "!"] })
    run_migration!

    expect(config_for("commands")).to be_nil
  end

  it "writes no commands row when nothing configured a prefix at all" do
    insert_setting(feature: "faq", config: { "name" => "FAQ" })
    run_migration!

    expect(config_for("commands")).to be_nil
  end

  it "strips prefixes and prefix from the legacy row, leaving its other keys alone" do
    insert_setting(feature: "utility_commands", config: { "prefixes" => ["#"], "ack_ttl_seconds" => 5 })
    run_migration!

    expect(config_for("utility_commands")).to eq({ "ack_ttl_seconds" => 5 })
  end

  it "picks the declaring feature earliest in the fixed order when two scopes disagree" do
    insert_setting(feature: "faq", config: { "prefixes" => ["?"] })
    insert_setting(feature: "utility_commands", config: { "prefixes" => ["#"] })
    run_migration!

    expect(config_for("commands")["prefixes"]).to eq(["#"])
  end

  it "keeps a room-scoped override separate from the community-wide default" do
    room_id = db[:rooms].insert(community_id: community_id, room_key: "gaming", label: "Gaming",
                                created_at: now, updated_at: now)
    insert_setting(feature: "utility_commands", config: { "prefixes" => ["#"] }, room_id: room_id)
    run_migration!

    expect(config_for("commands", room_id: room_id)["prefixes"]).to eq(["#"])
    expect(config_for("commands")).to be_nil
  end
end
