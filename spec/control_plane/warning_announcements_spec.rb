# frozen_string_literal: true

require "spec_helper"
require "sequel"

# A warning that could not be DMed says so in the room. Once the message it was
# about is gone, that notice stands over a blank space, so the pairing here is
# what lets a bot-mediated delete take the notice with it.
RSpec.describe Rubotty::ControlPlane::WarningAnnouncements, :control_plane do
  let(:db) { Sequel.sqlite }
  let(:models) { Rubotty::ControlPlane.models(db) }
  let(:now) { Time.utc(2026, 8, 28, 12, 0, 0) }
  let(:community) do
    models.community.create(slug: "first", name: "First", status: "active",
                            created_at: now, updated_at: now)
  end

  subject(:store) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  before { Rubotty::ControlPlane.migrate!(db) }

  def pair(native_id: "m1", notice_native_id: "n1", expires_at: now + 600)
    store.record(community_id: community.id, adapter: :telegram, endpoint_id: "tg",
                 native_id: native_id, notice_endpoint_id: "tg",
                 notice_native_id: notice_native_id, expires_at: expires_at)
  end

  def paired(native_id: "m1") = store.for_message(endpoint_id: "tg", native_id: native_id)

  it "hands back the notice paired with one message" do
    pair

    expect(paired.map(&:notice_native_id)).to eq(["n1"])
  end

  it "keeps pairings apart per message, so one delete retracts only its own notice" do
    pair(native_id: "m1", notice_native_id: "n1")
    pair(native_id: "m2", notice_native_id: "n2")

    expect(paired(native_id: "m1").map(&:notice_native_id)).to eq(["n1"])
    expect(paired(native_id: "m2").map(&:notice_native_id)).to eq(["n2"])
  end

  # A room can carry more than one warning about the same message over its life,
  # and deleting that message should clear every notice it drew.
  it "hands back every notice a message drew, oldest first" do
    pair(notice_native_id: "n1")
    pair(notice_native_id: "n2")

    expect(paired.map(&:notice_native_id)).to eq(%w[n1 n2])
  end

  it "forgets one pairing without touching the others" do
    pair(notice_native_id: "n1")
    pair(notice_native_id: "n2")
    store.forget(paired.first)

    expect(paired.map(&:notice_native_id)).to eq(["n2"])
  end

  it "prunes a pairing whose warning has lapsed, since there is nothing left to retract for" do
    pair(expires_at: now - 1)

    expect(store.prune).to eq(1)
    expect(paired).to be_empty
  end

  it "caps retention however far off the warning's own expiry is" do
    row = pair(expires_at: now + (400 * 86_400))

    expect(row.expires_at).to be <= now + (described_class::MAX_RETENTION_DAYS * 86_400)
  end

  it "pairs nothing without both a message and a notice to point at" do
    expect(pair(native_id: "")).to be_nil
    expect(pair(notice_native_id: "")).to be_nil
  end
end
