# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Polls::RoomActivity do
  subject(:activity) { described_class.new(window: 3) }

  let(:key) { described_class.key(1, "room") }

  def ref(native_id) = Rubotty::Core::MessageRef.new("tg-gaming", native_id)

  it "counts a message toward the window" do
    activity.record(key, at: Time.now)
    expect(activity.buried?(key, Time.now - 1)).to be(false)
  end

  it "buries a card once as many later messages as the window have landed" do
    now = Time.now
    3.times { |i| activity.record(key, at: now + i) }
    expect(activity.buried?(key, now - 1)).to be(true)
  end

  # PollCommand and ScheduleCommand both include PollSurface and call #record
  # on the one poll_activity the runtime wires to each, so the same chat
  # message reaches #record twice in a row when a room has both enabled.
  # Without this, VISIBLE_WINDOW trips at half its configured threshold.
  it "counts the same message once even when handed to record twice" do
    now = Time.now
    same_message = ref("42")
    activity.record(key, at: now, ref: same_message)
    activity.record(key, at: now, ref: same_message)
    activity.record(key, at: now + 1, ref: ref("43"))

    expect(activity.buried?(key, now - 1)).to be(false)
  end

  it "still counts two distinct messages that happen to share a ref-less caller" do
    now = Time.now
    3.times { |i| activity.record(key, at: now + i, ref: nil) }
    expect(activity.buried?(key, now - 1)).to be(true)
  end
end
