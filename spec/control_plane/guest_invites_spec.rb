# frozen_string_literal: true

require "spec_helper"

# The invariants a guest's access rests on: the token is stored hashed, an
# expired or revoked invite stops authenticating, and an invite reaches exactly
# one room of one community.
RSpec.describe Rubotty::ControlPlane::GuestInvites, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

  # A DIFFERENT room, guest access left OFF, for the gating tests.
  let(:disallowed_room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  # A fixed local time with no fractional seconds. SQLite stores a naive
  # timestamp in this zone, so it round-trips to the same instant.
  let(:now) { Time.at(Time.new(2026, 7, 24, 12, 0, 0).to_i) }
  let(:clock) { -> { @now } }
  before do
    @now = now
    allow_guests!
  end

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  subject(:invites) { described_class.new(models: models, clock: clock) }

  # A room admits guests only where its guest_portal feature is enabled.
  def allow_guests!(who: "operators", selector: room.room_key)
    controls.enable(community: community, selector: selector, feature: "guest_portal")
    controls.set(community: community, selector: selector, feature: "guest_portal",
                 key: "who_can_invite", value: who)
  end

  def issue!(nickname: "Sam", ttl: 3600, as: :operator)
    invites.issue(community: community, room: room, nickname: nickname, ttl_seconds: ttl, as: as)
  end

  # Built by hand: the channels unique index is global on (adapter, account,
  # route_key), so re-seeding the same addresses re-parents SAMPLE's channels.
  def foreign_community_and_room
    other = models.community.create(slug: "other", name: "Other", status: "active",
                                    settings: "{}", created_at: now, updated_at: now)
    connection = models.platform_connection.create(
      community_id: other.id, adapter: "discord", account: "discord",
      external_id: "other-guild", created_at: now, updated_at: now
    )
    channel = models.channel.create(
      community_id: other.id, platform_connection_id: connection.id, adapter: "discord",
      account: "discord", route_key: "other-channel", endpoint_key: "other-general",
      created_at: now, updated_at: now
    )
    other_room = models.room.create(community_id: other.id, room_key: "other-room", label: "Other Room",
                                    display_name: "{}", created_at: now, updated_at: now)
    models.room_channel.create(room_id: other_room.id, channel_id: channel.id, created_at: now)
    [other, other_room]
  end

  describe "#issue" do
    it "returns the raw token once but stores only its digest" do
      issued = issue!
      expect(issued.token).to be_a(String)
      expect(issued.token.length).to be >= 40
      expect(issued.invite.token_hash).to eq(Digest::SHA256.hexdigest(issued.token))
      expect(issued.invite.token_hash).not_to eq(issued.token)
    end

    it "sets the expiry from the injected clock plus the lifetime" do
      issued = issue!(ttl: 7200)
      expect(issued.invite.expires_at.to_i).to eq((now + 7200).to_i)
    end

    it "scopes the invite to the one room and community, no single channel" do
      issued = issue!
      expect(issued.invite.room_id).to eq(room.id)
      expect(issued.invite.community_id).to eq(community.id)
      expect(issued.invite.channel_id).to be_nil
    end

    it "rejects a blank nickname" do
      expect { invites.issue(community: community, room: room, nickname: "  ", ttl_seconds: 60) }
        .to raise_error(described_class::Invalid, /nickname/)
    end

    it "rejects a non-positive lifetime" do
      expect { issue!(ttl: 0) }.to raise_error(described_class::Invalid, /lifetime/)
    end

    it "refuses a room that belongs to another community" do
      _other, other_room = foreign_community_and_room
      expect { invites.issue(community: community, room: other_room, nickname: "X", ttl_seconds: 60) }
        .to raise_error(described_class::Invalid, /does not belong/)
    end
  end

  describe "guests_allowed gating" do
    it "refuses an invite for a room that does not allow guests" do
      expect do
        invites.issue(community: community, room: disallowed_room, nickname: "Sam", ttl_seconds: 60)
      end.to raise_error(described_class::Invalid, /not allowed/)
    end

    it "allows an invite once the room is turned on" do
      allow_guests!(selector: disallowed_room.room_key)
      expect do
        invites.issue(community: community, room: disallowed_room, nickname: "Sam", ttl_seconds: 60)
      end.not_to raise_error
    end
  end

  # who_can_invite is "operators" by default, or "everyone".
  describe "who_can_invite permission" do
    it "lets an operator invite where guests are allowed" do
      allow_guests!(who: "operators")
      expect { issue!(as: :operator) }.not_to raise_error
    end

    it "refuses a normal member when who_can_invite is operators" do
      allow_guests!(who: "operators")
      expect { issue!(as: :member) }.to raise_error(described_class::Invalid, /only operators/)
    end

    it "lets a normal member invite when who_can_invite is everyone" do
      allow_guests!(who: "everyone")
      expect { issue!(as: :member) }.not_to raise_error
    end

    it "still refuses a member on a room that does not allow guests at all" do
      expect do
        invites.issue(community: community, room: disallowed_room, nickname: "Sam",
                      ttl_seconds: 60, as: :member)
      end.to raise_error(described_class::Invalid, /not allowed/)
    end
  end

  describe "#live_on_room?" do
    it "is true only while a live invite exists on the room" do
      expect(invites.live_on_room?(room_id: room.id)).to be(false)
      issued = issue!
      expect(invites.live_on_room?(room_id: room.id)).to be(true)
      invites.revoke(invite: issued.invite)
      expect(invites.live_on_room?(room_id: room.id)).to be(false)
    end
  end

  describe "#authenticate" do
    it "returns the invite for the correct live token" do
      issued = issue!
      expect(invites.authenticate(token: issued.token)&.id).to eq(issued.invite.id)
    end

    it "returns nil for an unknown token" do
      issue!
      expect(invites.authenticate(token: "not-a-real-token")).to be_nil
    end

    it "returns nil for a blank token without touching the database" do
      expect(invites.authenticate(token: "")).to be_nil
      expect(invites.authenticate(token: nil)).to be_nil
    end

    it "rejects the token once the invite has expired" do
      issued = issue!(ttl: 60)
      expect(invites.authenticate(token: issued.token)).not_to be_nil
      @now = now + 61
      expect(invites.authenticate(token: issued.token)).to be_nil
    end

    it "rejects the token once the invite is revoked, even before expiry" do
      issued = issue!(ttl: 3600)
      invites.revoke(invite: issued.invite)
      expect(invites.authenticate(token: issued.token)).to be_nil
    end
  end

  describe "#record_join" do
    it "pins the join cursor on first open and never moves it afterwards" do
      issued = issue!
      invites.record_join(invite: issued.invite, cursor: 5)
      expect(issued.invite.refresh.join_cursor).to eq(5)

      invites.record_join(invite: issued.invite.refresh, cursor: 99)
      expect(issued.invite.refresh.join_cursor).to eq(5)
    end

    # The notice fires on the same event that pins the cursor.
    it "announces the join once, on first open, and not on a later re-open" do
      announcer = instance_double(Rubotty::ControlPlane::GuestAnnouncer)
      invites = described_class.new(models: models, clock: clock, announcer: announcer)
      issued = invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600, as: :operator)

      expect(announcer).to receive(:announce_join).with(issued.invite).once
      invites.record_join(invite: issued.invite, cursor: 5)
      invites.record_join(invite: issued.invite.refresh, cursor: 99)
    end

    # Two independently loaded copies of the same row, both unjoined in
    # memory, the way two requests racing on the same invite link would
    # each read it before either write lands. The guard has to be
    # conditional at the DB layer, not a Ruby-level nil check, or both win.
    it "announces the join only once when two requests race on the same never-joined invite" do
      announcer = instance_double(Rubotty::ControlPlane::GuestAnnouncer)
      invites = described_class.new(models: models, clock: clock, announcer: announcer)
      issued = invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600, as: :operator)
      first_reader = models.guest_invite[issued.invite.id]
      second_reader = models.guest_invite[issued.invite.id]

      expect(announcer).to receive(:announce_join).once

      invites.record_join(invite: first_reader, cursor: 5)
      invites.record_join(invite: second_reader, cursor: 99)

      expect(issued.invite.refresh.join_cursor).to eq(5)
    end
  end

  describe "#revoke" do
    it "is idempotent and preserves the first revocation time" do
      issued = issue!
      invites.revoke(invite: issued.invite)
      first = issued.invite.refresh.revoked_at
      @now = now + 100
      invites.revoke(invite: issued.invite.refresh)
      expect(issued.invite.refresh.revoked_at.to_i).to eq(first.to_i)
    end
  end

  describe "#revoke_by_id" do
    it "will not revoke another community's invite by id" do
      other, _room = foreign_community_and_room
      issued = issue!
      expect(invites.revoke_by_id(community: other, id: issued.invite.id)).to be_nil
      expect(issued.invite.refresh.revoked_at).to be_nil
    end
  end

  # The /guest command hands this a Snapshot::Channel's endpoint_key, which is
  # all it carries.
  describe "#community_by_id and #room_for_endpoint_key" do
    it "resolves the community row for its id" do
      expect(invites.community_by_id(community.id).id).to eq(community.id)
    end

    it "resolves the room a channel's endpoint_key is bridged into" do
      resolved = invites.room_for_endpoint_key(community: community, endpoint_key: "tg-general")
      expect(resolved.id).to eq(room.id)
    end

    it "is nil for an endpoint_key this community has no channel for" do
      expect(invites.room_for_endpoint_key(community: community, endpoint_key: "no-such-endpoint")).to be_nil
    end
  end

  describe "state helpers" do
    it "reports live, expired and revoked" do
      live = issue!(ttl: 3600).invite
      expect(invites.state_of(live)).to eq("live")

      expired = issue!(ttl: 10).invite
      @now = now + 20
      expect(invites.state_of(expired)).to eq("expired")

      @now = now
      revoked = issue!(ttl: 3600).invite
      invites.revoke(invite: revoked)
      expect(invites.state_of(revoked.refresh)).to eq("revoked")
    end
  end
end
