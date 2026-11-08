# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "json"

# Migration 089: /operator, /identity and /warn each kept their acknowledgement
# window under a bespoke ack_delete_after key, which moves here to the shared
# ack_ttl_seconds Core::CommandAck owns.

# Moving rather than dropping is the point: a community that had configured a
# window keeps it, where reading the default instead would quietly change how
# long a live room holds a reply.
RSpec.describe "unify_command_ack_ttl_setting migration", :control_plane do
  let(:db) { Sequel.sqlite }
  let(:now) { Time.now }

  def community_id
    @community_id ||= db[:communities].insert(slug: "sample", name: "SAMPLE", status: "active",
                                              settings: "{}", created_at: now, updated_at: now)
  end

  def store(feature, config)
    db[:feature_settings].insert(community_id: community_id, room_id: nil, feature: feature,
                                 enabled: true, config: JSON.generate(config),
                                 created_at: now, updated_at: now)
  end

  def config_for(feature)
    JSON.parse(db[:feature_settings].where(feature: feature).first[:config])
  end

  def up! = Rubotty::ControlPlane::Migrator.new(db).run(target: 89)

  def down! = Rubotty::ControlPlane::Migrator.new(db).run(target: 88)

  before { Rubotty::ControlPlane::Migrator.new(db).run(target: 88) }

  it "carries a configured window across to the shared key rather than losing it" do
    store("operator_requests", "notify_room" => "general", "ack_delete_after" => 90)

    up!

    expect(config_for("operator_requests")).to eq("notify_room" => "general", "ack_ttl_seconds" => 90)
  end

  it "moves the key for every feature that had one of its own" do
    store("identity_history", "ack_delete_after" => 45)
    store("warnings", "ack_delete_after" => 15, "max" => 3)

    up!

    expect(config_for("identity_history")).to eq("ack_ttl_seconds" => 45)
    expect(config_for("warnings")).to eq("ack_ttl_seconds" => 15, "max" => 3)
  end

  # The shared reader takes whole seconds, so a duration spelling has to be
  # written out or it would read as unset and fall back to the default.
  it "writes a duration spelling out as the seconds it means" do
    store("warnings", "ack_delete_after" => "5m")

    up!

    expect(config_for("warnings")).to eq("ack_ttl_seconds" => 300)
  end

  it "leaves a zero alone, which is a scope asking for no self-delete at all" do
    store("identity_history", "ack_delete_after" => 0)

    up!

    expect(config_for("identity_history")).to eq("ack_ttl_seconds" => 0)
  end

  it "drops a value nothing could read, which was already producing the default" do
    store("warnings", "ack_delete_after" => "soonish")

    up!

    expect(config_for("warnings")).to eq({})
  end

  it "keeps a window already stored under the new key when both are present" do
    store("warnings", "ack_delete_after" => 90, "ack_ttl_seconds" => 20)

    up!

    expect(config_for("warnings")).to eq("ack_ttl_seconds" => 20)
  end

  it "touches no feature that never had the old key" do
    store("nickname", "ack_ttl_seconds" => 60)

    up!

    expect(config_for("nickname")).to eq("ack_ttl_seconds" => 60)
  end

  it "puts the value back under the old key on the way down" do
    store("operator_requests", "ack_delete_after" => 90)

    up!
    down!

    expect(config_for("operator_requests")).to eq("ack_delete_after" => 90)
  end
end
