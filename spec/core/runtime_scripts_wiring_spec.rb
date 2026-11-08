# frozen_string_literal: true

require "spec_helper"

# Everything else about the feature is tested by building the pieces by hand, so
# the whole of it could be absent from the running bot with every spec passing.
RSpec.describe Rubotty::Core::Runtime, "operator scripts wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def build_runtime(store:, env: ControlPlaneHelpers::CONFIG_ENV)
    described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env).build
  end

  def features_of(runtime) = runtime.router.instance_variable_get(:@pipeline).features

  describe "with a control plane and a Lua interpreter" do
    before { skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil? }

    let(:runtime) { build_runtime(store: sequel_store) }

    it "puts the scripts feature in the pipeline" do
      expect(features_of(runtime).find { |f| f.is_a?(Rubotty::Features::Scripts) }).not_to be_nil
    end

    # A rule that rewrites or rejects gets its say after the built in filters
    # and before the bridge relays anything, or translation queues a copy of it.
    # Translation takes the slot every only-ever-enqueues feature takes, and the
    # command answerer closes the chain so no command is translated or relayed.
    it "runs immediately before translation, which runs ahead of the closing pair" do
      names = features_of(runtime).map(&:class)

      expect(names.index(Rubotty::Features::Scripts))
        .to eq(names.index(Rubotty::Features::Translation) - 1)
      expect(names.index(Rubotty::Features::Translation))
        .to eq(names.index(Rubotty::Features::DisabledCommandNotice) - 1)
      expect(names.index(Rubotty::Features::DisabledCommandNotice))
        .to eq(names.index(Rubotty::Features::Bridge) - 1)
    end

    # rubotty.later books one of these, and with nothing consuming it the call
    # answers true while the work vanishes.
    it "registers a handler for the deferred endpoint job" do
      scheduler = runtime.instance_variable_get(:@durable_scheduler)

      expect(scheduler.handler?(Rubotty::Features::Scripts::LATER_KIND)).to be(true)
    end

    it "hands the feature the same services the runtime built" do
      feature = features_of(runtime).find { |f| f.is_a?(Rubotty::Features::Scripts) }

      expect(feature.instance_variable_get(:@scripts))
        .to be(runtime.instance_variable_get(:@scripts))
    end
  end

  # A script's process runs in an account of its own, and a deployment that
  # cannot hand one out refuses to run scripts at all. Booting quietly without
  # them would leave an operator wondering why nothing fires.
  describe "where scripts cannot be confined" do
    before { skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil? }

    it "leaves the feature out of the pipeline and says why" do
      allow(Rubotty::Scripting::Isolation).to receive(:satisfied?).and_return(false)
      allow(Rubotty::Scripting::Isolation).to receive(:reason).and_return("no account to hand out")
      sink = StringIO.new
      runtime = described_class.new(config: config, logger: Rubotty::Log.build(level: "warn", io: sink),
                                    storage: sequel_store, env: ControlPlaneHelpers::CONFIG_ENV).build

      expect(features_of(runtime).find { |f| f.is_a?(Rubotty::Features::Scripts) }).to be_nil
      expect(sink.string).to match(/scripting: turned off, no account to hand out/)
    end
  end

  # The filter walks down its tiers until one lets the interpreter start, and a
  # deployment sitting on the weakest of them used to boot reading exactly like
  # one behind the whole filter.
  describe "where the filter settled below its strongest tier" do
    before { skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil? }

    def booted_log
      sink = StringIO.new
      described_class.new(config: config, logger: Rubotty::Log.build(level: "warn", io: sink),
                          storage: sequel_store, env: ControlPlaneHelpers::CONFIG_ENV).build
      sink.string
    end

    it "names the tier in force and what it left open" do
      allow(Rubotty::Scripting::Seccomp).to receive_messages(
        reduced_tier: Rubotty::Scripting::Seccomp::RUNTIME_OPEN_FILES,
        describe: "a script's process can open a file for writing here."
      )

      expect(booted_log).to match(/settled on runtime_open_files rather than runtime/)
      expect(booted_log).to match(/can open a file for writing here/)
    end

    it "says nothing where the whole filter holds, which is most deployments" do
      allow(Rubotty::Scripting::Seccomp).to receive(:reduced_tier).and_return(nil)

      expect(booted_log).not_to match(/system call filter settled/)
    end
  end

  # No control plane means nowhere to keep scripts.
  describe "without a control plane" do
    it "leaves the scripts feature out of the pipeline" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)

      expect(features_of(runtime).find { |f| f.is_a?(Rubotty::Features::Scripts) }).to be_nil
    end
  end
end
