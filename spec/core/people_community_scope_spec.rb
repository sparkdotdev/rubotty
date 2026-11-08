# frozen_string_literal: true

require "spec_helper"

# Issue #1784, driven through the shared two-community fixture so it fails the
# way a real deployment would. A ban target or a mention whose community did
# not resolve used to be looked up across every tenant at once.
RSpec.describe Rubotty::Core::CommunityPeople, "resolving only inside one community" do
  let(:ada) do
    Rubotty::Core::Person.new(name: "Alpha Ada", identities: { telegram: ["55"] },
                              handles: { telegram: ["ada"] })
  end
  let(:bea) do
    Rubotty::Core::Person.new(name: "Beta Bea", identities: { telegram: ["66"] },
                              handles: { telegram: ["bea"] })
  end

  let(:snapshot) do
    Rubotty::ControlPlane::Snapshot.new(
      communities: [
        colliding_community(CollidingCommunities::ALPHA, people: [ada]),
        colliding_community(CollidingCommunities::BETA, people: [bea])
      ]
    )
  end
  let(:people) { snapshot.people }

  it "resolves alpha's person for alpha" do
    expect(people.for_community(1).by_handle(:telegram, "ada")).to eq(ada)
  end

  it "resolves beta's person for beta" do
    expect(people.for_community(2).by_handle(:telegram, "bea")).to eq(bea)
  end

  # The point of the class. Beta must not be able to name alpha's person, which
  # is what a /ban or a mention does with whatever this hands back.
  it "does not resolve alpha's person for beta" do
    expect(people.for_community(2).by_handle(:telegram, "ada")).to be_nil
    expect(people.for_community(2).by_identity(:telegram, "55")).to be_nil
  end

  # The regression itself: an unresolved community used to fall through to the
  # merged directory, where a handle unique to one tenant still answered.
  it "resolves nobody at all when the community did not resolve" do
    lost = people.for_community(nil)

    expect(lost.by_handle(:telegram, "ada")).to be_nil
    expect(lost.by_identity(:telegram, "66")).to be_nil
    expect(lost.resolve_mention(tg_user_id: "55")).to be_nil
  end

  it "resolves nobody for an id that names no live community" do
    expect(people.for_community(99).by_handle(:telegram, "ada")).to be_nil
  end

  # The config-file path keeps its own meaning: one deployment, one people list,
  # and naming a community picks out the same people it already holds.
  it "leaves a plain config directory answering as itself" do
    directory = Rubotty::Core::Directory.new([ada])

    expect(directory.for_community("anything").by_handle(:telegram, "ada")).to eq(ada)
  end
end
