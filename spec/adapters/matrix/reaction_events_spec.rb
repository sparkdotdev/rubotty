# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Matrix::ReactionEvents do
  let(:store) { Rubotty::Storage::Memory.new }
  let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }

  subject(:events) { described_class.new(store: store) }

  it "remembers and forgets the event id that placed a reaction" do
    events.remember("!room", "$target", thumbs, "$placed")
    expect(events.forget("!room", "$target", thumbs)).to eq("$placed")
  end

  it "returns nil once an entry has been forgotten, rather than the same id twice" do
    events.remember("!room", "$target", thumbs, "$placed")
    events.forget("!room", "$target", thumbs)
    expect(events.forget("!room", "$target", thumbs)).to be_nil
  end

  it "returns nil for a reaction it never saw" do
    expect(events.forget("!room", "$target", thumbs)).to be_nil
  end

  it "survives across a new instance sharing the same store" do
    events.remember("!room", "$target", thumbs, "$placed")
    later = described_class.new(store: store)
    expect(later.forget("!room", "$target", thumbs)).to eq("$placed")
  end

  it "keys by room, target and reaction independently" do
    other = Rubotty::Core::Reaction.new(emoji: "🎉")
    events.remember("!room", "$target", thumbs, "$a")
    events.remember("!room", "$target", other, "$b")
    expect(events.forget("!room", "$target", thumbs)).to eq("$a")
    expect(events.forget("!room", "$target", other)).to eq("$b")
  end

  it "is a no-op with no store wired, never raising" do
    bare = described_class.new(store: nil)
    expect { bare.remember("!room", "$target", thumbs, "$placed") }.not_to raise_error
    expect(bare.forget("!room", "$target", thumbs)).to be_nil
  end

  it "keeps the stored key within the bridge_state column bound for real-length Matrix ids" do
    long_room = "!#{"a" * 60}:example.org"
    long_target = "$#{"b" * 60}"
    key = events.send(:key, long_room, long_target, thumbs)
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
    logged.remember("!room", "$target", thumbs, "$placed")
  end
end
