# frozen_string_literal: true

require "spec_helper"

# One row covers a proposal's whole life: pending, answered or lapsed, and then
# a labelled sample of what the classifier got right and wrong.
RSpec.describe Rubotty::ControlPlane::TopicMoveProposals, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 8, 27, 12, 0, 0) }

  subject(:store) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  def open_one(**overrides)
    store.open(**{ community_id: community.id, adapter: "telegram", endpoint_id: "tg-general",
                   native_id: "m1", from_room: "general", to_room: "banking",
                   author_native_id: "u9", author_name: "Ada", body: "which bank should I use",
                   reasoning: "fits Banking better than General", confidence: 0.81,
                   here_confidence: 0.22, move_payload: { "native_id" => "m1", "text" => "which bank" },
                   message_at: now - 60 }.merge(overrides))
  end

  it "opens pending, with a code an operator can type back" do
    row = open_one

    expect(row.state).to eq(described_class::PENDING)
    expect(row.code).to match(/\A[#{Rubotty::ControlPlane::ContentPolicyActions::CODE_ALPHABET}]{4}\z/)
  end

  it "keeps what a decision and a training pass both need" do
    row = open_one

    expect(row.body).to eq("which bank should I use")
    expect(row.from_room).to eq("general")
    expect(row.to_room).to eq("banking")
    expect(row.confidence).to be_within(0.001).of(0.81)
    expect(row.here_confidence).to be_within(0.001).of(0.22)
  end

  it "hands the move back in the shape the router gave it, so it can be replayed" do
    row = open_one

    expect(described_class.move_payload(row)).to eq("native_id" => "m1", "text" => "which bank")
  end

  describe "answering one" do
    it "claims it, so two operators cannot both decide it" do
      row = open_one

      expect(store.decide!(row, state: described_class::APPROVED, by: "tg:mel")).to be(true)
      expect(store.decide!(models.topic_move_proposal[row.id], state: described_class::REJECTED, by: "tg:sam"))
        .to be(false)
    end

    it "keeps the reason an operator gave for rejecting" do
      row = open_one
      store.decide!(row, state: described_class::REJECTED, by: "tg:mel", reason: "banking chat belongs here too")

      stored = models.topic_move_proposal[row.id]
      expect(stored.state).to eq(described_class::REJECTED)
      expect(stored.decision_reason).to eq("banking chat belongs here too")
      expect(stored.decided_by).to eq("tg:mel")
    end

    it "leaves an answered row in the corpus rather than deleting it" do
      row = open_one
      store.decide!(row, state: described_class::APPROVED, by: "tg:mel")

      expect(store.decided(community_id: community.id).map(&:id)).to eq([row.id])
      expect(store.pending(community_id: community.id)).to be_empty
    end
  end

  describe "lapsing" do
    it "closes what nobody answered in time and leaves a fresh one alone" do
      stale = described_class.new(models: models, logger: Rubotty::Log.null,
                                  clock: -> { now - (72 * 3600) })
      old_row = stale.open(community_id: community.id, adapter: "telegram", endpoint_id: "tg-general",
                           native_id: "m0", from_room: "general", to_room: "banking", message_at: now)
      fresh = open_one

      expect(store.lapse(pending_hours: 48)).to eq(1)
      expect(models.topic_move_proposal[old_row.id].state).to eq(described_class::LAPSED)
      expect(models.topic_move_proposal[fresh.id].state).to eq(described_class::PENDING)
    end

    # A lapsed proposal can never be approved: reposting a message the room has
    # moved on from reads as the bot malfunctioning.
    it "refuses a decision on a lapsed proposal" do
      row = open_one
      store.decide!(row, state: described_class::LAPSED, by: "system")

      expect(store.decide!(models.topic_move_proposal[row.id], state: described_class::APPROVED, by: "tg:mel"))
        .to be(false)
    end

    it "holds the pending window to its ceiling" do
      expect(described_class.pending_hours(1000)).to eq(described_class::MAX_PENDING_HOURS)
      expect(described_class.pending_hours(0)).to eq(described_class::DEFAULT_PENDING_HOURS)
      expect(described_class.pending_hours(24)).to eq(24)
    end
  end

  describe "retention" do
    it "is six months, which is the training window that was asked for" do
      expect(described_class::MAX_WINDOW_DAYS).to eq(183)
    end

    # Measured from the message, not the row: a proposal about an old message
    # must not outlive one about a fresh one.
    it "prunes on the message's own date rather than the proposal's" do
      open_one(native_id: "old", message_at: now - (200 * 86_400))
      kept = open_one(native_id: "new", message_at: now - 3600)

      expect(store.prune(window_days: 183)).to eq(1)
      expect(models.topic_move_proposal[kept.id]).not_to be_nil
    end

    it "holds a stored window to the ceiling where it is read" do
      expect(described_class.window_days(365)).to eq(described_class::MAX_WINDOW_DAYS)
      expect(described_class.window_days(30)).to eq(30)
    end
  end

  it "never reads out of the community that owns it" do
    open_one
    other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                    created_at: now, updated_at: now)

    expect(store.pending(community_id: other.id)).to be_empty
    expect(store.decided(community_id: other.id)).to be_empty
  end
end
