# frozen_string_literal: true

require "spec_helper"

# A thread's name is learned from the one event that carries it, then looked
# back up to name a threaded reply where the platform has no threads.
RSpec.describe Rubotty::Core::ThreadNames do
  let(:store) { Rubotty::Storage::Memory.new }

  subject(:names) { described_class.new(store: store) }

  it "returns a learned name for its scope and thread id" do
    names.learn(scope: "-100chat", native_id: 77, name: "release chat")
    expect(names.name_for(scope: "-100chat", native_id: 77)).to eq("release chat")
  end

  it "stringifies the thread id so an Integer learn matches a String lookup" do
    names.learn(scope: "-100chat", native_id: 77, name: "release chat")
    expect(names.name_for(scope: "-100chat", native_id: "77")).to eq("release chat")
  end

  it "returns nil for a thread it never learned" do
    expect(names.name_for(scope: "-100chat", native_id: 999)).to be_nil
  end

  it "updates the name when a thread is renamed" do
    names.learn(scope: "-100chat", native_id: 77, name: "release chat")
    names.learn(scope: "-100chat", native_id: 77, name: "release war room")
    expect(names.name_for(scope: "-100chat", native_id: 77)).to eq("release war room")
  end

  it "keeps the known name when a later event carries no name (an icon-only edit)" do
    names.learn(scope: "-100chat", native_id: 77, name: "release chat")
    names.learn(scope: "-100chat", native_id: 77, name: nil)
    names.learn(scope: "-100chat", native_id: 77, name: "")
    expect(names.name_for(scope: "-100chat", native_id: 77)).to eq("release chat")
  end

  it "scopes by the namespace, so the same thread id in two chats does not collide" do
    names.learn(scope: "chat-a", native_id: 5, name: "alpha")
    names.learn(scope: "chat-b", native_id: 5, name: "beta")
    expect(names.name_for(scope: "chat-a", native_id: 5)).to eq("alpha")
    expect(names.name_for(scope: "chat-b", native_id: 5)).to eq("beta")
  end

  it "is a no-op with no durable store wired, so the feature simply stays dormant" do
    dormant = described_class.new(store: nil)
    expect { dormant.learn(scope: "c", native_id: 1, name: "x") }.not_to raise_error
    expect(dormant.name_for(scope: "c", native_id: 1)).to be_nil
  end

  it "never lets a storage fault break the caller" do
    faulty = Class.new do
      def get_state(_key) = raise Rubotty::StorageError, "down"
      def put_state(_key, _value, expires_at: nil) = raise Rubotty::StorageError, "down"
    end.new
    resilient = described_class.new(store: faulty)
    expect { resilient.learn(scope: "c", native_id: 1, name: "x") }.not_to raise_error
    expect(resilient.name_for(scope: "c", native_id: 1)).to be_nil
  end

  it "honours a ttl so a name can be pruned on the same window the map is" do
    ttl_names = described_class.new(store: store, ttl: 3600)
    ttl_names.learn(scope: "c", native_id: 1, name: "temp")
    expect(store.get_state(ttl_names.send(:key, "c", "1"))).to eq("temp")
    store.purge(now: Time.now + 7200)
    expect(ttl_names.name_for(scope: "c", native_id: 1)).to be_nil
  end

  it "keeps the stored key within the bridge_state column bound for long platform ids" do
    long_scope = "a" * 90
    long_native_id = "b" * 90
    key = names.send(:key, long_scope, long_native_id)
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
    logged.learn(scope: "c", native_id: 1, name: "x")
  end
end
