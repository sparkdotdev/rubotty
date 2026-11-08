# frozen_string_literal: true

require "spec_helper"
require "rubotty/guest_portal"

# The per-session guest send limit, counted over the durable feed in a trailing
# window, so it is deterministic under an injected clock and survives a restart.
RSpec.describe Rubotty::GuestPortal::RateLimiter, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models) }
  let(:invite) do
    invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600).invite
  end

  let(:now) { Time.at(Time.new(2026, 7, 24, 12, 0, 0).to_i) }
  let(:clock) { -> { @now } }
  before do
    @now = now
    Rubotty::ControlPlane::FeatureControls.new(models: models)
                                          .enable(community: community, selector: "general", feature: "guest_portal")
  end

  let(:feed) { Rubotty::ControlPlane::GuestFeed.new(models: models, clock: clock) }
  subject(:limiter) { described_class.new(feed: feed, max: 3, window_seconds: 15, clock: clock) }

  def send!
    feed.record_out(invite: invite, body: "m")
  end

  it "allows sends up to the limit and refuses the one that would exceed it" do
    3.times do
      expect(limiter.allow?(invite)).to be(true)
      send!
    end
    expect(limiter.allow?(invite)).to be(false)
  end

  it "allows sending again once the window has passed" do
    3.times { send! }
    expect(limiter.allow?(invite)).to be(false)

    @now = now + 16
    expect(limiter.allow?(invite)).to be(true)
  end

  it "limits each invite independently" do
    other = invites.issue(community: community, room: room, nickname: "Pat", ttl_seconds: 3600).invite
    3.times { send! }
    expect(limiter.allow?(invite)).to be(false)
    expect(limiter.allow?(other)).to be(true)
  end
end
