# frozen_string_literal: true

require "spec_helper"

# When a channel joined a room is when it began bridging, and it is what stops the
# backfill sweep replaying a private channel's history to the other side the
# moment somebody maps it. room_channels is insert-only, so its created_at is that
# moment and stays true.
RSpec.describe Rubotty::ControlPlane::SnapshotBuilder, "channel mapping times", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  def snapshot = described_class.build(models)

  def channel_named(endpoint_key)
    snapshot.communities.first.channels.find { |channel| channel.endpoint.id == endpoint_key }
  end

  let(:mapped) do
    models.room_channel.where(
      room_id: models.room.where(community_id: community.id).select(:id)
    ).order(:id).first
  end

  it "carries the moment each channel joined a room" do
    channel = models.channel[mapped.channel_id]

    expect(channel_named(channel.endpoint_key).mapped_at.to_i).to eq(mapped.created_at.to_i)
  end

  it "leaves a channel that is in no room without one" do
    orphan = models.channel.create(
      community_id: community.id,
      platform_connection_id: models.platform_connection.first.id,
      adapter: "discord", account: "discord", route_key: "999", endpoint_key: "dc-orphan",
      created_at: Time.now, updated_at: Time.now
    )

    expect(channel_named(orphan.endpoint_key).mapped_at).to be_nil
  end

  it "takes the earliest mapping for a channel joined to more than one room" do
    channel_id = mapped.channel_id
    other_room = models.room.where(community_id: community.id).exclude(id: mapped.room_id).first
    later = mapped.created_at + 3600
    models.room_channel.create(room_id: other_room.id, channel_id: channel_id, created_at: later)

    key = models.channel[channel_id].endpoint_key

    expect(channel_named(key).mapped_at.to_i).to eq(mapped.created_at.to_i)
  end

  it "defaults to nil when a channel is built without one" do
    channel = Rubotty::ControlPlane::Snapshot::Channel.new(
      endpoint: Rubotty::Core::Endpoint.new(id: "x", adapter_name: :telegram, account: "tg", settings: {}),
      community_id: 1, route_key: "x"
    )

    expect(channel.mapped_at).to be_nil
  end
end
