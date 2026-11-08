# frozen_string_literal: true

require "spec_helper"

# Its own stand-ins, named for this file: a constant assigned inside an example
# group lands on Object, which has collided in this suite before.
GateMsg = Struct.new(:ref, :timestamp, :body, :author) do
  def initialize(ref, timestamp = nil, body = Rubotty::Core::RichText.plain("gap"), author = nil)
    super
  end

  def with(**changes)
    self.class.new(changes.fetch(:ref, ref), changes.fetch(:timestamp, timestamp),
                   changes.fetch(:body, body), changes.fetch(:author, author))
  end
end

class GateFakeAdapter
  attr_reader :ingested, :sinces

  # +ownership+, when given, is a native id => :ours/:not_ours/:unknown map, and
  # is what turns on the ownership seam Core::GapReport asks through.
  def initialize(messages: [], ownership: nil)
    @messages = messages
    @ownership = ownership
    @ingested = []
    @sinces = []
  end

  def supports_backfill? = true

  def supports_reaction_backfill? = false

  def supports_gap_ownership? = !@ownership.nil?

  # Honours +since+ the way a real history fetch does, so a test can leave a
  # hole behind the sweep's watermark and see which start each path read from.
  def backfill_messages(_endpoint, since:, limit:)
    @sinces << since
    @messages.select { |message| message.timestamp >= since }
  end

  def backfill_candidates(_endpoint, since:, limit:)
    backfill_messages(nil, since: since, limit: limit)
      .map { |message| [message, @ownership.fetch(message.ref.native_id, :not_ours)] }
  end

  # Where the proposal gate started reading, which is the last ask of the sweep.
  def proposal_since = @sinces.last

  def ingest(message) = @ingested << message
end

class GateFakeCommunity
  attr_reader :id, :slug, :channels

  def initialize(id:, channels:, config: {}, slug: "sample")
    @id = id
    @slug = slug
    @channels = channels
    @config = config
  end

  def feature_enabled?(_channel, feature) = feature == "backfill"

  def feature_config(_channel, _feature) = @config
end

# The half of the approval flow that was never wired: before this, enabling
# backfill anywhere relayed into a live room with nobody asked, which put a
# week of the bridge's own copies into one on 2026-08-03. The sweep now writes
# the window down past auto_relay_limit instead of sending any of it.
RSpec.describe Rubotty::Core::Backfill, :control_plane do
  def ref(native) = Rubotty::Core::MessageRef.new("dc-general", native)

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }
  let(:now) { Time.at(2_000_000_000) }

  let(:endpoint) { double("endpoint", id: "dc-general") }
  let(:mapped_at) { nil }
  let(:last_relay_at) { nil }
  let(:channel) { double("channel", endpoint: endpoint, adapter: :discord, account: "dc", mapped_at: mapped_at) }
  let(:config) { {} }
  let(:community) { GateFakeCommunity.new(id: community_row.id, channels: [channel], config: config) }
  let(:snapshot) { double("snapshot", communities: [community]) }

  # Oldest first, one a minute, all well inside the safe horizon.
  def messages(count)
    (1..count).map { |n| GateMsg.new(ref("m#{n}"), now - ((count - n + 1) * 60)) }
  end

  let(:ownership) { nil }
  let(:adapter) { GateFakeAdapter.new(messages: messages(30), ownership: ownership) }
  let(:adapters) { { [:discord, "dc"] => adapter } }
  let(:storage) { instance_double(Rubotty::Storage::Memory) }

  let(:proposals) do
    Rubotty::ControlPlane::BackfillProposals.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
  end

  subject(:backfill) do
    described_class.new(storage: storage, logger: Rubotty::Log.null, clock: -> { now },
                        sleeper: ->(_seconds) {}, proposals: proposals)
  end

  before do
    allow(storage).to receive(:relay_claimed?).and_return(false)
    allow(storage).to receive(:destination?).and_return(false)
    allow(storage).to receive(:last_relay_at).and_return(last_relay_at)
  end

  def run = backfill.run(adapters: adapters, snapshot: snapshot)

  def pending = proposals.pending(community: community_row)

  describe "a gap bigger than the channel's limit" do
    it "writes one proposal and puts nothing at all into the room" do
      run

      expect(adapter.ingested).to be_empty
      expect(pending.size).to eq(1)
      expect(pending.first[:endpoint_id]).to eq("dc-general")
      expect(pending.first[:gaps]).to eq(30)
    end

    it "stores an item per message it would have sent, with what it takes to judge one" do
      run
      items = proposals.items(community: community_row, proposal_id: pending.first[:id])

      expect(items.map { |item| item[:native_id] }).to eq((1..30).map { |n| "m#{n}" })
      expect(items.first[:preview]).to eq("gap")
      expect(items.first[:sent_at]).not_to be_nil
    end

    # The counts an operator judges by, ours above all: a zero there means the
    # ownership check is broken and nothing should be accepted.
    it "records the classification the sweep saw, rather than a recount taken later" do
      row = run.then { pending.first }

      expect(row[:fetched]).to eq(30)
      expect(row[:ours]).to be_zero
      expect(row[:claimed]).to be_zero
    end
  end

  describe "a gap at or under the limit" do
    let(:adapter) { GateFakeAdapter.new(messages: messages(25), ownership: ownership) }

    it "heals itself quietly, the way a short restart always has" do
      run

      expect(adapter.ingested.map { |message| message.ref.native_id }).to eq((1..25).map { |n| "m#{n}" })
      expect(pending).to be_empty
    end
  end

  describe "auto_relay_limit: 0" do
    let(:config) { { auto_relay_limit: 0 } }
    let(:adapter) { GateFakeAdapter.new(messages: messages(1), ownership: ownership) }

    it "holds even a single missing message for a decision" do
      run

      expect(adapter.ingested).to be_empty
      expect(pending.size).to eq(1)
      expect(proposals.items(community: community_row, proposal_id: pending.first[:id]).map { |item| item[:native_id] }).to eq(%w[m1])
    end
  end

  # A bot that crash-loops must not leave a page of identical proposals behind.
  describe "a second boot over the same unchanged gap" do
    it "supersedes the first rather than stacking a second one up" do
      run
      first = pending.first[:id]

      run

      expect(pending.size).to eq(1)
      expect(pending.first[:id]).not_to eq(first)
      expect(models.backfill_proposal[id: first][:status]).to eq("expired")
    end

    it "keeps a preview only for the proposal still waiting on somebody" do
      run
      run

      expect(models.backfill_proposal_item.select_map(:proposal_id).uniq).to eq([pending.first[:id]])
    end
  end

  # The classification is GapReport's, so the thing that caused the incident
  # cannot come back through a second opinion the gate keeps to itself.
  describe "when the window is full of our own relayed copies" do
    let(:ownership) { (1..30).to_h { |n| ["m#{n}", :ours] } }

    it "counts no gap, proposes nothing, and lets the sweep run as normal" do
      run

      expect(pending).to be_empty
      expect(adapter.ingested.size).to eq(30)
    end
  end

  # The shape the sweep's own watermark hid for good: yesterday evening went
  # missing, the channel carried on talking this morning, and the start jumped
  # past the hole, so the busiest channel was the one that could never raise a
  # gap. The proposal gate reads the plain window, so it can still see it.
  describe "a hole with traffic on both sides of it" do
    let(:hole) { (1..30).map { |n| GateMsg.new(ref("h#{n}"), now - (24 * 60 * 60) + (n * 60)) } }
    let(:since_the_hole) { GateMsg.new(ref("this-morning"), now - 300) }
    let(:adapter) { GateFakeAdapter.new(messages: hole + [since_the_hole], ownership: ownership) }
    let(:last_relay_at) { now - 3600 }

    before do
      allow(storage).to receive(:relay_claimed?) { |source:, **| source.native_id == "this-morning" }
    end

    it "raises a proposal even though the sweep resumes past the gap" do
      run

      expect(pending.size).to eq(1)
      expect(pending.first[:gaps]).to eq(30)
    end

    it "names every message in the hole" do
      run

      expect(proposals.items(community: community_row, proposal_id: pending.first[:id]).map { |item| item[:native_id] })
        .to eq((1..30).map { |n| "h#{n}" })
    end

    it "still sends none of it, because a person decides" do
      run

      expect(adapter.ingested).to be_empty
    end
  end

  # The protection mapped_at carries on its own: a channel bridged this
  # afternoon must not offer this morning's private history for publishing.
  describe "a channel mapped into a room after those messages were written" do
    let(:mapped_at) { now - 30 }

    it "proposes nothing and sends nothing" do
      run

      expect(pending).to be_empty
      expect(adapter.ingested).to be_empty
    end

    context "with a hole since the mapping and a relay after it" do
      let(:mapped_at) { now - (2 * 60 * 60) }
      let(:before_the_bridge) { (1..30).map { |n| GateMsg.new(ref("old#{n}"), now - (3 * 60 * 60) + n) } }
      let(:hole) { (1..30).map { |n| GateMsg.new(ref("h#{n}"), now - (90 * 60) + (n * 60)) } }
      let(:adapter) { GateFakeAdapter.new(messages: before_the_bridge + hole, ownership: ownership) }
      let(:last_relay_at) { now - (30 * 60) }

      it "proposes the hole and none of the pre-bridge history" do
        run

        expect(proposals.items(community: community_row, proposal_id: pending.first[:id]).map { |item| item[:native_id] })
          .to eq((1..30).map { |n| "h#{n}" })
      end

      it "starts the proposal at the mapping rather than the whole window" do
        run

        expect(adapter.proposal_since).to be_within(1).of(mapped_at)
      end
    end
  end

  # Below the horizon the dedup claim may already be pruned, so re-feeding could
  # duplicate. A lookback set past the horizon buys no extra reach here either.
  describe "a lookback set past the safe horizon" do
    let(:config) { { lookback_seconds: 604_800, safe_horizon_seconds: 259_200 } }
    let(:ancient) { (1..5).map { |n| GateMsg.new(ref("a#{n}"), now - (100 * 60 * 60) + n) } }
    let(:recent) { (1..30).map { |n| GateMsg.new(ref("h#{n}"), now - (24 * 60 * 60) + (n * 60)) } }
    let(:adapter) { GateFakeAdapter.new(messages: ancient + recent, ownership: ownership) }
    let(:last_relay_at) { now - 3600 }

    it "starts the proposal at the horizon, not the wider lookback" do
      run

      expect(adapter.proposal_since).to be_within(1).of(now - 259_200)
    end

    it "offers nothing older than the horizon" do
      run

      expect(proposals.items(community: community_row, proposal_id: pending.first[:id]).map { |item| item[:native_id] })
        .to eq((1..30).map { |n| "h#{n}" })
    end
  end

  # Refusing to send is the safe answer to "I cannot tell how big this is".
  describe "with nowhere to record a proposal" do
    subject(:backfill) do
      described_class.new(storage: storage, logger: Rubotty::Log.null, clock: -> { now },
                          sleeper: ->(_seconds) {})
    end

    it "relays nothing rather than falling back to sending unattended" do
      run

      expect(adapter.ingested).to be_empty
      expect(models.backfill_proposal.count).to be_zero
    end
  end
end
