# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The record of what rubotty left standing in a room, which is the only way
# back to those messages: Telegram lets a bot read none of its own history, so
# a permanent post missing from here can never be deleted again.
RSpec.describe Rubotty::ControlPlane::BotMessages, :control_plane do
  let(:db) { Sequel.sqlite }
  let(:models) { Rubotty::ControlPlane.models(db) }
  let(:now) { Time.utc(2026, 8, 30, 12, 0, 0) }
  let(:community) do
    models.community.create(slug: "first", name: "First", status: "active",
                            created_at: now, updated_at: now)
  end
  let(:other) do
    models.community.create(slug: "second", name: "Second", status: "active",
                            created_at: now, updated_at: now)
  end

  subject(:store) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  before { Rubotty::ControlPlane.migrate!(db) }

  def post(room_key: "general", endpoint_id: "tg", native_id: "m1", kind: "summary", owner: community)
    store.record(community_id: owner.id, room_key: room_key, endpoint_id: endpoint_id,
                 native_id: native_id, kind: kind)
  end

  def in_room(room_key: "general", owner: community)
    store.for_room(community_id: owner.id, room_key: room_key)
  end

  it "hands back what was posted in one room, oldest first" do
    post(native_id: "m1")
    post(native_id: "m2")

    expect(in_room.map(&:native_id)).to eq(%w[m1 m2])
  end

  it "keeps rooms apart, so a sweep of one leaves the other standing" do
    post(room_key: "general", native_id: "m1")
    post(room_key: "offtopic", native_id: "m2")

    expect(in_room(room_key: "general").map(&:native_id)).to eq(["m1"])
  end

  # A room key is unique only within a community, so the read has to be scoped
  # by both or one tenant's sweep would reach into another's room.
  it "never answers another community's rows for the same room key" do
    post(room_key: "general", native_id: "m1", owner: community)
    post(room_key: "general", native_id: "m2", owner: other)

    expect(in_room(owner: community).map(&:native_id)).to eq(["m1"])
  end

  # A resend that lands on an id already written down must not leave two rows,
  # since the sweep would then try to delete the same message twice.
  it "records one row per message however often it is recorded" do
    post(native_id: "m1")
    post(native_id: "m1")

    expect(in_room.length).to eq(1)
  end

  it "forgets a row once its message has been dealt with" do
    post(native_id: "m1")

    expect(store.forget(endpoint_id: "tg", native_id: "m1")).to eq(1)
    expect(in_room).to be_empty
  end

  it "records nothing without a community, which has no room to scope to" do
    expect(store.record(community_id: nil, room_key: "general", endpoint_id: "tg", native_id: "m1")).to be_nil
  end

  it "records nothing for a message with no id to delete later" do
    expect(post(native_id: "")).to be_nil
  end

  it "drops rows past the retention ceiling and keeps the rest" do
    post(native_id: "old")
    models.bot_message.where(native_id: "old").update(posted_at: now - described_class::RETENTION - 1)
    post(native_id: "new")

    expect(store.prune(now: now)).to eq(1)
    expect(in_room.map(&:native_id)).to eq(["new"])
  end

  # Losing a row costs a sweep, never the post it was about, so nothing here
  # is allowed to reach the caller.
  it "answers rather than raises when the table cannot be read" do
    allow(models).to receive(:bot_message).and_raise(Sequel::DatabaseError, "gone")

    expect(in_room).to eq([])
    expect(store.prune(now: now)).to eq(0)
  end
end
