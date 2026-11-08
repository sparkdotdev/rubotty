# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::RoomSummaries do
  include Builders

  class SummaryFeatureService
    attr_reader :recorded, :queued, :dm_queued

    def initialize(pending: false)
      @pending = pending
      @recorded = []
      @queued = []
      @dm_queued = []
    end

    def record(context) = @recorded << context

    def pending?(_context) = @pending

    def enqueue_command(context)
      @queued << context
      :queued
    end

    def enqueue_dm(context)
      @dm_queued << context
      :queued
    end
  end

  SummaryFeatureContext = Struct.new(:message, :config, keyword_init: true) do
    def command_prefixes = Rubotty::Core::CommandPrefix.new
  end

  let(:endpoint) do
    Rubotty::Core::Endpoint.new(id: "telegram-general", adapter_name: :telegram, account: "default",
                                settings: { room_key: "k" })
  end
  let(:service) { SummaryFeatureService.new }
  let(:feature) do
    described_class.new(topology: topology(Rubotty::Core::Room.new(id: "general", endpoints: [endpoint])), adapters: {}, logger: Rubotty::Log.null,
                        summaries: service)
  end

  def context(text, config: { mode: "command" })
    SummaryFeatureContext.new(message: message(endpoint, text: text), config: config)
  end

  it "records ordinary chat messages for the later durable run" do
    expect(feature.call(context("hello"))).to be_continue

    expect(service.recorded.length).to eq(1)
  end

  it "silently consumes /summary when there is nothing new to summarize" do
    outcome = feature.call(context("/summary"))

    expect(outcome).to be_halt
    expect(service.queued).to be_empty
  end

  it "recognises !summary through the shared command markers" do
    pending = SummaryFeatureService.new(pending: true)
    feature = described_class.new(topology: topology(Rubotty::Core::Room.new(id: "general", endpoints: [endpoint])), adapters: {}, logger: Rubotty::Log.null,
                                  summaries: pending)

    feature.call(context("!summary"))

    expect(pending.queued.length).to eq(1)
  end

  it "acknowledges weekly/monthly/count modes without touching pending? or enqueue_command" do
    %w[weekly monthly count].each do |summary_mode|
      outcome = feature.call(context("/summary", config: { mode: summary_mode }))
      expect(outcome).to be_halt
    end

    expect(service.queued).to be_empty
  end

  # dm mode reads the last fourteen days whole rather than what is left since
  # the room's last posted summary, so "nothing pending" is a different
  # question and must not be asked here.
  describe "dm mode" do
    def dm_context(text) = context(text, config: { mode: "dm" })

    it "queues a private summary even with nothing pending for the room" do
      outcome = feature.call(dm_context("/summary"))

      expect(outcome).to be_halt
      expect(service.dm_queued.length).to eq(1)
    end

    it "never queues one to post in the room instead" do
      feature.call(dm_context("/summary"))

      expect(service.queued).to be_empty
    end
  end
end
