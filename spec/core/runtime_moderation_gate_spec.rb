# frozen_string_literal: true

require "spec_helper"

# Whether the bridge READS moderation verbs at all is a different question
# from whether the person who typed one may run it. The runtime's own gate
# used to ask the static YAML operator directory, empty by design on a
# control-plane deployment, leaving every verb "not available on this bridge".
RSpec.describe Rubotty::Core::Runtime, "moderation command gate" do
  let(:yaml) do
    <<~YAML
      name: gate
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
      storage:
        driver: memory
      behaviour:
        log_level: fatal
        purge_interval: 0
      rooms:
        - id: lounge
          endpoints:
            - id: tg-lounge
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
    YAML
  end

  let(:config) { Rubotty::Config::Loader.load_string(yaml, env: { "TG_TOKEN" => "123:abc" }) }
  let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null) }

  it "reads the YAML as having no operators, which is the state that used to disable commands" do
    expect(config.operators).to be_empty
    expect(config.moderation_enabled?).to be(false)
  end

  context "without a control plane" do
    it "stays fail-closed on the static directory, since that IS the directory authorisation uses" do
      expect(runtime.send(:commands_enabled?)).to be(false)
    end

    it "builds no command parser at all" do
      expect(runtime.send(:build_commands)).to be_nil
    end

    it "leaves the acknowledgement and the grace period exactly where the static config puts them" do
      expect(runtime.send(:command_acknowledge?)).to be(false)
      expect(runtime.send(:command_cleanup_after)).to eq(0)
    end

    it "recognises /delete alone, the schema's own floor" do
      expect(runtime.send(:command_actions)).to eq(%i[delete])
    end
  end

  context "with a control plane" do
    # The registry is mostly consulted only for its presence here: it swaps the
    # operator directory over to LiveOperators, which reads the database.
    # command_acknowledge?/command_cleanup_after also read its Snapshot for the
    # deployment-wide default, stubbed unset so these still exercise the YAML.
    let(:snapshot) { instance_double(Rubotty::ControlPlane::Snapshot, feature_config_default: {}) }

    before { runtime.instance_variable_set(:@registry, instance_double(Rubotty::ControlPlane::Registry, current: snapshot)) }

    it "reads commands, because an empty YAML operators block says nothing about the live directory" do
      expect(runtime.send(:commands_enabled?)).to be(true)
    end

    it "builds a parser that recognises the verbs rather than calling them unavailable" do
      commands = runtime.send(:build_commands)

      expect(commands).not_to be_nil
      expect(commands.enabled?).to be(true)
    end

    # Config::Model gates both of these on the same static directory, so an
    # accepted command ran and then said nothing back, and the bridge-wide
    # grace period the per-scope ack_ttl_seconds falls back to was pinned to 0.
    it "acknowledges an accepted command, since the static directory does not decide that either" do
      expect(config.command_acknowledge?).to be(false)
      expect(runtime.send(:command_acknowledge?)).to be(true)
    end

    it "reads the grace period from the commands block rather than pinning it to zero" do
      expect(runtime.send(:command_cleanup_after)).to eq(0)

      with_grace = Rubotty::Config::Loader.load_string(
        yaml.sub("behaviour:", "commands:\n  cleanup_after: 15\nbehaviour:"),
        env: { "TG_TOKEN" => "123:abc" }
      )
      other = described_class.new(config: with_grace, logger: Rubotty::Log.null)
      other.instance_variable_set(:@registry, instance_double(Rubotty::ControlPlane::Registry))

      expect(with_grace.command_cleanup_after).to eq(0)
      expect(other.send(:command_cleanup_after)).to eq(15)
    end

    # The bug this closes: a database-only deployment has no YAML commands
    # block, so the static side of #fetch never has the key and used to fall
    # to a bare Ruby literal with no live default to read. A deployment-wide
    # feature_settings row (community_id and room_id both nil) now answers it.
    context "with a deployment-wide moderation default set" do
      let(:snapshot) do
        instance_double(
          Rubotty::ControlPlane::Snapshot,
          feature_config_default: { ack_ttl_seconds: 30, acknowledge: true }
        )
      end

      it "reads the grace period from it rather than the bare literal" do
        expect(runtime.send(:command_cleanup_after)).to eq(30)
      end

      it "reads acknowledge from it too" do
        expect(runtime.send(:command_acknowledge?)).to be(true)
      end

      it "still lets an explicit commands block in the YAML win" do
        with_grace = Rubotty::Config::Loader.load_string(
          yaml.sub("behaviour:", "commands:\n  cleanup_after: 15\n  acknowledge: false\nbehaviour:"),
          env: { "TG_TOKEN" => "123:abc" }
        )
        other = described_class.new(config: with_grace, logger: Rubotty::Log.null)
        other.instance_variable_set(:@registry, instance_double(Rubotty::ControlPlane::Registry, current: snapshot))

        expect(other.send(:command_cleanup_after)).to eq(15)
        expect(other.send(:command_acknowledge?)).to be(false)
      end
    end

    # The database grants an operator any of Moderation::ACTIONS; the static
    # floor of :delete alone refused the other seven as "not available on this
    # bridge" before authorisation was ever consulted. TYPED_ACTIONS rather than
    # ACTIONS: the parser reads words, and unban and unpinall are not words.
    it "recognises every moderation verb, not just the one the schema defaults to" do
      expect(runtime.send(:command_actions)).to eq(Rubotty::Core::Moderation::TYPED_ACTIONS)
    end

    context "and an explicit commands.actions list" do
      let(:config) do
        Rubotty::Config::Loader.load_string(
          yaml.sub("behaviour:", "commands:\n  actions: [delete, kick]\nbehaviour:"),
          env: { "TG_TOKEN" => "123:abc" }
        )
      end

      it "honours it, since naming the verbs is an operator's own decision" do
        expect(runtime.send(:command_actions)).to eq(%i[delete kick])
      end
    end

    context "and commands turned off on purpose" do
      let(:config) do
        Rubotty::Config::Loader.load_string(
          yaml.sub("behaviour:", "commands:\n  enabled: false\nbehaviour:"),
          env: { "TG_TOKEN" => "123:abc" }
        )
      end

      it "stays off, since that switch is an operator's own decision" do
        expect(runtime.send(:commands_enabled?)).to be(false)
        expect(runtime.send(:command_acknowledge?)).to be(false)
        expect(runtime.send(:command_cleanup_after)).to eq(0)
      end
    end
  end

  # The point of the gate change is recognition, NOT permission. An issuer who
  # resolves to no operator has to still be refused, and refused as
  # :not_permitted rather than waved through.
  it "refuses a non-operator's /delete on its own authority, not by pretending the verb does not exist" do
    runtime.instance_variable_set(:@registry, instance_double(Rubotty::ControlPlane::Registry))
    allow(runtime).to receive(:routing_operators).and_return(Rubotty::Core::Moderation::Directory.new)
    commands = runtime.send(:build_commands)

    endpoint = endpoint("tg-lounge", adapter: :telegram, settings: { chat_id: "-100" })
    message = Rubotty::Core::Message.new(
      kind: :chat,
      ref: Rubotty::Core::MessageRef.new("tg-lounge", "9"),
      origin: endpoint,
      author: Rubotty::Core::Author.new(native_id: "77", username: "mallory", kind: :user),
      body: Rubotty::Core::RichText.plain("/delete"),
      reply_to: Rubotty::Core::MessageRef.new("tg-lounge", "8"),
      timestamp: Time.now
    )

    result = commands.parse(message, directory: Rubotty::Core::Moderation::Directory.new)

    expect(result).to be_a(Rubotty::Core::Commands::Refusal)
    expect(result.reason).to eq(:not_permitted)
  end
end
