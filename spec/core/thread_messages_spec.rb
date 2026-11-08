# frozen_string_literal: true

require "spec_helper"

# A message's real channel is learned once, from the thread it arrived in,
# then looked back up whenever a later action needs to address it directly.
RSpec.describe Rubotty::Core::ThreadMessages do
  let(:store) { Rubotty::Storage::Memory.new }

  subject(:messages) { described_class.new(store: store) }

  it "returns the learned channel for its scope and message id" do
    messages.learn(scope: "dc", native_id: 700, channel_id: 9999)
    expect(messages.channel_for(scope: "dc", native_id: 700)).to eq("9999")
  end

  it "stringifies the message id so an Integer learn matches a String lookup" do
    messages.learn(scope: "dc", native_id: 700, channel_id: 9999)
    expect(messages.channel_for(scope: "dc", native_id: "700")).to eq("9999")
  end

  it "returns nil for a message it never learned" do
    expect(messages.channel_for(scope: "dc", native_id: 999)).to be_nil
  end

  it "scopes by the namespace, so the same message id on two accounts does not collide" do
    messages.learn(scope: "acc-a", native_id: 5, channel_id: "111")
    messages.learn(scope: "acc-b", native_id: 5, channel_id: "222")
    expect(messages.channel_for(scope: "acc-a", native_id: 5)).to eq("111")
    expect(messages.channel_for(scope: "acc-b", native_id: 5)).to eq("222")
  end

  it "is a no-op with no durable store wired, so the feature simply stays dormant" do
    dormant = described_class.new(store: nil)
    expect { dormant.learn(scope: "dc", native_id: 1, channel_id: "2") }.not_to raise_error
    expect(dormant.channel_for(scope: "dc", native_id: 1)).to be_nil
  end

  it "never lets a storage fault break the caller" do
    faulty = Class.new do
      def get_state(_key) = raise Rubotty::StorageError, "down"
      def put_state(_key, _value, expires_at: nil) = raise Rubotty::StorageError, "down"
    end.new
    resilient = described_class.new(store: faulty)
    expect { resilient.learn(scope: "dc", native_id: 1, channel_id: "2") }.not_to raise_error
    expect(resilient.channel_for(scope: "dc", native_id: 1)).to be_nil
  end

  it "keeps the stored key within the bridge_state column bound for long platform ids" do
    long_scope = "a" * 90
    long_native_id = "b" * 90
    key = messages.send(:key, long_scope, long_native_id)
    expect(key.length).to be <= 128
  end

  it "logs a warning instead of silently swallowing a write failure" do
    logger = double("logger")
    faulty = Class.new do
      def get_state(_key) = raise Rubotty::StorageError, "down"
      def put_state(_key, _value, expires_at: nil) = raise Rubotty::StorageError, "down"
    end.new
    logged = described_class.new(store: faulty, logger: logger)

    expect(logger).to receive(:warn)
    logged.learn(scope: "dc", native_id: 1, channel_id: "2")
  end
end
