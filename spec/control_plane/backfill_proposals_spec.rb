# frozen_string_literal: true

require "spec_helper"

# What a sweep intends to relay, held until somebody says yes: these rules were
# missing on 2026-08-03, when a boot decided on its own to push a week of the
# bridge's own copies into a live room. Named at the top level on purpose: a
# constant assigned inside an example group lands on Object, which has collided
# in this suite before.
ProposalReport = Struct.new(:endpoint_id, :since, :fetched, :gaps, :ours, :claimed, :below_floor,
                            keyword_init: true)
ProposalItem = Struct.new(:native_id, :author_label, :preview, :sent_at, keyword_init: true)

RSpec.describe Rubotty::ControlPlane::BackfillProposals, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:now) { Time.at(2_000_000_000) }

  subject(:proposals) do
    described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
  end

  def report(endpoint_id: "dc-general", gaps: 3, ours: 40, **rest)
    ProposalReport.new(endpoint_id: endpoint_id, since: now - 3600, fetched: 50, gaps: gaps,
               ours: ours, claimed: 7, below_floor: 0, **rest)
  end

  def items(count = 3)
    (1..count).map do |n|
      # Ascending, so m1 is the oldest: a replay has to go out in the order it
      # was said, not newest first.
      ProposalItem.new(native_id: "m#{n}", author_label: "Alex@discord", preview: "hello #{n}", sent_at: now - (10 - n))
    end
  end

  def propose(**rest) = proposals.propose(community: community, report: report(**rest), items: items)

  describe "the threshold" do
    # A restart that loses half a minute should still heal itself. The review is
    # for the restores nobody would have chosen.
    it "lets a small gap through without asking" do
      expect(proposals.auto_relayable?(1)).to be(true)
      expect(proposals.auto_relayable?(described_class::AUTO_RELAY_LIMIT)).to be(true)
    end

    it "holds anything past the limit" do
      expect(proposals.auto_relayable?(described_class::AUTO_RELAY_LIMIT + 1)).to be(false)
    end

    it "takes the channel's own limit when it has one, so zero holds every restore" do
      expect(proposals.auto_relayable?(1, limit: 0)).to be(false)
      expect(proposals.auto_relayable?(0, limit: 0)).to be(true)
    end

    # The sweep asks before it has any reason to hold a proposal store.
    it "answers on the class as well as an instance" do
      expect(described_class.auto_relayable?(described_class::AUTO_RELAY_LIMIT + 1)).to be(false)
      expect(described_class.auto_relayable?(30, limit: 50)).to be(true)
    end
  end

  it "records the counts the sweep saw, so the numbers judged are the ones it found" do
    row = propose

    expect(row[:endpoint_id]).to eq("dc-general")
    expect(row[:status]).to eq("pending")
    expect(row[:gaps]).to eq(3)
    # The number that would have caught this morning: a zero here means the
    # ownership check is broken and nothing should be accepted.
    expect(row[:ours]).to eq(40)
  end

  it "proposes nothing when there is nothing to send" do
    expect(proposals.propose(community: community, report: report, items: [])).to be_nil
  end

  # Approving has to send the list that was shown, not a fresh answer computed
  # at the moment of clicking.
  it "hands back exactly the items that were stored, oldest first" do
    row = propose

    approved = proposals.approve(community: community, proposal_id: row[:id], decided_by: "alex")

    expect(approved.map { |item| item[:native_id] }).to eq(%w[m1 m2 m3])
  end

  it "keeps a short preview so a decision can be made, and no more" do
    proposals.propose(
      community: community, report: report,
      items: [ProposalItem.new(native_id: "m1", author_label: "Alex@discord",
                       preview: "x" * 900, sent_at: now)]
    )

    stored = models.backfill_proposal_item.first
    expect(stored[:preview].length).to eq(described_class::PREVIEW_LIMIT)
  end

  describe "a decision that has already been made" do
    it "cannot be made twice" do
      row = propose
      proposals.approve(community: community, proposal_id: row[:id], decided_by: "alex")

      expect { proposals.approve(community: community, proposal_id: row[:id], decided_by: "alex") }
        .to raise_error(described_class::Invalid, /not waiting for a decision/)
    end

    it "records who decided and when" do
      row = propose
      proposals.reject(community: community, proposal_id: row[:id], decided_by: "alex")

      stored = models.backfill_proposal[id: row[:id]]
      expect(stored[:status]).to eq("rejected")
      expect(stored[:decided_by]).to eq("alex")
    end

    it "is marked relayed once it has actually gone out, so a later boot cannot resend it" do
      row = propose
      proposals.approve(community: community, proposal_id: row[:id], decided_by: "alex")
      proposals.mark_relayed(community: community, proposal_id: row[:id])

      expect(models.backfill_proposal[id: row[:id]][:status]).to eq("relayed")
    end
  end

  describe "going stale" do
    # Accepting a day old list drops messages into a conversation that moved on.
    it "cannot be accepted once its window has passed" do
      row = proposals.propose(community: community, report: report, items: items, ttl_seconds: 60)
      later = described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now + 120 })

      expect { later.approve(community: community, proposal_id: row[:id], decided_by: "alex") }
        .to raise_error(described_class::Invalid, /expired/)
    end

    it "is marked rather than deleted, so the page can say what happened" do
      row = proposals.propose(community: community, report: report, items: items, ttl_seconds: 60)
      described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now + 120 }).expire_stale!

      expect(models.backfill_proposal[id: row[:id]][:status]).to eq("expired")
    end
  end

  # A fresh sweep describes a window that has moved, so the older list stops
  # being offered rather than sitting there alongside it.
  it "supersedes an earlier pending proposal for the same channel" do
    first = propose
    second = propose

    expect(models.backfill_proposal[id: first[:id]][:status]).to eq("expired")
    expect(models.backfill_proposal[id: second[:id]][:status]).to eq("pending")
    expect(proposals.pending(community: community).map { |r| r[:id] }).to eq([second[:id]])
  end

  # The previews are the only chat text this whole feature keeps, so they last
  # exactly as long as a decision needs them and the counts outlive them.
  describe "what happens to the previews" do
    def stored_items(id) = models.backfill_proposal_item.where(proposal_id: id).count

    it "drops them when the proposal is rejected, and keeps the row" do
      row = propose

      proposals.reject(community: community, proposal_id: row[:id], decided_by: "alex")

      expect(stored_items(row[:id])).to be_zero
      expect(models.backfill_proposal[id: row[:id]][:gaps]).to eq(3)
    end

    it "drops them when the proposal goes stale undecided" do
      row = proposals.propose(community: community, report: report, items: items, ttl_seconds: 60)

      described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now + 120 }).expire_stale!

      expect(stored_items(row[:id])).to be_zero
    end

    it "drops them when a superseding sweep expires the older list" do
      first = propose
      propose

      expect(stored_items(first[:id])).to be_zero
    end

    # Accepting has to send the stored list, so the relay reads them back first.
    it "keeps them from accept until the send has actually happened" do
      row = propose
      proposals.approve(community: community, proposal_id: row[:id], decided_by: "alex")
      expect(stored_items(row[:id])).to eq(3)

      proposals.mark_relayed(community: community, proposal_id: row[:id])

      expect(stored_items(row[:id])).to be_zero
    end
  end

  it "lists what is waiting, per channel" do
    propose(endpoint_id: "dc-general")
    propose(endpoint_id: "dc-media")

    expect(proposals.pending(community: community).map { |r| r[:endpoint_id] })
      .to contain_exactly("dc-general", "dc-media")
  end
end
