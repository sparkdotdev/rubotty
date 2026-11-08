# frozen_string_literal: true

require "spec_helper"

# What an operator's answer to a move proposal does. Approving replays the move
# through the same redirection the unattended path opens, so nothing downstream
# can tell the two apart; rejecting moves nothing and keeps the reason.
RSpec.describe Rubotty::SemanticAnalysis::MoveDecisions do
  DecisionRow = Struct.new(:id, :code, :adapter, :endpoint_id, :native_id, :author_native_id,
                           :author_name, :from_room, :to_room, :move_payload, :state,
                           :decided_by, :confidence, :here_confidence, keyword_init: true)
  DecisionRoom = Struct.new(:id, :label, :endpoints, keyword_init: true)
  DecisionCommunity = Struct.new(:id, :slug, :name, :rooms, keyword_init: true)

  # Stands in for ControlPlane::TopicMoveProposals, with the same claim
  # semantics: a row is answered once.
  class DecisionProposals
    attr_reader :decisions

    def initialize(row) = (@row = row) && @decisions = []

    def find(community_id:, code:) = (@row if @row && @row.code == code)

    def pending(community_id:) = @row && @row.state == "pending" ? [@row] : []

    def decide!(row, state:, by:, reason: nil)
      return false unless row.state == "pending"

      row.state = state
      row.decided_by = by
      @decisions << { state: state, by: by, reason: reason }
      true
    end
  end

  class DecisionRedirections
    attr_reader :opened

    def initialize = @opened = []

    def open(**args)
      @opened << args
      Struct.new(:id).new(77)
    end
  end

  class DecisionScheduler
    attr_reader :jobs

    def initialize = @jobs = []

    def schedule(**job) = @jobs << job
  end

  class DecisionAudit
    attr_reader :events

    def initialize = @events = []

    def record(**event) = @events << event
  end

  let(:sending) { Struct.new(:id) { def sends? = true }.new("tg-banking") }
  let(:target) { DecisionRoom.new(id: "banking", label: "Banking", endpoints: [sending]) }
  let(:community) { DecisionCommunity.new(id: 7, slug: "acme", name: "Acme", rooms: [target]) }
  let(:redirections) { DecisionRedirections.new }
  let(:scheduler) { DecisionScheduler.new }
  let(:audit) { DecisionAudit.new }

  def row(**overrides)
    DecisionRow.new(
      **{ id: 1, code: "bq7k", adapter: "telegram", endpoint_id: "tg-general", native_id: "m1",
          author_native_id: "u9", author_name: "Ada", from_room: "general", to_room: "banking",
          move_payload: JSON.generate("native_id" => "m1", "text" => "which bank"),
          state: "pending", confidence: 0.81, here_confidence: 0.22 }.merge(overrides)
    )
  end

  def decisions_for(proposal_row, redirections: self.redirections, scheduler: self.scheduler)
    described_class.new(proposals: DecisionProposals.new(proposal_row), registry: nil,
                        redirections: redirections, scheduler: scheduler, audit: audit,
                        logger: Rubotty::Log.null)
  end

  def settle(proposal_row, approve:, reason: nil, **rest)
    decisions_for(proposal_row, **rest)
      .settle(community: community, code: proposal_row.code, operator: "telegram:mel",
              approve: approve, reason: reason)
  end

  # What the console asks to work out which community a DM'd /approve is
  # about, so both verb pairs read one contract (see
  # ContentPolicy::Vindication#holds?). A settled code still answers true:
  # it names its community just as exactly as a pending one does.
  describe "holding a code" do
    it "answers true for a code this community has a proposal for" do
      expect(decisions_for(row).holds?(community_id: 7, code: "bq7k")).to be(true)
    end

    it "answers false for a code it never minted" do
      expect(decisions_for(row).holds?(community_id: 7, code: "zzzz")).to be(false)
    end

    it "still answers for a proposal somebody already decided, since it names the community either way" do
      decided_row = row(state: "approved", decided_by: "telegram:mel")

      expect(decisions_for(decided_row).holds?(community_id: 7, code: "bq7k")).to be(true)
    end

    it "answers false rather than raising with no proposal store wired at all" do
      decisions = described_class.new(proposals: nil, registry: nil, logger: Rubotty::Log.null)

      expect(decisions.holds?(community_id: 7, code: "bq7k")).to be(false)
    end
  end

  describe "approving" do
    it "opens the same redirection the unattended path would" do
      outcome = settle(row, approve: true)

      expect(outcome.status).to eq(:decided)
      expect(outcome.moved).to be(true)
      expect(redirections.opened.first).to include(community_id: 7, source_endpoint_id: "tg-general",
                                                   target_room_id: "banking")
      expect(scheduler.jobs.first).to include(kind: Rubotty::Features::Redirection::KIND)
    end

    it "names the operator on the redirection, so the log says who moved it" do
      settle(row, approve: true)

      expect(redirections.opened.first[:operator]).to include("telegram:mel")
    end

    it "records the decision against the operator who made it" do
      settle(row, approve: true)

      expect(audit.events.last).to include(action: "move_approved", actor: "telegram:mel",
                                           subject_native_id: "u9")
    end
  end

  describe "rejecting" do
    it "moves nothing and keeps the reason" do
      outcome = settle(row, approve: false, reason: "banking chat belongs in general too")

      expect(outcome.status).to eq(:decided)
      expect(redirections.opened).to be_empty
      expect(scheduler.jobs).to be_empty
      expect(audit.events.last).to include(action: "move_rejected",
                                           reason: "banking chat belongs in general too")
    end

    it "takes a rejection with no reason at all, since the reason is optional" do
      outcome = settle(row, approve: false)

      expect(outcome.status).to eq(:decided)
      expect(audit.events.last[:action]).to eq("move_rejected")
    end
  end

  it "refuses a proposal somebody already answered" do
    outcome = settle(row(state: "approved"), approve: true)

    expect(outcome.status).to eq(:settled)
    expect(redirections.opened).to be_empty
  end

  # Reposting a message the room has moved on from reads as a malfunction, so
  # a lapsed proposal is answered as lapsed rather than acted on.
  it "refuses a lapsed proposal and says so" do
    outcome = settle(row(state: "lapsed"), approve: true)

    expect(outcome.status).to eq(:lapsed)
    expect(redirections.opened).to be_empty
  end

  it "answers unknown for a code that resolves to nothing" do
    outcome = decisions_for(row).settle(community: community, code: "zzzz",
                                        operator: "telegram:mel", approve: true)

    expect(outcome.status).to eq(:unknown)
  end

  # The row is already claimed by then, so a move that cannot start must not
  # look like a proposal nobody answered.
  it "still reports the decision when the move cannot be started" do
    outcome = settle(row, approve: true, redirections: nil, scheduler: nil)

    expect(outcome.status).to eq(:decided)
    expect(outcome.moved).to be(false)
    expect(audit.events.last[:outcome]).to eq("approved, not moved")
  end

  it "refuses to move into a room with nowhere to post" do
    quiet = Struct.new(:id) { def sends? = false }.new("tg-banking")
    community.rooms = [DecisionRoom.new(id: "banking", label: "Banking", endpoints: [quiet])]

    expect(settle(row, approve: true).moved).to be(false)
  end
end
