# frozen_string_literal: true

require "spec_helper"

# Features::Context promised the community's directory first and the injected
# one as the fallback, and read them the other way round (#1795). The router
# holds the merged deployment-wide directory, so one line passing it here would
# have converted every command surface to it at once.
RSpec.describe "Features::Context resolves in the community, not the injection (#1795)", :control_plane do
  let(:alpha_operator) do
    Rubotty::Core::Moderation::Operator.new(
      name: "Alex", identities: { telegram: ["55"] }, rooms: [CollidingCommunities::SHARED_ROOM_KEY]
    )
  end
  let(:alpha_person) { Rubotty::Core::Person.new(name: "Alex", identities: { telegram: ["55"] }) }

  let(:snapshot) do
    Rubotty::ControlPlane::Snapshot.new(
      communities: [
        colliding_community(CollidingCommunities::ALPHA, operators: [alpha_operator], people: [alpha_person]),
        colliding_community(CollidingCommunities::BETA)
      ]
    )
  end

  def context_for(community_id, operators: nil, people: nil)
    Rubotty::Features::Context.new(
      message: message(endpoint("tg", adapter: :telegram)),
      community: snapshot.community_by_id(community_id), operators: operators, people: people
    )
  end

  it "holds the operator in the merged directory, which is what an injection would carry" do
    expect(snapshot.operators.resolve(:telegram, "55")).to eq(alpha_operator)
  end

  it "answers with the community's own directory in the community that granted the operator" do
    expect(context_for(CollidingCommunities::ALPHA[:id]).operators.resolve(:telegram, "55")).to eq(alpha_operator)
  end

  it "refuses to widen the other community even when the merged directory is injected" do
    scope = context_for(CollidingCommunities::BETA[:id], operators: snapshot.operators)
    expect(scope.operators.resolve(:telegram, "55")).to be_nil
  end

  it "reads the community's people over an injected directory too" do
    scope = context_for(CollidingCommunities::BETA[:id], people: snapshot.community_by_id(1).people)
    expect(scope.people.by_identity(:telegram, "55")).to be_nil
  end
end
