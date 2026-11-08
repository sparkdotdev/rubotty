# frozen_string_literal: true

require "spec_helper"

# Its own stand-ins rather than the ones backfill_spec defines at top level, so
# this file still runs when it is the only one loaded.
GapMsg = Struct.new(:ref, :timestamp, :author)

class GapFakeAdapter
  attr_reader :since, :limit, :ingested

  # +ownership+, when given, is a native id => :ours/:not_ours/:unknown map,
  # and is what turns on supports_gap_ownership? and #backfill_candidates,
  # the same seam a real adapter offers {Rubotty::Core::GapReport}. Left nil,
  # this fake answers exactly like one that cannot tell.
  def initialize(messages: [], supports: true, ownership: nil)
    @messages = messages
    @supports = supports
    @ownership = ownership
    @ingested = []
  end

  def supports_backfill? = @supports

  def supports_reaction_backfill? = false

  def supports_gap_ownership? = !@ownership.nil?

  def backfill_messages(_endpoint, since:, limit:)
    @since = since
    @limit = limit
    @messages
  end

  def backfill_candidates(_endpoint, since:, limit:)
    @since = since
    @limit = limit
    @messages.map { |message| [message, @ownership.fetch(message.ref.native_id, :not_ours)] }
  end

  def ingest(message) = @ingested << message
end

class GapFakeCommunity
  attr_reader :id, :slug, :channels

  def initialize(channels:, config: {}, slug: "sample")
    @id = "c1"
    @slug = slug
    @channels = channels
    @config = config
  end

  def feature_enabled?(_channel, feature) = feature == "backfill"

  def feature_config(_channel, _feature) = @config
end

RSpec.describe Rubotty::Core::GapReport do
  def ref(native) = Rubotty::Core::MessageRef.new("dc-general", native)

  let(:now) { Time.at(2_000_000_000) }
  let(:endpoint) { double("endpoint", id: "dc-general") }
  let(:channel) { double("channel", endpoint: endpoint, adapter: :discord, account: "dc", mapped_at: nil) }

  let(:messages) do
    [
      GapMsg.new(ref("100"), now - 180),
      GapMsg.new(ref("200"), now - 120),
      GapMsg.new(ref("300"), now - 60)
    ]
  end

  let(:adapter) { GapFakeAdapter.new(messages: messages) }
  let(:adapters) { { [:discord, "dc"] => adapter } }
  let(:community) { GapFakeCommunity.new(channels: [channel]) }
  let(:snapshot) { double("snapshot", communities: [community]) }
  let(:storage) { instance_double(Rubotty::Storage::Memory) }

  subject(:report) { described_class.new(storage: storage, logger: nil, clock: -> { now }) }

  before do
    allow(storage).to receive(:relay_claimed?).and_return(false)
    allow(storage).to receive(:destination?).and_return(false)
    allow(storage).to receive(:last_relay_at).and_return(nil)
  end

  def run = report.run(adapters: adapters, snapshot: snapshot)

  it "counts a message nothing has accounted for as a gap" do
    row = run.first

    expect(row.endpoint_id).to eq("dc-general")
    expect(row.community).to eq("sample")
    expect(row.fetched).to eq(3)
    expect(row.gaps).to eq(3)
    expect(row).to be_gap
  end

  # The whole reason this class exists: backfill starts at the LATEST of the
  # window, the last relay and the mapping time, so a hole with traffic after it
  # sits behind the start and can never be found. This reads the plain window.
  it "looks past the last relay, where the real sweep stops" do
    allow(storage).to receive(:last_relay_at).and_return(now - 30)

    run

    expect(adapter.since).to eq(now - Rubotty::Core::Backfill::DEFAULTS[:lookback_seconds])
  end

  it "does not count a message the relay ledger already claims" do
    allow(storage).to receive(:relay_claimed?).with(hash_including(source: messages[0].ref)).and_return(true)

    row = run.first

    expect(row.claimed).to eq(1)
    expect(row.gaps).to eq(2)
  end

  # Our own copy coming back from the far side. Its native id never had a claim
  # written against it, so a source-ref check alone would nominate it for a
  # second trip, which is the duplicate storm.
  it "recognises its own relayed copy and does not call it a gap" do
    allow(storage).to receive(:destination?).with(messages[1].ref).and_return(true)

    row = run.first

    expect(row.ours).to eq(1)
    expect(row.gaps).to eq(2)
  end

  # Neither the relay ledger nor the destination map can see a copy that
  # arrived through a webhook. The adapter can, when asked.
  it "counts a message the adapter reports as ours, not as a gap" do
    adapters[[:discord, "dc"]] = GapFakeAdapter.new(messages: messages, ownership: { "200" => :ours })

    row = run.first

    expect(row.ours).to eq(1)
    expect(row.gaps).to eq(2)
  end

  # Guessing wrong on an unknown answer is what sent our own copies back down
  # the bridge before, so the report makes the same cautious call the replay
  # path makes: unknown counts as ours, never as a gap.
  it "treats an unknown ownership answer the same cautious way the replay path treats it" do
    adapters[[:discord, "dc"]] = GapFakeAdapter.new(messages: messages, ownership: { "200" => :unknown })

    row = run.first

    expect(row.ours).to eq(1)
    expect(row.gaps).to eq(2)
  end

  # A platform GapReport cannot ask (Adapters::Base's default) must not break;
  # classification falls back to exactly what it did before this existed.
  it "leaves classification exactly as before when the adapter cannot answer ownership" do
    plain = GapFakeAdapter.new(messages: messages)
    adapters[[:discord, "dc"]] = plain
    allow(plain).to receive(:backfill_candidates)

    row = run.first

    expect(plain).not_to have_received(:backfill_candidates)
    expect(row.ours).to be_zero
    expect(row.gaps).to eq(3)
  end

  it "writes nothing even when the adapter answers ownership questions" do
    tagged = GapFakeAdapter.new(messages: messages, ownership: { "200" => :ours })
    adapters[[:discord, "dc"]] = tagged
    expect(storage).not_to receive(:claim_relay)

    run

    expect(tagged.ingested).to be_empty
  end

  it "gives a sample a reason and an author label, and still no message body" do
    author = Rubotty::Core::Author.new(display_name: "Alex R", username: "sample_owner", bot: true)
    echo = [GapMsg.new(ref("500"), now - 30, author)]
    adapters[[:discord, "dc"]] = GapFakeAdapter.new(messages: echo, ownership: { "500" => :ours })

    sample = run.first.samples.first

    expect(sample.reason).to eq(:ours_adapter)
    expect(sample.author).to eq("Alex R (bot)")
    expect(sample.members).not_to include(:body)
  end

  it "does not count anything below the safe horizon, where the claim may be pruned" do
    messages << GapMsg.new(ref("400"), now - (Rubotty::Core::Backfill::DEFAULTS[:safe_horizon_seconds] + 60))

    row = run.first

    expect(row.below_floor).to eq(1)
    expect(row.gaps).to eq(3)
  end

  it "relays nothing and claims nothing, whatever it finds" do
    expect(storage).not_to receive(:claim_relay)

    run

    expect(adapter.ingested).to be_empty
  end

  # Under-reporting is the safe direction: an unreadable ledger must not invent a
  # gap and talk somebody into replaying a channel that was fine.
  it "treats an unreadable ledger as already relayed" do
    allow(storage).to receive(:relay_claimed?).and_raise(Rubotty::StorageError, "down")

    row = run.first

    expect(row.gaps).to be_zero
    expect(row.claimed).to eq(3)
  end

  it "names a bounded sample of gap ids, and no message bodies" do
    row = run.first

    expect(row.samples.map(&:native_id)).to eq(%w[100 200 300])
    expect(row.samples.size).to be <= described_class::SAMPLE_LIMIT
    expect(row.samples.first.members).not_to include(:body)
    expect(row.samples.map(&:reason)).to all(eq(:gap))
  end

  it "puts the worst channel first" do
    quiet = double("channel", endpoint: double("endpoint", id: "dc-quiet"),
                              adapter: :discord, account: "quiet", mapped_at: nil)
    allow(community).to receive(:channels).and_return([quiet, channel])
    adapters[[:discord, "quiet"]] = GapFakeAdapter.new(messages: [GapMsg.new(ref("900"), now - 60)])

    expect(run.map(&:endpoint_id)).to eq(%w[dc-general dc-quiet])
  end

  it "reports a channel that raised rather than dropping it from the report" do
    allow(adapter).to receive(:backfill_messages).and_raise(Rubotty::AdapterError, "no permission")

    row = run.first

    expect(row.error).to include("no permission")
    expect(row.gaps).to be_zero
  end

  it "is empty without a control plane" do
    expect(report.run(adapters: adapters, snapshot: nil)).to eq([])
  end
end
