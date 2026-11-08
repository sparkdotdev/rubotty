# frozen_string_literal: true

require "spec_helper"

# Named at the top level on purpose: a constant assigned inside an example
# group lands on Object, which has collided in this suite before.
ScopedProposalReport = Struct.new(:endpoint_id, :since, :fetched, :gaps, :ours, :claimed, :below_floor,
                                  keyword_init: true)
ScopedProposalItem = Struct.new(:native_id, :author_label, :preview, :sent_at, keyword_init: true)

# Issue #1798. Every single-row read and every decision took a bare proposal
# id, so approving one replayed whichever tenant's message history that id
# happened to name. Driven over the two communities #1769 asks every surface
# to be held against.
RSpec.describe Rubotty::ControlPlane::BackfillProposals, "held to one community" do
  let(:plane) { colliding_control_plane }
  let(:models) { plane[1] }
  let(:seeded) { plane[2] }
  let(:alpha) { models.community[seeded[:alpha][:community_id]] }
  let(:beta) { models.community[seeded[:beta][:community_id]] }
  let(:now) { Time.at(2_000_000_000) }

  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "info", io: logs) }

  subject(:proposals) { described_class.new(models: models, logger: logger, clock: -> { now }) }

  def report_for(community_key)
    ScopedProposalReport.new(endpoint_id: seeded[community_key][:endpoint_keys].first, since: now - 3600,
                             fetched: 50, gaps: 3, ours: 40, claimed: 7, below_floor: 0)
  end

  def preview_items(prefix)
    (1..3).map do |n|
      ScopedProposalItem.new(native_id: "#{prefix}#{n}", author_label: "Alex@discord",
                             preview: "#{prefix} secret #{n}", sent_at: now - (10 - n))
    end
  end

  def propose(community, community_key, prefix)
    proposals.propose(community: community, report: report_for(community_key), items: preview_items(prefix))
  end

  let!(:beta_proposal) { propose(beta, :beta, "b") }

  def status_of(row) = models.backfill_proposal[id: row[:id]][:status]

  def item_count(row) = models.backfill_proposal_item.where(proposal_id: row[:id]).count

  describe "reading one tenant's proposal as another" do
    it "answers nil, the same answer a proposal that is not there gives" do
      expect(proposals.find(community: alpha, proposal_id: beta_proposal[:id])).to be_nil
      expect(proposals.find(community: alpha, proposal_id: 9_999)).to be_nil
    end

    it "still answers the tenant that owns it" do
      expect(proposals.find(community: beta, proposal_id: beta_proposal[:id])[:id]).to eq(beta_proposal[:id])
    end

    # The previews are real message text, so this is the read that matters.
    it "hands over none of the stored message previews" do
      expect(proposals.items(community: alpha, proposal_id: beta_proposal[:id])).to be_empty
      expect(proposals.items(community: beta, proposal_id: beta_proposal[:id]).map { |i| i[:native_id] })
        .to eq(%w[b1 b2 b3])
    end

    it "lists only its own tenant's rows" do
      alpha_proposal = propose(alpha, :alpha, "a")

      expect(proposals.pending(community: alpha).map { |row| row[:id] }).to eq([alpha_proposal[:id]])
      expect(proposals.pending(community: beta).map { |row| row[:id] }).to eq([beta_proposal[:id]])
    end
  end

  describe "deciding one tenant's proposal as another" do
    it "refuses to approve it, and leaves it waiting" do
      expect { proposals.approve(community: alpha, proposal_id: beta_proposal[:id], decided_by: "alex") }
        .to raise_error(described_class::Invalid, "no such proposal")
      expect(status_of(beta_proposal)).to eq("pending")
    end

    it "refuses to reject it, and keeps the previews it would have dropped" do
      expect { proposals.reject(community: alpha, proposal_id: beta_proposal[:id], decided_by: "alex") }
        .to raise_error(described_class::Invalid)
      expect(status_of(beta_proposal)).to eq("pending")
      expect(item_count(beta_proposal)).to eq(3)
    end

    it "refuses to mark it relayed" do
      expect { proposals.mark_relayed(community: alpha, proposal_id: beta_proposal[:id]) }
        .to raise_error(described_class::Invalid)
      expect(status_of(beta_proposal)).to eq("pending")
    end

    it "says so in the log, since a refusal nothing records is a refusal nobody sees" do
      begin
        proposals.approve(community: alpha, proposal_id: beta_proposal[:id], decided_by: "alex")
      rescue described_class::Invalid
        nil
      end

      expect(logs.string).to match(/refusing deciding proposal #{beta_proposal[:id]}/)
      expect(logs.string).to include("ERROR")
    end

    it "still lets the tenant that owns it decide" do
      approved = proposals.approve(community: beta, proposal_id: beta_proposal[:id], decided_by: "alex")

      expect(approved.map { |item| item[:native_id] }).to eq(%w[b1 b2 b3])
      expect(status_of(beta_proposal)).to eq("approved")
    end
  end

  # The old signatures defaulted community to nil, which read as the whole
  # deployment. A forgotten argument now raises instead.
  describe "the community argument itself" do
    it "refuses a nil rather than reading every tenant" do
      expect { proposals.pending(community: nil) }.to raise_error(ArgumentError, /community is required/)
      expect { proposals.find(community: nil, proposal_id: beta_proposal[:id]) }.to raise_error(ArgumentError)
    end

    it "reads every tenant only when a caller names EVERY_COMMUNITY" do
      propose(alpha, :alpha, "a")

      wide = proposals.pending(community: described_class::EVERY_COMMUNITY)
      expect(wide.map { |row| row[:community_id] }).to contain_exactly(alpha.id, beta.id)
    end

    it "will not let EVERY_COMMUNITY be used to decide anything" do
      expect do
        proposals.approve(community: described_class::EVERY_COMMUNITY,
                          proposal_id: beta_proposal[:id], decided_by: "alex")
      end.to raise_error(ArgumentError, /names no single tenant/)
      expect(status_of(beta_proposal)).to eq("pending")
    end
  end
end
