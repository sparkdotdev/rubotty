# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Rubotty::Features::TopicRouting do
  let(:service) { instance_double(Rubotty::SemanticAnalysis::TopicRouter) }
  let(:context) { Struct.new(:message).new("private message").freeze }

  it "queues one background check and leaves delivery to the bridge" do
    expect(service).to receive(:enqueue).with(context).once
    feature = described_class.new(logger: Rubotty::Log.null, service: service)

    outcome = feature.call(context)

    expect(outcome).to be_continue
    expect(outcome.value).to eq([])
    expect(context.message).to eq("private message")
  end

  it "leaves messages flowing when the optional service is not configured" do
    feature = described_class.new(logger: Rubotty::Log.null)

    expect(feature.call(context)).to be_continue
  end

  it "contains queue failures without logging message text or credential details" do
    log = StringIO.new
    logger = Rubotty::Log.build(level: "warn", io: log)
    allow(service).to receive(:enqueue).and_raise(RuntimeError, "private message and credential details")
    feature = described_class.new(logger: logger, service: service)

    expect(feature.call(context)).to be_continue
    expect(log.string).to include("could not queue room work", "RuntimeError")
    expect(log.string).not_to include("private message", "credential details")
  end
end

RSpec.describe Rubotty::Features::TopicRoutingMoves do
  %i[confirm_within_hours training_retention_days].each do |field|
    [0, -1].each do |value|
      it "rejects #{field}=#{value} in its declared configuration contract" do
        result = described_class.config_schema.call({ field => value })

        expect(result).not_to be_valid
        expect(result.problems).to include("must be a positive number of #{field == :confirm_within_hours ? 'hours' : 'days'}")
      end
    end

    it "accepts a positive #{field} without changing the configured value" do
      result = described_class.config_schema.call({ field => 2 })

      expect(result).to be_valid
      expect(result.value[field]).to eq(2)
    end
  end
end
