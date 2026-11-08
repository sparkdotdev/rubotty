# frozen_string_literal: true

require "spec_helper"

# Guessing which community a pending space belongs to, by name. Nothing here
# writes, so these assert only what is proposed and, more importantly, what is
# refused: a space nobody can place confidently belongs on the Onboarding queue,
# not on whichever community scored least badly.
RSpec.describe Rubotty::ControlPlane::SpaceSuggestions, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  subject(:suggestions) { described_class.new(models: models, logger: Rubotty::Log.null) }

  def community(name, slug)
    now = Time.now
    models.community.create(slug: slug, name: name, status: "active", created_at: now, updated_at: now)
  end

  def space(name, external_id: "-100#{name.hash.abs}")
    now = Time.now
    models.pending_space.create(
      adapter: "telegram", account: "telegram", external_id: external_id, name: name,
      state: Rubotty::ControlPlane::PendingSpaces::PENDING, expires_at: now + 1800,
      created_at: now, updated_at: now
    )
  end

  def propose(spaces)
    suggestions.propose(spaces: spaces, communities: models.community.order(:slug).all)
  end

  it "suggests a community whose whole name appears in the space's name" do
    target = community("ARI Residency", "ari-residency")
    result = propose([space("ARI Residency Chat")])

    expect(result.length).to eq(1)
    expect(result.first.community.id).to eq(target.id)
    expect(result.first.matched).to include("residency")
  end

  it "matches on the slug when the display name never appears" do
    target = community("The Anticraft", "sunday-bakers")
    result = propose([space("Sunday Bakers")])

    expect(result.first.community.id).to eq(target.id)
  end

  it "matches a one-word community through the platform noise in a group name" do
    target = community("Rando", "rando")
    result = propose([space("Rando Official Group")])

    expect(result.first.community.id).to eq(target.id)
  end

  it "refuses a one-word community that only appears alongside a real extra word" do
    community("Rando", "rando")

    expect(propose([space("Rando Bikes")])).to be_empty
  end

  it "refuses a community whose name is nothing but filler" do
    community("Chat", "chat")

    expect(propose([space("Some Other Chat")])).to be_empty
  end

  it "suggests nothing at all when two communities both match" do
    community("Ferrous Wheel", "ferrous-wheel")
    community("Ferrous Wheel Riders", "ferrous-wheel-riders")

    expect(propose([space("Ferrous Wheel Riders Chat")])).to be_empty
  end

  it "ignores a space with no name" do
    community("ARI Residency", "ari-residency")

    expect(propose([space(nil, external_id: "-999")])).to be_empty
  end

  it "refuses a partial overlap, however suggestive" do
    community("ARI Residency", "ari-residency")

    expect(propose([space("ARI Alumni")])).to be_empty
  end

  it "reads a space's punctuation and case the same as the community's" do
    target = community("ARI Residency", "ari-residency")

    expect(propose([space("[ari] residency // chat")]).first.community.id).to eq(target.id)
  end

  it "scopes for_community to one community, still checking every other for a clash" do
    target = community("Ferrous Wheel", "ferrous-wheel")
    community("Ferrous Wheel Riders", "ferrous-wheel-riders")
    rows = [space("Ferrous Wheel"), space("Ferrous Wheel Riders", external_id: "-2")]

    result = suggestions.for_community(community: target, spaces: rows)

    # "Ferrous Wheel" is the exact name of one community and a subset of the
    # other's, so only the space that matches nothing else is offered here.
    expect(result.map { |row| row.space.name }).to eq(["Ferrous Wheel"])
  end
end
