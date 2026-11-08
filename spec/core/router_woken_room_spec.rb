# frozen_string_literal: true

require "spec_helper"

# Where a woken script's notify, post, edit, delete, react and room-fallback
# whisper land. The woken branch used to search the merged deployment-wide
# topology, so a wake in a community whose room shares a key with an
# earlier one's (both named "general") found the earlier one's endpoints.
RSpec.describe Rubotty::Core::Router, "the room a woken script speaks into" do
  let(:alpha_general) { room("general", endpoint("tg-alpha"), endpoint("dc-alpha")) }
  let(:beta_general) { room("general", endpoint("tg-beta")) }
  let(:beta_only) { room("travel", endpoint("tg-beta-travel")) }

  # The Snapshot's merged view, built alpha first, exactly as flat_map over
  # communities ordered by id produces it.
  let(:merged) { topology(alpha_general, beta_general, beta_only) }

  let(:community_type) { Struct.new(:rooms) }

  def woken(community, room_key)
    Rubotty::Scripting::WakeContext.new(community: community, room_key: room_key)
  end

  def endpoints_for(context)
    described_class.allocate.send(:script_room_endpoints, context, merged).map(&:id)
  end

  it "speaks into the woken community's own room, not the first one of that name" do
    beta = community_type.new([beta_general, beta_only])

    expect(endpoints_for(woken(beta, "general"))).to eq(["tg-beta"])
  end

  it "still finds the room when the woken community is the first one built" do
    alpha = community_type.new([alpha_general])

    expect(endpoints_for(woken(alpha, "general"))).to eq(%w[tg-alpha dc-alpha])
  end

  it "says nothing rather than guessing when the room is gone from that community" do
    beta = community_type.new([beta_only])

    expect(endpoints_for(woken(beta, "general"))).to be_empty
  end

  # Issue #1787, and this assertion used to run the other way. The merged
  # fallback is the hazard itself: a room key is unique only within a community,
  # and this resolution is what a script's post, edit, delete and react all
  # address through.
  it "resolves nothing when there is no community to scope the key by" do
    expect(endpoints_for(woken(nil, "travel"))).to be_empty
    expect(endpoints_for(woken(nil, "general"))).to be_empty
  end

  # The message path is untouched here: it resolves through the endpoint id,
  # which is globally unique, so it never crossed a community.
  it "resolves a message-triggered run through the origin endpoint as before" do
    context = Struct.new(:message, :community, :channel)
                    .new(message(endpoint("tg-beta")), nil, nil)

    expect(endpoints_for(context)).to eq(["tg-beta"])
  end
end
