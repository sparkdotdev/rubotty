# frozen_string_literal: true

require "spec_helper"

# Records every line at every level, so a spec can assert what got logged
# without depending on Rubotty::Log's formatting.
class HistorySweepFakeLogger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def info = @lines << yield
  def warn = @lines << yield
  def debug = @lines << yield
end

class HistorySweepFakeAdapter
  attr_reader :deleted

  def initialize(own_account_id:, messages: [], supports_backfill: true, deletes: true, own_account_ids: nil)
    @own_account_id = own_account_id
    @own_account_ids = own_account_ids
    @messages = messages
    @supports_backfill = supports_backfill
    @deletes = deletes
    @deleted = []
  end

  def own_account_id = @own_account_id

  def own_account_ids = @own_account_ids || [@own_account_id].compact

  def supports_backfill? = @supports_backfill

  def backfill_messages(_endpoint, since:, limit:) = @messages

  def capabilities_for(_endpoint) = Rubotty::Adapters::Capabilities.new(deletes: @deletes)

  def delete(_endpoint, native_id)
    raise "cannot delete on this fake" unless @deletes

    @deleted << native_id.to_s
  end
end

# The fallback for a stray with NO durable row: a bounded history scan, so these
# specs pin the strict matching that keeps it off the wrong message.
RSpec.describe Rubotty::Core::HistorySweep do
  let(:dc) { endpoint("dc-general", adapter: :discord, account: "acc") }
  let(:live_topology) { topology(room("general", dc)) }

  def adapters_with(adapter) = { [:discord, "acc"] => adapter }

  def banner_text = "Started rubotty at Wed, 24 Jul 2026 12:00:00 GMT.\nrubotty version: 1.2.5"

  def banner(native_id:, author_id:, text: banner_text)
    message(dc, native_id: native_id, text: text, author: Rubotty::Core::Author.new(native_id: author_id))
  end

  it "removes a straggler banner authored by the bot's own account" do
    stray = banner(native_id: "700", author_id: "bot-1")
    adapter = HistorySweepFakeAdapter.new(own_account_id: "bot-1", messages: [stray])

    removed = described_class.new(adapters: adapters_with(adapter), topology: live_topology).sweep

    expect(removed).to eq(1)
    expect(adapter.deleted).to eq(["700"])
  end

  it "removes a straggler banner authored under a fallback nick the adapter also owns" do
    stray = banner(native_id: "701", author_id: "bridge_")
    adapter = HistorySweepFakeAdapter.new(
      own_account_id: "bridge", own_account_ids: ["bridge", "bridge_"], messages: [stray]
    )

    removed = described_class.new(adapters: adapters_with(adapter), topology: live_topology).sweep

    expect(removed).to eq(1)
    expect(adapter.deleted).to eq(["701"])
  end

  it "never touches a message from another author, even one that shapes exactly like the banner" do
    someone_elses = banner(native_id: "701", author_id: "some-member")
    adapter = HistorySweepFakeAdapter.new(own_account_id: "bot-1", messages: [someone_elses])

    removed = described_class.new(adapters: adapters_with(adapter), topology: live_topology).sweep

    expect(removed).to eq(0)
    expect(adapter.deleted).to be_empty
  end

  it "never matches a loose substring, only the banner's own anchored shape" do
    chatter = message(
      dc, native_id: "702",
      text: "haha did you see it said \"Started rubotty at\" earlier, so funny",
      author: Rubotty::Core::Author.new(native_id: "bot-1")
    )
    adapter = HistorySweepFakeAdapter.new(own_account_id: "bot-1", messages: [chatter])

    removed = described_class.new(adapters: adapters_with(adapter), topology: live_topology).sweep

    expect(removed).to eq(0)
    expect(adapter.deleted).to be_empty
  end

  it "skips, and logs, an endpoint on an adapter that cannot read history (Telegram)" do
    tg = endpoint("tg-general", adapter: :telegram, account: "acc")
    tg_topology = topology(room("general", tg))
    adapter = HistorySweepFakeAdapter.new(own_account_id: "bot-1", supports_backfill: false)
    logger = HistorySweepFakeLogger.new

    removed = described_class.new(
      adapters: { [:telegram, "acc"] => adapter }, topology: tg_topology, logger: logger
    ).sweep

    expect(removed).to eq(0)
    expect(logger.lines.any? { |line| line.include?("cannot read history") }).to be(true)
  end

  it "skips an endpoint whose adapter cannot delete messages" do
    stray = banner(native_id: "700", author_id: "bot-1")
    adapter = HistorySweepFakeAdapter.new(own_account_id: "bot-1", messages: [stray], deletes: false)

    removed = described_class.new(adapters: adapters_with(adapter), topology: live_topology).sweep

    expect(removed).to eq(0)
    expect(adapter.deleted).to be_empty
  end

  it "does nothing for an endpoint with no live adapter" do
    removed = described_class.new(adapters: {}, topology: live_topology).sweep
    expect(removed).to eq(0)
  end

  it "never raises when the adapter blows up mid-sweep" do
    adapter = HistorySweepFakeAdapter.new(own_account_id: "bot-1")
    allow(adapter).to receive(:backfill_messages).and_raise(RuntimeError.new("boom"))

    expect { described_class.new(adapters: adapters_with(adapter), topology: live_topology).sweep }.not_to raise_error
  end

  it "bounds the fetch to the configured limit and window" do
    adapter = HistorySweepFakeAdapter.new(own_account_id: "bot-1")
    allow(adapter).to receive(:backfill_messages).and_call_original
    sweep = described_class.new(adapters: adapters_with(adapter), topology: live_topology, window: 3600, limit: 42)

    expect(adapter).to receive(:backfill_messages).with(dc, since: kind_of(Time), limit: 42).and_return([])
    sweep.sweep
  end
end
