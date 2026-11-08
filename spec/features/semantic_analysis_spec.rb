# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::SemanticAnalysis do
  include Builders

  class SemanticFeatureService
    attr_reader :contexts

    def initialize = @contexts = []

    def enqueue(context) = @contexts << context
  end

  let(:endpoint) { Rubotty::Core::Endpoint.new(id: "telegram-general", adapter_name: :telegram, account: "default") }
  let(:service) { SemanticFeatureService.new }
  let(:feature) { described_class.new(logger: Rubotty::Log.null, service: service) }
  let(:context) do
    Struct.new(:message).new(message(endpoint, text: "where are the rules?"))
  end

  it "continues the bridge after scheduling its separate room job" do
    expect(feature.call(context)).to be_continue

    expect(service.contexts).to eq([context])
  end

  it "is inert without its durable service" do
    expect(described_class.new(logger: Rubotty::Log.null).call(context)).to be_continue
  end
end
