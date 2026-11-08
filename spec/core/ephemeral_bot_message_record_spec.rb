# frozen_string_literal: true

require "spec_helper"

# A post with a TTL reaps itself off its pending-deletion row. One without has
# nothing coming for it, so unless it is written down here it can never be
# found again: Telegram lets a bot read none of its own history, which is what
# /clean would otherwise have to do.
RSpec.describe Rubotty::Core::EphemeralMessage, "recording what it leaves standing" do
  let(:tg) { endpoint("tg", account: "a") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:owned) { room("general", tg, community_id: 7) }
  let(:orphan) { room("general", tg) }

  # Records what it was handed, in the shape ControlPlane::BotMessages writes.
  let(:tracker) do
    Class.new do
      def initialize = (@rows = [])

      attr_reader :rows

      def record(community_id:, room_key:, endpoint_id:, native_id:, kind: nil)
        @rows << { community_id: community_id, room_key: room_key, endpoint_id: endpoint_id,
                   native_id: native_id, kind: kind }
      end
    end.new
  end

  def service(topo: topology(owned), track: tracker)
    described_class.new(
      adapters: { [:fake, "a"] => adapter }, session_id: "live", topology: topo,
      logger: Rubotty::Log.null, tracker: track
    )
  end

  it "records a permanent post against its room and community" do
    service.post(endpoints: [tg], body: "summary", name: "summary", delete_after: 0)

    expect(tracker.rows).to contain_exactly(
      hash_including(community_id: 7, room_key: "general", endpoint_id: "tg", kind: "summary")
    )
  end

  # The self-deleting ones are already accounted for, and recording every
  # acknowledgement would fill the table with rows that reap themselves.
  it "records nothing for a post that self-deletes" do
    service.post(endpoints: [tg], body: "ack", name: "bridge", delete_after: 30)

    expect(tracker.rows).to be_empty
  end

  # The config-file path has no community to scope a row to, so there is
  # nothing /clean could safely sweep and nothing is written.
  it "records nothing for a room with no community" do
    service(topo: topology(orphan)).post(endpoints: [tg], body: "banner", name: "bridge", delete_after: 0)

    expect(tracker.rows).to be_empty
  end

  it "posts normally with no tracker at all" do
    group = service(track: nil).post(endpoints: [tg], body: "banner", name: "bridge", delete_after: 0)

    expect(group.copies.size).to eq(1)
  end

  # Losing the row must never cost the post it was about.
  it "still answers the group when recording raises" do
    exploding = Class.new { def record(**) = raise("no database") }.new

    group = service(track: exploding).post(endpoints: [tg], body: "banner", name: "bridge", delete_after: 0)

    expect(group.copies.size).to eq(1)
  end
end
