# frozen_string_literal: true

require "spec_helper"

# Minimal stand-ins: the sweep reads only a handful of things off each collaborator.
# Carries a body and #with because the sweep annotates every message it relays,
# and an author because the gate classifies the window through Core::GapReport.
BackfillMsg = Struct.new(:ref, :timestamp, :body, :author) do
  def initialize(ref, timestamp = nil, body = Rubotty::Core::RichText.plain("gap"), author = nil)
    super
  end

  def with(**changes)
    self.class.new(changes.fetch(:ref, ref),
                   changes.fetch(:timestamp, timestamp),
                   changes.fetch(:body, body),
                   changes.fetch(:author, author))
  end
end

# A reaction candidate, carrying just what a reaction_add Core::Message exposes
# to the claim key: the ref, the actor's native id and the canonical key.
BackfillReaction = Struct.new(:ref, :author, :reaction)
BackfillActor = Struct.new(:native_id)

class BackfillFakeAdapter
  attr_reader :ingested, :sinces, :limit, :reaction_limits

  def initialize(messages: [], supports: true, reactions: {}, supports_reactions: true)
    @messages = messages
    @supports = supports
    # native_id => [reaction candidates on that message]
    @reactions = reactions
    @supports_reactions = supports_reactions
    @ingested = []
    @reaction_limits = []
    @sinces = []
  end

  # Where the RELAY pass started reading. The proposal gate asks for its own,
  # wider window through the same method afterwards, so the first ask is the
  # one resume_from decided.
  def since = @sinces.first

  # Where the proposal gate started reading.
  def proposal_since = @sinces.last

  def supports_backfill? = @supports

  def supports_reaction_backfill? = @supports_reactions

  # A platform the gate's classifier cannot ask, which is Adapters::Base's own
  # answer and the fallback every non-Discord adapter takes.
  def supports_gap_ownership? = false

  # Records the request so a test can assert it, and returns the canned history.
  def backfill_messages(_endpoint, since:, limit:)
    @sinces << since
    @limit = limit
    @messages
  end

  # Caps at the budget it was asked for, as the real adapter's fetch is bounded.
  def backfill_reactions(_endpoint, native_id, limit:)
    @reaction_limits << limit
    @reactions.fetch(native_id.to_s, []).first(limit)
  end

  def ingest(message) = @ingested << message
end

class BackfillFakeCommunity
  attr_reader :id, :slug, :channels, :rooms

  def initialize(id:, channels:, enabled:, config: {}, slug: "sample", rooms: [])
    @id = id
    @slug = slug
    @channels = channels
    @enabled = enabled
    @config = config
    @rooms = rooms
  end

  def feature_enabled?(_channel, feature) = feature == "backfill" && @enabled

  def feature_config(_channel, _feature) = @config
end

RSpec.describe Rubotty::Core::Backfill do
  def ref(native) = Rubotty::Core::MessageRef.new("dc-general", native)

  let(:now) { Time.at(2_000_000_000) }
  let(:endpoint) { double("endpoint", id: "dc-general") }
  let(:mapped_at) { nil }
  let(:channel) do
    double("channel", endpoint: endpoint, adapter: :discord, account: "dc", mapped_at: mapped_at)
  end

  # Three recent messages, well inside the safe horizon.
  let(:messages) do
    [
      BackfillMsg.new(ref("100"), now - 180),
      BackfillMsg.new(ref("200"), now - 120),
      BackfillMsg.new(ref("300"), now - 60)
    ]
  end

  let(:adapter) { BackfillFakeAdapter.new(messages: messages) }
  let(:adapters) { { [:discord, "dc"] => adapter } }
  let(:last_relay_at) { nil }
  let(:rooms) { [] }
  let(:community) do
    BackfillFakeCommunity.new(id: "c1", channels: [channel], enabled: true, config: config, rooms: rooms)
  end
  let(:config) { {} }
  let(:snapshot) { double("snapshot", communities: [community]) }

  let(:storage) { instance_double(Rubotty::Storage::Memory) }
  let(:sleeps) { [] }
  # The pacing budget is spent against elapsed time, so the fake sleeper moves a
  # virtual clock by exactly what it was asked to wait. Without that the waits
  # below would read as the wall clock standing still through every sleep.
  let(:elapsed) { [0.0] }
  let(:monotonic) { -> { elapsed.first } }
  let(:sleeper) do
    lambda do |seconds|
      sleeps << seconds
      elapsed[0] += seconds
    end
  end
  let(:outcomes) { nil }

  subject(:backfill) do
    described_class.new(storage: storage, logger: nil, clock: -> { now }, sleeper: sleeper,
                        outcomes: outcomes, monotonic: monotonic)
  end

  before do
    allow(storage).to receive(:relay_claimed?).and_return(false)
    allow(storage).to receive(:last_relay_at).and_return(last_relay_at)
    # Read by the gate's classifier before it will call anything a gap.
    allow(storage).to receive(:destination?).and_return(false)
  end

  def run = backfill.run(adapters: adapters, snapshot: snapshot)

  it "relays every missed message through the adapter, oldest first" do
    run
    expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[100 200 300])
  end

  # A raise partway through the candidates loop must not lose the bookkeeping
  # for what already went out before it: those refs are still watched in
  # RelayOutcomes and have to be reconciled on the way out, the same way
  # relay_approved's own rescue does it.
  describe "a mid-sweep error after some sends already went out" do
    let(:outcomes) { Rubotty::Core::RelayOutcomes.new(logger: nil, monotonic: monotonic) }

    it "still reconciles the refs sent before the error, rather than leaking their watched outcome" do
      boom_native_id = messages[1].ref.native_id
      allow(adapter).to receive(:ingest) do |message|
        raise "boom mid-sweep" if message.ref.native_id == boom_native_id

        outcomes.abandoned(message.ref, "dc-general", "gave up")
      end

      errors = []
      logger = instance_double(Logger, info: nil, warn: nil, debug: nil)
      allow(logger).to receive(:error) { |&block| errors << block.call }
      described_class.new(storage: storage, logger: logger, clock: -> { now }, sleeper: sleeper,
                          outcomes: outcomes, monotonic: monotonic)
                     .run(adapters: adapters, snapshot: snapshot)

      expect(errors.join("\n")).to include("were relayed and never arrived", "dc-general:100")
    end
  end

  # A gap message lands hours late, next to whatever is being said now, so it has
  # to say what it is or it reads as somebody replying to the wrong thing.
  describe "the recovery note" do
    it "says when the message was originally sent" do
      run
      relayed = adapter.ingested.first

      expect(relayed.body.to_s).to start_with("gap\n")
      expect(relayed.body.to_s).to include("(Message recovered; originally sent on ")
      expect(relayed.body.to_s).to include(" UTC.)")
    end

    it "italicises the note and not the message" do
      run
      body = adapter.ingested.first.body
      italic = body.spans.find { |span| span.kind == :italic }

      expect(italic).not_to be_nil
      expect(body.text[italic.begin_index...italic.end_index]).to start_with("(Message recovered")
      expect(body.text[0, 3]).to eq("gap")
    end

    it "still says so when the platform gave no timestamp" do
      messages.replace([BackfillMsg.new(ref("400"), nil)])
      run

      expect(adapter.ingested.first.body.to_s)
        .to include("(Message recovered; it was sent while the bridge was down.)")
    end

    # The note is read by whoever is in the room, so the date is spelled the way
    # somebody would say it out loud.
    context "when the message is from the first of the month" do
      let(:now) { Time.utc(2026, 8, 3, 12, 0) }

      it "writes the date in full, with an ordinal day" do
        messages.replace([BackfillMsg.new(ref("500"), Time.utc(2026, 8, 1, 21, 39))])
        run

        expect(adapter.ingested.first.body.to_s)
          .to include("(Message recovered; originally sent on August 1st at 21:39 UTC.)")
      end

      it "gives each of the first three days its own suffix" do
        messages.replace([
                           BackfillMsg.new(ref("501"), Time.utc(2026, 8, 1, 9, 0)),
                           BackfillMsg.new(ref("502"), Time.utc(2026, 8, 2, 9, 0)),
                           BackfillMsg.new(ref("503"), Time.utc(2026, 8, 3, 9, 0))
                         ])
        run

        expect(adapter.ingested.map { |message| message.body.to_s[/August \S+/] })
          .to eq(["August 1st", "August 2nd", "August 3rd"])
      end
    end

    # 11, 12 and 13 end in 1, 2 and 3 but take "th", which is the usual bug.
    context "when the message is from the teens" do
      let(:now) { Time.utc(2026, 8, 13, 12, 0) }

      it "spells the teens the way English does" do
        messages.replace([
                           BackfillMsg.new(ref("511"), Time.utc(2026, 8, 11, 9, 0)),
                           BackfillMsg.new(ref("512"), Time.utc(2026, 8, 12, 9, 0)),
                           BackfillMsg.new(ref("513"), Time.utc(2026, 8, 13, 9, 0))
                         ])
        run

        expect(adapter.ingested.map { |message| message.body.to_s[/August \S+/] })
          .to eq(["August 11th", "August 12th", "August 13th"])
      end
    end

    # The note is for a replayed message. A live one must arrive untouched.
    it "is added by the sweep, not by the adapter, so live traffic is unaffected" do
      run
      expect(messages.first.body.to_s).to eq("gap")
    end
  end

  it "paces one relayed action per configured interval" do
    run
    # interval_ms default 1000 => 1.0s between each relayed message.
    expect(sleeps).to eq([1.0, 1.0, 1.0])
  end

  it "skips a message already relayed, and does not pace the skip" do
    allow(storage).to receive(:relay_claimed?) do |source:, operation:, community:|
      operation == "new" && community == "c1" && source.native_id == "200"
    end
    run
    expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[100 300])
    expect(sleeps).to eq([1.0, 1.0])
  end

  it "does nothing when the feature is disabled for the community" do
    allow(community).to receive(:feature_enabled?).and_return(false)
    run
    expect(adapter.ingested).to be_empty
  end

  it "skips an adapter that cannot reconstruct history" do
    allow(adapter).to receive(:supports_backfill?).and_return(false)
    run
    expect(adapter.ingested).to be_empty
  end

  it "is a no-op without a control plane snapshot" do
    expect { backfill.run(adapters: adapters, snapshot: nil) }.not_to raise_error
    expect(backfill.start(adapters: adapters, snapshot: nil)).to be_nil
    expect(adapter.ingested).to be_empty
  end

  context "with a max_messages cap of 2" do
    let(:config) { { max_messages: 2 } }

    it "relays only up to the cap, leaving the older gap unsynced" do
      run
      expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[100 200])
    end
  end

  it "never relays a message older than the safe horizon, where dedup may have lapsed" do
    messages << BackfillMsg.new(ref("ancient"), now - (73 * 60 * 60))
    run
    expect(adapter.ingested.map { |message| message.ref.native_id }).not_to include("ancient")
  end

  it "treats a dedup-check failure as already relayed, so a hiccup cannot flood" do
    allow(storage).to receive(:relay_claimed?).and_raise(Rubotty::StorageError.new("db down"))
    run
    expect(adapter.ingested).to be_empty
  end

  it "falls back to the lookback window for a channel with no relay and no mapping time" do
    run
    expect(adapter.since).to be_within(1).of(now - (72 * 60 * 60))
    expect(adapter.limit).to eq(2_000)
  end

  # A flat window replays history nobody bridged the moment a channel is mapped,
  # which is the whole reason this feature could not be on by default.
  describe "where the sweep starts" do
    context "when the channel has relayed recently" do
      let(:last_relay_at) { now - 600 }

      it "resumes from the last relay rather than the whole window" do
        run
        expect(adapter.since).to be_within(1).of(now - 600)
      end

      it "asks storage for that endpoint in that community" do
        run
        expect(storage).to have_received(:last_relay_at).with(endpoint: "dc-general", community: "c1")
      end

      # The watermark is what keeps the unattended path cheap and idempotent, so
      # it stays on the relay pass; only the proposal gate reads behind it,
      # because a person sees a proposal before any of it goes anywhere.
      it "classifies the whole window for a proposal, watermark or no watermark" do
        run
        expect(adapter.proposal_since).to be_within(1).of(now - (72 * 60 * 60))
      end
    end

    context "when the channel was mapped into a room a minute ago" do
      let(:mapped_at) { now - 60 }

      it "starts at the mapping, so nothing said before the bridge existed is replayed" do
        run
        expect(adapter.since).to be_within(1).of(now - 60)
      end

      it "holds the proposal gate at the mapping too" do
        run
        expect(adapter.proposal_since).to be_within(1).of(now - 60)
      end
    end

    context "when it has both" do
      let(:mapped_at) { now - 3600 }
      let(:last_relay_at) { now - 300 }

      it "takes the later of the two" do
        run
        expect(adapter.since).to be_within(1).of(now - 300)
      end
    end

    context "when both are older than the lookback" do
      let(:mapped_at) { now - (30 * 24 * 60 * 60) }
      let(:last_relay_at) { now - (80 * 60 * 60) }

      it "still reaches no further back than the window" do
        run
        expect(adapter.since).to be_within(1).of(now - (72 * 60 * 60))
      end
    end

    it "falls back to the window when the ledger cannot be read" do
      allow(storage).to receive(:last_relay_at).and_raise(Rubotty::StorageError.new("db down"))
      run
      expect(adapter.since).to be_within(1).of(now - (72 * 60 * 60))
    end
  end

  # Eight discovered channels the bot was never granted Read Message History on
  # printed eight ERROR lines on every single boot, which made a clean start look
  # broken and buried the failures that deserve the colour.
  describe "a channel whose history we are not allowed to read" do
    let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
    let(:infos) { [] }
    let(:errors) { [] }

    subject(:backfill) do
      described_class.new(storage: storage, logger: logger, clock: -> { now }, sleeper: sleeper)
    end

    before do
      allow(logger).to receive(:info) { |&block| infos << block.call }
      allow(logger).to receive(:error) { |&block| errors << block.call }
      allow(adapter).to receive(:backfill_messages)
        .and_raise(Rubotty::PermissionError.new("discord: cannot fetch history for 1: no", adapter: :discord))
    end

    it "says so once, at info, rather than at error" do
      run

      expect(errors).to be_empty
      expect(infos.last).to include("cannot read history on 1 channel(s)")
      expect(infos.last).to include("dc-general")
    end

    it "tells the operator what would make it work" do
      run

      expect(infos.last).to include("Read Message History")
    end

    # The distinction that matters: a real fault still gets a red line.
    it "still reports any other failure at error" do
      allow(adapter).to receive(:backfill_messages).and_raise(Rubotty::AdapterError.new("boom", adapter: :discord))
      run

      expect(errors.first).to include("backfill for dc-general failed")
      expect(infos).not_to include(a_string_matching(/cannot read history/))
    end

    it "says nothing at all when every channel is readable" do
      allow(adapter).to receive(:backfill_messages).and_return([])
      run

      expect(infos).not_to include(a_string_matching(/cannot read history/))
    end
  end

  describe "the boot notice for a channel that has opted out" do
    let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
    let(:warnings) { [] }

    subject(:backfill) do
      described_class.new(storage: storage, logger: logger, clock: -> { now }, sleeper: sleeper)
    end

    before do
      allow(logger).to receive(:warn) { |&block| warnings << block.call }
    end

    it "names a backfill-capable channel whose feature is off" do
      allow(community).to receive(:feature_enabled?).and_return(false)
      run

      expect(warnings.first).to include("backfill is OFF on 1 channel(s)")
      expect(warnings.first).to include("sample/dc-general")
    end

    it "says nothing about a channel whose platform could not backfill anyway" do
      allow(community).to receive(:feature_enabled?).and_return(false)
      allow(adapter).to receive(:supports_backfill?).and_return(false)
      run

      expect(warnings).to be_empty
    end

    it "says nothing when the feature is on" do
      run
      expect(warnings).to be_empty
    end
  end

  # The incident this guards against was lookback_seconds and
  # safe_horizon_seconds both set to a week, by someone who thought raising the
  # lookback also raised what could be relayed. resume_from already bounds the
  # sweep to whichever is smaller, so this is a warning, not a refusal.
  describe "the boot notice for a lookback set past the horizon" do
    let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
    let(:warnings) { [] }

    subject(:backfill) do
      described_class.new(storage: storage, logger: logger, clock: -> { now }, sleeper: sleeper)
    end

    before do
      allow(logger).to receive(:warn) { |&block| warnings << block.call }
    end

    it "names a channel whose lookback reaches past its horizon" do
      config.replace(lookback_seconds: 604_800, safe_horizon_seconds: 259_200)
      run

      expect(warnings.first).to include("lookback_seconds is set past safe_horizon_seconds on 1 channel(s)")
      expect(warnings.first).to include("sample/dc-general")
    end

    it "says nothing when the lookback stays under the horizon" do
      config.replace(lookback_seconds: 100_000, safe_horizon_seconds: 259_200)
      run

      expect(warnings).to be_empty
    end

    it "says nothing for the equal case, only for strictly past" do
      config.replace(lookback_seconds: 259_200, safe_horizon_seconds: 259_200)
      run

      expect(warnings).to be_empty
    end
  end

  # A relayed gap message also resyncs the reactions it accrued while the bot was
  # down, on the same paced path, where the react claim dedups a re-run.
  describe "reaction backfill" do
    let(:messages) { [BackfillMsg.new(ref("100"), now - 60)] }
    let(:thumb) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:reaction) { BackfillReaction.new(ref("100"), BackfillActor.new("55"), thumb) }
    let(:adapter) do
      BackfillFakeAdapter.new(messages: messages, reactions: { "100" => [reaction] })
    end

    # The claim key the bridge would use, so a test can mark the reaction
    # already-relayed exactly as a prior run would have left it.
    def react_claim(source:, operation:, community:)
      operation == "react:55:emoji:👍" && community == "c1" && source.native_id == "100"
    end

    it "relays a missed reaction on a message it just relayed" do
      run
      expect(adapter.ingested.map(&:ref)).to eq([messages.first.ref, reaction.ref])
    end

    it "paces the reaction on the same one-per-second budget as the message" do
      run
      expect(sleeps).to eq([1.0, 1.0])
    end

    it "deduplicates a reaction whose claim is already present, without pacing it" do
      # A re-run: the message is unclaimed and the reaction is already claimed,
      # so only the message crosses.
      allow(storage).to receive(:relay_claimed?) do |source:, operation:, community:|
        react_claim(source: source, operation: operation, community: community)
      end
      run
      expect(adapter.ingested.map(&:ref)).to eq([messages.first.ref])
      expect(sleeps).to eq([1.0])
    end

    it "does not fetch reactions for a message it skipped as already relayed" do
      allow(storage).to receive(:relay_claimed?) do |source:, operation:, community:|
        operation == "new" && source.native_id == "100"
      end
      run
      expect(adapter.ingested).to be_empty
      expect(adapter.reaction_limits).to be_empty
    end

    it "skips reaction backfill for an adapter that cannot read history reactions" do
      allow(adapter).to receive(:supports_reaction_backfill?).and_return(false)
      run
      expect(adapter.ingested.map(&:ref)).to eq([messages.first.ref])
      expect(adapter.reaction_limits).to be_empty
    end

    context "with a max_reactions cap of 1" do
      let(:config) { { max_reactions: 1 } }
      let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }
      let(:second) { BackfillReaction.new(ref("100"), BackfillActor.new("77"), party) }
      let(:adapter) do
        BackfillFakeAdapter.new(messages: messages, reactions: { "100" => [reaction, second] })
      end

      it "relays only up to the cap and bounds the fetch to the remaining budget" do
        run
        expect(adapter.ingested.map(&:ref)).to eq([messages.first.ref, reaction.ref])
        expect(adapter.reaction_limits).to eq([1])
      end
    end
  end

  # #relay_approved: the bot side of the proposal handoff, over the
  # same paced, deduped path #run uses, but for a caller-supplied whitelist of
  # native ids rather than whatever the classifier would decide today.
  describe "#relay_approved" do
    def target = backfill.sweepable(adapters: adapters, snapshot: snapshot).first

    it "relays exactly the requested ids, in the order given, paced the same way a sweep is" do
      result = backfill.relay_approved(target: target, native_ids: %w[300 100], since: now - 300)

      expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[300 100])
      expect(sleeps).to eq([1.0, 1.0])
      expect(result.relayed).to eq(2)
      expect(result.skipped).to eq(0)
      expect(result.missing).to eq(0)
      expect(result.error).to be_nil
    end

    it "never relays an id outside the requested whitelist, even though it was fetched" do
      backfill.relay_approved(target: target, native_ids: %w[100], since: now - 300)

      expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[100])
    end

    it "counts a requested id the adapter no longer returns as missing rather than relaying nothing" do
      result = backfill.relay_approved(target: target, native_ids: %w[100 999], since: now - 300)

      expect(result.relayed).to eq(1)
      expect(result.missing).to eq(1)
    end

    it "skips an id already relayed, and does not pace the skip" do
      allow(storage).to receive(:relay_claimed?) do |source:, operation:, community:|
        operation == "new" && community == "c1" && source.native_id == "200"
      end

      result = backfill.relay_approved(target: target, native_ids: %w[100 200], since: now - 300)

      expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[100])
      expect(result.relayed).to eq(1)
      expect(result.skipped).to eq(1)
      expect(sleeps).to eq([1.0])
    end

    context "with a max_messages cap of 1" do
      let(:config) { { max_messages: 1 } }

      it "stops at the cap and reports the rest as capped, not relayed" do
        result = backfill.relay_approved(target: target, native_ids: %w[100 200], since: now - 300)

        expect(adapter.ingested.map { |message| message.ref.native_id }).to eq(%w[100])
        expect(result.relayed).to eq(1)
        expect(result.capped).to eq(1)
      end
    end

    it "reports a fetch failure as an error rather than raising" do
      # #sweepable never calls backfill_messages itself, so resolving the
      # target first is safe even once the stub below makes every fetch raise.
      resolved = target
      allow(adapter).to receive(:backfill_messages).and_raise(Rubotty::AdapterError.new("boom", adapter: :discord))

      result = backfill.relay_approved(target: resolved, native_ids: %w[100], since: now - 300)

      expect(result.error).to include("boom")
      expect(result.relayed).to eq(0)
    end

    it "is a no-op, with no error, when given no ids" do
      result = backfill.relay_approved(target: target, native_ids: [], since: now - 300)

      expect(adapter.ingested).to be_empty
      expect(result.error).to be_nil
    end
  end

  # interval_ms used to be spent once per SOURCE action, and a source
  # message fans out to every endpoint in the room, so a room holding Telegram
  # and one other platform ran at twice the rate the knob described and took a
  # 429 on the first real restore. The budget is now counted per destination.
  describe "per destination pacing" do
    def endpoint_for(id, adapter_name)
      Rubotty::Core::Endpoint.new(id: id, adapter_name: adapter_name, account: "main")
    end

    # sample's general as it actually is: one Discord source, two destinations.
    let(:rooms) do
      [
        Rubotty::Core::Room.new(
          id: "general",
          endpoints: [
            endpoint_for("dc-general", :discord),
            endpoint_for("tg-general", :telegram),
            endpoint_for("st-general", :stoat)
          ]
        )
      ]
    end
    let(:outcomes) { Rubotty::Core::RelayOutcomes.new(logger: nil, monotonic: monotonic) }

    # When each handover happened, in virtual seconds since the sweep began.
    let(:moments) { [] }

    before do
      allow(adapter).to receive(:ingest).and_wrap_original do |original, message|
        moments << elapsed.first
        original.call(message)
      end
    end

    def destination_ids = rooms.first.targets_for(endpoint).map(&:id)

    it "holds each destination in the room to one send per configured interval" do
      run

      # A handover is one send to tg-general and one to st-general at the same
      # moment, so the gap between handovers is the gap each of them sees.
      expect(destination_ids).to contain_exactly("tg-general", "st-general")
      gaps = moments.each_cons(2).map { |earlier, later| later - earlier }
      expect(gaps).to all(be >= 1.0)
    end

    it "costs a two destination room no more wall clock than a one destination room" do
      run
      expect(sleeps).to eq([1.0, 1.0, 1.0])
    end

    context "when Telegram answers with a retry_after" do
      # The shape of the incident: the copy to tg-general is refused ONCE, and
      # the platform names the wait it wants before any retry is spent.
      before do
        refused = false
        allow(adapter).to receive(:ingest).and_wrap_original do |original, message|
          moments << elapsed.first
          unless refused
            refused = true
            outcomes.rate_limited("tg-general", 27)
          end
          original.call(message)
        end
      end

      it "paces that destination at the rate the platform named, for the rest of the sweep" do
        run

        # Refused once, and every wait after it runs at the rate Telegram asked
        # for rather than dropping back to the configured interval and being
        # refused again on the message after next.
        expect(sleeps).to eq([27.0, 27.0, 27.0])
      end

      it "never inherits that slowdown into a later sweep" do
        run
        sleeps.clear
        elapsed[0] += 600

        backfill.run(adapters: adapters, snapshot: snapshot)
        expect(sleeps).to eq([1.0, 1.0, 1.0])
      end

      context "with max_interval_ms holding how slow a destination may go" do
        let(:config) { { max_interval_ms: 5_000 } }

        it "never paces slower than the operator allowed" do
          run
          expect(sleeps).to eq([5.0, 5.0, 5.0])
        end
      end
    end

    # A copy the bridge gave up on is a message that never arrived, so the count
    # has to say so rather than reporting the handover as an arrival.
    describe "a delivery that spends every retry it has" do
      def target = backfill.sweepable(adapters: adapters, snapshot: snapshot).first

      before do
        lost = messages.first.ref
        allow(adapter).to receive(:ingest).and_wrap_original do |original, message|
          outcomes.abandoned(message.ref, "tg-general", "Too Many Requests") if message.ref == lost
          original.call(message)
        end
      end

      it "is reported as abandoned rather than counted as relayed" do
        result = backfill.relay_approved(target: target, native_ids: %w[100 200], since: now - 300)

        expect(result.relayed).to eq(1)
        expect(result.abandoned).to eq(1)
        expect(result.capped).to eq(0)
        expect(result.error).to be_nil
      end

      it "is reported the same way on an unattended sweep" do
        errors = []
        logger = instance_double(Logger, info: nil, warn: nil, debug: nil)
        allow(logger).to receive(:error) { |&block| errors << block.call }
        described_class.new(storage: storage, logger: logger, clock: -> { now }, sleeper: sleeper,
                            outcomes: outcomes, monotonic: monotonic)
                       .run(adapters: adapters, snapshot: snapshot)

        expect(errors.join("\n")).to include("were relayed and never arrived", "dc-general:100", "tg-general")
      end

      # The cap is what stopped the loop, so it is the raw count that decides
      # whether older history was left behind. Reading it off the count with the
      # abandoned copy already taken out made a run that hit the cap read as one
      # that had caught up, and an operator would never go looking for the rest.
      context "on a run that also hit the message cap" do
        let(:config) { { max_messages: 2 } }

        it "still says the older gap was left unsynced" do
          notes = []
          logger = instance_double(Logger, warn: nil, debug: nil, error: nil)
          allow(logger).to receive(:info) { |&block| notes << block.call }
          described_class.new(storage: storage, logger: logger, clock: -> { now }, sleeper: sleeper,
                              outcomes: outcomes, monotonic: monotonic)
                         .run(adapters: adapters, snapshot: snapshot)

          expect(notes.join("\n")).to include("capped at 2 (older gap left unsynced)")
        end
      end
    end

    # relay_approved reconciles on its way out of a failure; sweep did not, so a
    # candidate that raised partway through left every ref handed over before it
    # parked in RelayOutcomes for the life of the process, and a copy that never
    # arrived was never counted as abandoned.
    describe "an error partway through the loop, after some copies have gone out" do
      before do
        lost = messages.first.ref
        seen = 0
        allow(adapter).to receive(:ingest).and_wrap_original do |original, message|
          seen += 1
          outcomes.abandoned(message.ref, "tg-general", "Too Many Requests") if message.ref == lost
          raise Rubotty::AdapterError.new("boom", adapter: :discord) if seen == 2

          original.call(message)
        end
      end

      it "still reconciles what it had already handed over" do
        errors = []
        logger = instance_double(Logger, info: nil, warn: nil, debug: nil)
        allow(logger).to receive(:error) { |&block| errors << block.call }
        described_class.new(storage: storage, logger: logger, clock: -> { now }, sleeper: sleeper,
                            outcomes: outcomes, monotonic: monotonic)
                       .run(adapters: adapters, snapshot: snapshot)

        expect(errors.join("\n")).to include("were relayed and never arrived", "dc-general:100")
      end

      it "leaves nothing parked in the outcomes afterwards" do
        described_class.new(storage: storage, logger: nil, clock: -> { now }, sleeper: sleeper,
                            outcomes: outcomes, monotonic: monotonic)
                       .run(adapters: adapters, snapshot: snapshot)

        expect(outcomes.reconcile(messages.map(&:ref)).lost).to eq(0)
      end
    end

    it "still costs nothing when there is nothing missing" do
      allow(storage).to receive(:relay_claimed?).and_return(true)
      run

      expect(sleeps).to be_empty
      expect(elapsed.first).to eq(0.0)
    end
  end
end
