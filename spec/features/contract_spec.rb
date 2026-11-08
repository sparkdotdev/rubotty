# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::Outcome do
  it "continues by default, carrying an empty value" do
    outcome = described_class.continue
    expect(outcome).to be_continue
    expect(outcome).not_to be_halt
    expect(outcome.value).to eq([])
  end

  it "halts, carrying the value and an optional reason" do
    outcome = described_class.halt(%i[receipt], reason: :done)
    expect(outcome).to be_halt
    expect(outcome.value).to eq(%i[receipt])
    expect(outcome.reason).to eq(:done)
  end

  it "is frozen: an outcome is a decision, not a mutable accumulator" do
    expect(described_class.continue).to be_frozen
  end
end

RSpec.describe Rubotty::Features::Base do
  it "requires a subclass to name itself" do
    expect { described_class.feature_name }.to raise_error(NotImplementedError)
  end

  it "observes every relayable kind by default" do
    expect(described_class.observes).to include(:chat, :edit, :delete, :reaction_add, :reaction_remove)
  end

  it "is off by default: only the bridge opts into on" do
    expect(described_class.default_enabled?).to be(false)
  end

  it "continues by default, so a feature that only observes never halts the chain" do
    expect(described_class.new.call(nil)).to be_continue
  end
end

RSpec.describe Rubotty::Features::Context do
  include Builders

  let(:tg) { endpoint("tg") }

  it "carries the message, community, channel and resolved config it is given" do
    context = described_class.new(
      message: message(tg), community: :a_community, channel: :a_channel, config: { k: 1 }
    )
    expect(context.message.origin).to eq(tg)
    expect(context.community).to eq(:a_community)
    expect(context.channel).to eq(:a_channel)
    expect(context.config).to eq({ k: 1 })
  end

  it "falls through to the community for operators, people and rooms" do
    community = instance_double(
      Rubotty::ControlPlane::Snapshot::Community,
      operators: :ops, people: :ppl, rooms: :rms
    )
    context = described_class.new(message: message(tg), community: community)
    expect(context.operators).to eq(:ops)
    expect(context.people).to eq(:ppl)
    expect(context.rooms).to eq(:rms)
  end

  # Inverted from asserting the injected directory wins (#1795): the merged
  # deployment-wide directory is one injection away from every command surface,
  # so a resolved community always answers with its own.
  it "prefers the community's own directory over an injected one" do
    community = instance_double(
      Rubotty::ControlPlane::Snapshot::Community, operators: :community_ops, people: :community_people
    )
    context = described_class.new(message: message(tg), community: community,
                                  operators: :injected_ops, people: :injected_people)
    expect(context.operators).to eq(:community_ops)
    expect(context.people).to eq(:community_people)
  end

  it "reads an injected directory only where no community resolved" do
    context = described_class.new(message: message(tg), operators: :injected_ops, people: :injected_people)
    expect(context.operators).to eq(:injected_ops)
    expect(context.people).to eq(:injected_people)
  end

  it "yields nil for community-derived views when there is no community" do
    context = described_class.new(message: message(tg))
    expect(context.operators).to be_nil
    expect(context.rooms).to be_nil
  end

  describe "#command_prefixes" do
    it "resolves through the community's own feature_config, not this feature's own config" do
      community = instance_double(Rubotty::ControlPlane::Snapshot::Community)
      allow(community).to receive(:feature_config)
        .with(:a_channel, Rubotty::Core::CommandPrefix::CONFIG_FEATURE).and_return({ "prefixes" => ["#"] })

      context = described_class.new(message: message(tg), community: community, channel: :a_channel,
                                    config: { prefixes: ["?"] })

      expect(context.command_prefixes.to_a).to eq(["#"])
    end

    it "falls back to the hardcoded default without a control plane" do
      context = described_class.new(message: message(tg))
      expect(context.command_prefixes.to_a).to eq(["/", "!"])
    end
  end

  it "builds outcomes so a feature body reads as intent" do
    context = described_class.new(message: message(tg))
    expect(context.halt(%i[x])).to be_halt
    expect(context.continue.value).to eq([])
  end
end
