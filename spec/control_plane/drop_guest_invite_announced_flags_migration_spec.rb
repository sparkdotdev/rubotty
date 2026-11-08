# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 079: drops guest_invites.announced_join and .announced_expiry.
# Neither column was ever read or written by GuestInvites or GuestRetention,
# which gate their one-time announcements on joined_at and on being called
# once per invite instead.
RSpec.describe "drop_guest_invite_announced_flags migration", :control_plane do
  let(:db) { Sequel.sqlite }
  let(:now) { Time.now }

  def columns = db.schema(:guest_invites).map(&:first)

  before { Rubotty::ControlPlane::Migrator.new(db).run(target: 78) }

  it "carries both columns just before the migration" do
    expect(columns).to include(:announced_join, :announced_expiry)
  end

  it "drops both columns on the way up" do
    Rubotty::ControlPlane::Migrator.new(db).run(target: 79)

    expect(columns).not_to include(:announced_join, :announced_expiry)
  end

  it "puts both columns back, defaulted false, on the way down" do
    Rubotty::ControlPlane::Migrator.new(db).run(target: 79)
    Rubotty::ControlPlane::Migrator.new(db).run(target: 78)

    expect(columns).to include(:announced_join, :announced_expiry)
    community_id = db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                                           created_at: now, updated_at: now)
    conn_id = db[:platform_connections].insert(
      community_id: community_id, adapter: "telegram", account: "telegram",
      external_id: "-100", created_at: now, updated_at: now
    )
    channel_id = db[:channels].insert(
      community_id: community_id, platform_connection_id: conn_id,
      adapter: "telegram", account: "telegram", route_key: "guest",
      endpoint_key: "guest", relay: "{}", display_name: "{}", settings: "{}",
      created_at: now, updated_at: now
    )
    invite_id = db[:guest_invites].insert(
      community_id: community_id, channel_id: channel_id, nickname: "guest",
      token_hash: "x" * 64, expires_at: now, created_at: now, updated_at: now
    )
    invite = db[:guest_invites].where(id: invite_id).first
    expect(invite[:announced_join]).to eq(false)
    expect(invite[:announced_expiry]).to eq(false)
  end
end
