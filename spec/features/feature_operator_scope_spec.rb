# frozen_string_literal: true

require "spec_helper"

# The boot Snapshot publishes every community's operators as one merged
# Directory, and eight features took a copy and read it whenever the message's
# own community did not resolve, so somebody else's operator was exempt from
# this community's filters and raid controls (#1785).
RSpec.describe "feature permission checks resolve in one community only (#1785)", :control_plane do
  # The eight that carried the fallback. utility_commands and identify_topic
  # already read the community's directory and nothing else.
  let(:scoped_features) do
    [Rubotty::Features::Warnings, Rubotty::Features::WordFilter, Rubotty::Features::LinkFilter,
     Rubotty::Features::AntiSpam, Rubotty::Features::AntiRaid, Rubotty::Features::MentionSpam,
     Rubotty::Features::Multipost, Rubotty::Features::IdentityHistory]
  end

  let(:alpha_operator) do
    Rubotty::Core::Moderation::Operator.new(
      name: "Alex", identities: { telegram: ["55"] }, rooms: [CollidingCommunities::SHARED_ROOM_KEY]
    )
  end
  let(:operator_author) { author(native_id: "55", username: "alex") }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot") }

  def word_filter_on
    Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
      feature: "word_filter", enabled: true, config: { entries: %w[badword] }
    )
  end

  # ALPHA holds the only operator row and BETA holds none. Both switch the
  # filter on, so the one difference between them is whose operator is asked for.
  let(:snapshot) do
    Rubotty::ControlPlane::Snapshot.new(
      communities: [
        colliding_community(CollidingCommunities::ALPHA, operators: [alpha_operator],
                            feature_settings: [word_filter_on]),
        colliding_community(CollidingCommunities::BETA, feature_settings: [word_filter_on])
      ]
    )
  end

  let(:pipeline) do
    filter = Rubotty::Features::WordFilter.new(
      topology: snapshot.topology, adapters: Hash.new(adapter),
      storage: Rubotty::Storage::Memory.new, logger: Rubotty::Log.null
    )
    Rubotty::Features::Pipeline.new(features: [filter], registry: colliding_registry(snapshot))
  end

  def endpoint_named(key) = snapshot.channel_by_endpoint_key(key).endpoint

  def post(endpoint_key, native_id:)
    pipeline.handle(
      message(endpoint_named(endpoint_key), text: "a badword", native_id: native_id, author: operator_author)
    )
  end

  # The signature is the fix: with nothing to inject there is no second
  # directory for an unresolved community to fall through to.
  it "gives none of the eight an operator directory to be handed" do
    scoped_features.each do |klass|
      accepted = klass.instance_method(:initialize).parameters.map(&:last)
      expect(accepted).not_to include(:operators), "#{klass} still accepts an injected operator directory"
    end
  end

  it "publishes the operator in the merged directory, which is what the fallback read" do
    expect(snapshot.operators.resolve(:telegram, "55")).to eq(alpha_operator)
  end

  it "exempts the operator in the community that granted them" do
    post("alpha-telegram", native_id: "1")
    expect(adapter.deleted).to be_empty
  end

  it "does not exempt them in the other community's identically keyed room" do
    post("beta-telegram", native_id: "2")
    expect(adapter.deleted).to eq([%w[beta-telegram 2]])
  end
end
