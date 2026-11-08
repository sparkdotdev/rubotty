# frozen_string_literal: true

require "spec_helper"

# Minimal fakes for the bot side of the proposal handoff: resolving
# a channel from a snapshot needs the same shape Core::Backfill's own specs use,
# named differently here so the two files never collide on a shared constant.
ProposalRelayMsg = Struct.new(:ref, :timestamp, :body) do
  def initialize(ref, timestamp = nil, body = Rubotty::Core::RichText.plain("hi"))
    super
  end

  def with(**changes)
    self.class.new(changes.fetch(:ref, ref), changes.fetch(:timestamp, timestamp), changes.fetch(:body, body))
  end
end

class ProposalRelayFakeAdapter
  attr_reader :ingested

  def initialize(messages: [])
    @messages = messages
    @ingested = []
  end

  def supports_backfill? = true

  def backfill_messages(_endpoint, since:, limit:) = @messages

  def ingest(message) = @ingested << message
end

class ProposalRelayFakeCommunity
  attr_reader :id, :slug, :channels

  def initialize(id:, channels:, slug: "sample")
    @id = id
    @slug = slug
    @channels = channels
  end

  def feature_enabled?(_channel, feature) = feature == "backfill"

  def feature_config(_channel, _feature) = {}
end

# The bot side of the handoff: an operator's Accept on the dashboard can only
# flip a row to approved, since the web process holds no adapters. This turns
# that into messages actually going out, over the same paced path a normal
# sweep uses, marking the proposal relayed only once that has happened.
RSpec.describe Rubotty::Core::BackfillProposalRelay, :control_plane do
  def ref(native) = Rubotty::Core::MessageRef.new("dc-general", native)

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }
  let(:now) { Time.at(2_000_000_000) }

  let(:endpoint) { double("endpoint", id: "dc-general") }
  let(:channel) { double("channel", endpoint: endpoint, adapter: :discord, account: "dc", mapped_at: nil) }
  let(:snapshot_community) { ProposalRelayFakeCommunity.new(id: community_row.id, channels: [channel]) }
  let(:snapshot) { double("snapshot", communities: [snapshot_community]) }

  let(:messages) do
    [
      ProposalRelayMsg.new(ref("m1"), now - 180),
      ProposalRelayMsg.new(ref("m2"), now - 120),
      ProposalRelayMsg.new(ref("m3"), now - 60)
    ]
  end
  let(:adapter) { ProposalRelayFakeAdapter.new(messages: messages) }
  let(:adapters) { { [:discord, "dc"] => adapter } }
  let(:storage) { instance_double(Rubotty::Storage::Memory) }

  before { allow(storage).to receive(:relay_claimed?).and_return(false) }

  subject(:relay) do
    described_class.new(models: models, storage: storage, adapters: adapters, snapshot: snapshot,
                        logger: Rubotty::Log.null, clock: -> { now }, sleeper: ->(_seconds) {})
  end

  def create_proposal(status: "approved", endpoint_id: "dc-general", items: %w[m1 m2], expires_at: now + 86_400)
    id = models.backfill_proposal.insert(
      community_id: community_row.id, endpoint_id: endpoint_id, status: status,
      fetched: items.size, gaps: items.size, ours: 0, claimed: 0, below_floor: 0,
      swept_since: now - 3600, expires_at: expires_at, created_at: now, updated_at: now
    )
    items.each_with_index do |native_id, i|
      models.backfill_proposal_item.insert(
        proposal_id: id, native_id: native_id, author_label: "Alex@discord",
        preview: "hi #{i}", sent_at: now - (10 - i), created_at: now
      )
    end
    id
  end

  describe "#relay" do
    it "relays exactly the stored items and marks the proposal relayed" do
      id = create_proposal(items: %w[m1 m2])

      outcome = relay.relay(id)

      expect(outcome.ok?).to be(true)
      expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[m1 m2])
      expect(models.backfill_proposal[id: id][:status]).to eq("relayed")
    end

    it "never relays an id nobody approved, even though the adapter's window also holds it" do
      id = create_proposal(items: %w[m1])

      relay.relay(id)

      expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[m1])
    end

    it "errors, and leaves the proposal alone, for one that is not approved" do
      id = create_proposal(status: "pending", items: %w[m1])

      outcome = relay.relay(id)

      expect(outcome.ok?).to be(false)
      expect(outcome.error).to include("pending")
      expect(adapter.ingested).to be_empty
      expect(models.backfill_proposal[id: id][:status]).to eq("pending")
    end

    it "errors for a proposal id that does not exist" do
      outcome = relay.relay(999_999)

      expect(outcome.ok?).to be(false)
      expect(outcome.error).to include("no such proposal")
    end

    # The counts on this page are what somebody reads to decide the
    # restore worked, so a copy the bridge gave up on cannot be absorbed into
    # "relayed" and left as a warning in the log.
    context "when a copy of an approved message never arrives" do
      let(:outcomes) { Rubotty::Core::RelayOutcomes.new(logger: Rubotty::Log.null) }

      subject(:relay) do
        described_class.new(models: models, storage: storage, adapters: adapters, snapshot: snapshot,
                            logger: Rubotty::Log.null, clock: -> { now }, sleeper: ->(_seconds) {},
                            outcomes: outcomes)
      end

      before do
        allow(adapter).to receive(:ingest).and_wrap_original do |original, message|
          outcomes.abandoned(message.ref, "tg-general", "Too Many Requests") if message.ref.native_id == "m1"
          original.call(message)
        end
      end

      it "says the relay did not fully succeed rather than reporting a clean run" do
        id = create_proposal(items: %w[m1 m2])

        outcome = relay.relay(id)

        expect(outcome.ok?).to be(false)
        expect(outcome.error).to include("1 approved message(s) never arrived")
      end

      # The exactly-once claim was taken on the way out, so a second click would
      # skip every one of them. Leaving the row approved would only invite it.
      it "still marks the proposal relayed, since clicking Accept again would send nothing" do
        id = create_proposal(items: %w[m1 m2])

        relay.relay(id)

        expect(models.backfill_proposal[id: id][:status]).to eq("relayed")
      end
    end

    it "errors, and does not mark relayed, when this process holds no live adapter for the channel" do
      id = create_proposal(items: %w[m1])
      unreachable = described_class.new(models: models, storage: storage, adapters: {}, snapshot: snapshot,
                                        logger: Rubotty::Log.null, clock: -> { now })

      outcome = unreachable.relay(id)

      expect(outcome.ok?).to be(false)
      expect(models.backfill_proposal[id: id][:status]).to eq("approved")
    end
  end

  describe "#kick" do
    it "answers immediately, then relays and marks it relayed on its own thread" do
      id = create_proposal(items: %w[m1])

      outcome = relay.kick(id)

      expect(outcome.ok?).to be(true)
      relay.last_relay_thread.join
      expect(models.backfill_proposal[id: id][:status]).to eq("relayed")
    end

    it "answers synchronously with the error, spawning no thread, when it cannot even be attempted" do
      outcome = relay.kick(999_999)

      expect(outcome.ok?).to be(false)
      expect(relay.last_relay_thread).to be_nil
    end
  end
end
