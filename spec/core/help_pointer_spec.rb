# frozen_string_literal: true

require "spec_helper"

# Fluxer publishes no command list, so the bridge says where the commands are in
# the channel itself. That line is worth exactly once per channel.
RSpec.describe Rubotty::Core::HelpPointer do
  # The message map's key/value half, which is all this needs of a store.
  class HelpPointerStore
    def initialize = @state = {}

    attr_reader :state

    def get_state(key) = @state[key]

    def put_state(key, value, expires_at: nil) = (@state[key] = value)
  end

  describe "without a store" do
    subject(:pointer) { described_class.new }

    it "starts with nothing pointed at" do
      expect(pointer.pointed?("fx-general")).to be(false)
    end

    it "remembers within the process" do
      pointer.mark_pointed!("fx-general")
      expect(pointer.pointed?("fx-general")).to be(true)
    end

    it "keeps one endpoint's marker off another's" do
      pointer.mark_pointed!("fx-general")
      expect(pointer.pointed?("fx-offtopic")).to be(false)
    end
  end

  describe "with a store" do
    let(:store) { HelpPointerStore.new }

    subject(:pointer) { described_class.new(store: store) }

    it "writes the marker under a namespaced key" do
      pointer.mark_pointed!("fx-general")
      expect(store.state.keys).to eq(["#{described_class::KEY_PREFIX}:fx-general"])
    end

    it "survives a restart, since a fresh instance reads the same store" do
      pointer.mark_pointed!("fx-general")
      expect(described_class.new(store: store).pointed?("fx-general")).to be(true)
    end

    it "reads the store once and answers from memory after that" do
      described_class.new(store: store)
      reads = 0
      allow(store).to receive(:get_state) { |key| reads += 1; store.state[key] }
      fresh = described_class.new(store: store)
      fresh.mark_pointed!("fx-general")
      3.times { fresh.pointed?("fx-general") }

      expect(reads).to eq(0)
    end

    it "ignores a store that has no key/value half" do
      expect { described_class.new(store: Object.new).mark_pointed!("fx-general") }.not_to raise_error
    end

    # Failing quiet is the right way round: a storage hiccup must not turn the
    # pointer into a line posted on every message.
    it "claims the pointer was posted when the store cannot be read" do
      allow(store).to receive(:get_state).and_raise(Rubotty::StorageError, "gone")
      expect(pointer.pointed?("fx-general")).to be(true)
    end

    it "swallows a write failure rather than costing the message it rode on" do
      allow(store).to receive(:put_state).and_raise(Rubotty::StorageError, "gone")
      expect { pointer.mark_pointed!("fx-general") }.not_to raise_error
    end
  end
end
