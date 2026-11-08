# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The Ruby side of the host function boundary, tested alone because its rule (a name
# only reaches Ruby if somebody registered it) has to hold whether or not Lua is
# installed.
RSpec.describe Rubotty::Scripting::Registry do
  subject(:registry) { described_class.new }

  it "runs a registered function with the arguments it was given" do
    registry.register("add") { |a, b| a + b }

    expect(registry.call("add", [2, 3])).to eq(5)
  end

  it "reports the names a child needs in order to install its stubs" do
    registry.register("webhook") { nil }
    registry.register("rooms") { [] }

    expect(registry.names).to contain_exactly("webhook", "rooms")
  end

  it "refuses a name nobody registered" do
    expect { registry.call("exfiltrate", []) }
      .to raise_error(Rubotty::Scripting::UnknownHostFunction, /exfiltrate/)
  end

  it "will not register a function with no body" do
    expect { registry.register("webhook") }.to raise_error(ArgumentError)
  end

  it "carries its own call ceiling, so one registry can serve every community" do
    expect(described_class.new(max_calls: 3).max_calls).to eq(3)
    expect(registry.max_calls).to eq(described_class::DEFAULT_MAX_CALLS)
  end

  # What a call is charged is a fact about its handler, so it is declared where the handler
  # is. Adding a function and classifying it is one gesture, which is what stops a new one
  # arriving unclassified.
  describe "what a call costs" do
    it "remembers the class each function was registered under" do
      registry.register("bold", cost: :free) { |t| t }
      registry.register("notify", cost: :broadcast) { true }
      registry.register("recall", cost: :read) { nil }

      expect(registry.cost_of("bold")).to eq(:free)
      expect(registry.cost_of("notify")).to eq(:broadcast)
      expect(registry.cost_of("recall")).to eq(:read)
    end

    # The safe default: a function nobody thought about is charged rather than
    # free, and charged against the big ceiling rather than the small one.
    it "charges an unclassified function as an ordinary one" do
      registry.register("something_new") { true }

      expect(registry.cost_of("something_new")).to eq(:read)
      expect(registry.cost_of("never_registered")).to eq(:read)
    end

    it "refuses a class it does not have a budget for" do
      expect { registry.register("notify", cost: :cheap) { true } }
        .to raise_error(ArgumentError, /cheap/)
    end
  end

  # The catalog and the classification are two lists, and a function in the
  # first and neither half of the second is charged as ordinary. That is the
  # right default, but the ones that reach people have to be in it or the
  # broadcast cap protects nothing.
  describe "the shipped classification" do
    it "charges every function that reaches people as a broadcast" do
      %w[notify post whisper react warn alert].each do |name|
        expect(Rubotty::Scripting::HostFunctions.cost_of(name)).to eq(:broadcast)
      end
    end

    # Not an oversight: they change something already in front of people rather
    # than putting something new there, so a rule may keep a scoreboard current.
    it "leaves edit and delete on the ordinary charge" do
      %w[edit delete].each do |name|
        expect(Rubotty::Scripting::HostFunctions.cost_of(name)).to eq(:read)
      end
    end

    it "charges nothing for the helpers that only touch a string" do
      %w[bold italic underline strikethrough spoiler code pre blockquote
         format escape truncate mention].each do |name|
        expect(Rubotty::Scripting::HostFunctions.cost_of(name)).to eq(:free)
      end
    end

    it "names only functions the catalog actually offers" do
      expect(Rubotty::Scripting::HostFunctions::COST_OF.keys - Rubotty::Scripting::HostFunctions.names)
        .to be_empty
    end

    # Built through the real builder, so the wiring from catalog to registry is
    # what is under test rather than the table on its own.
    it "carries the classification onto a registry the router would build" do
      built = Rubotty::Scripting::HostFunctions.registry(
        handlers: { "bold" => ->(t) { t }, "notify" => ->(_t) { true }, "recall" => ->(_k) { nil } }
      )

      expect(built.cost_of("bold")).to eq(:free)
      expect(built.cost_of("notify")).to eq(:broadcast)
      expect(built.cost_of("recall")).to eq(:read)
    end
  end
end
