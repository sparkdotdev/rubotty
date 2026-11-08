# frozen_string_literal: true

require "spec_helper"

# A script's post, edit, delete and react must reach the room its own
# room_key names. script_room_endpoints resolved a message-triggered run
# with topology.rooms_for(origin).first, while everything else went through
# RoomKey.for; for an endpoint in two rooms, those two disagreed.
RSpec.describe Rubotty::Core::Router, "a channel that sits in two rooms" do
  let(:hub) { endpoint("tg-hub") }
  let(:staff_only) { endpoint("tg-staff") }
  let(:announce_extra) { endpoint("dc-announce") }

  # Built in this order on purpose: private-staff first, announce second, which
  # is what makes rooms_for(...).first and room_key_of disagree.
  let(:private_staff) { room("private-staff", hub, staff_only) }
  let(:announce) { room("announce", hub, announce_extra) }

  let(:rooms) { [private_staff, announce] }
  let(:merged) { topology(*rooms) }

  # Stands in for Snapshot::Community: room_key_of is the last-wins index, and
  # rooms is what the resolution now searches.
  let(:community) do
    Class.new do
      def initialize(rooms) = @rooms = rooms

      attr_reader :rooms

      def room_key_of(channel_or_key)
        key = channel_or_key.respond_to?(:endpoint_key) ? channel_or_key.endpoint_key : channel_or_key.to_s
        found = nil
        @rooms.each { |room| found = room.id if room.include?(key) }
        found
      end
    end.new(rooms)
  end

  # Snapshot::Channel's shape, as much of it as the resolution touches.
  let(:channel) { Struct.new(:endpoint_key).new("tg-hub") }

  let(:context) do
    Struct.new(:message, :community, :channel)
          .new(message(hub, text: "hello"), community, channel)
  end

  def endpoint_ids
    described_class.allocate.send(:script_room_endpoints, context, merged).map(&:id)
  end

  it "delivers to the room room_key_of names, not the first one indexed" do
    expect(community.room_key_of(channel)).to eq("announce")
    expect(endpoint_ids).to eq(%w[tg-hub dc-announce])
  end

  it "keeps a script out of the staff-only channel it does not believe it is in" do
    expect(endpoint_ids).not_to include("tg-staff")
  end

  # The whole point is that the two agree, so the assertion is stated that way
  # rather than as a list of endpoint ids that could drift.
  it "agrees with the room a script reads as its own room_key" do
    key = Rubotty::Scripting::RoomKey.for(channel: channel, community: community)
    expected = community.rooms.find { |room| room.id == key }

    expect(endpoint_ids).to eq(expected.endpoints.map(&:id))
  end

  # A channel in exactly one room is the ordinary case and must be unchanged.
  it "is unchanged for a channel that sits in only one room" do
    single = Struct.new(:message, :community, :channel)
                   .new(message(staff_only, text: "hi"), community,
                        Struct.new(:endpoint_key).new("tg-staff"))
    ids = described_class.allocate.send(:script_room_endpoints, single, merged).map(&:id)

    expect(ids).to eq(%w[tg-hub tg-staff])
  end

  # Without a control plane there is no room_key_of to ask, so the endpoint
  # index is still the answer and the config path is untouched.
  it "falls back to the endpoint index when there is no community" do
    plain = Struct.new(:message, :community, :channel).new(message(hub, text: "hi"), nil, nil)
    ids = described_class.allocate.send(:script_room_endpoints, plain, merged).map(&:id)

    expect(ids).to eq(%w[tg-hub tg-staff])
  end
end
