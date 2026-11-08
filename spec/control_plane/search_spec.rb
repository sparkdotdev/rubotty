# frozen_string_literal: true

require "spec_helper"

# What the dashboard command bar's lookup finds and how it bounds itself. The
# cross-community property this exists to hold is in search_isolation_spec.rb.
RSpec.describe Rubotty::ControlPlane::Search, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:search) { described_class.new(models: models, logger: Rubotty::Log.null) }
  let(:everything) { described_class::Scope.deployment_wide(actions: described_class::ACTIONS) }
  let!(:community) { search_community(models, slug: "sample", marker: "alpha") }

  def call(query, scope: everything, **rest) = search.call(query: query, scope: scope, **rest)

  def kinds_for(query, **rest) = call(query, **rest).entities.map(&:kind)

  describe "what it finds" do
    described_class::KINDS.each do |kind|
      it "finds a #{kind.name} by its own text" do
        term = search_terms("alpha").fetch(kind.name)

        expect(kinds_for(term)).to include(kind.name)
      end
    end

    it "reaches every kind it declares, so none of them is wired up and unreachable" do
      found = described_class::KINDS.map { |kind| kinds_for(search_terms("alpha").fetch(kind.name)) }.flatten.uniq

      expect(found).to include(*described_class::KINDS.map(&:name))
    end

    it "matches a substring rather than only a whole word" do
      expect(kinds_for("oung")).to include(:room)
    end

    it "ignores case on both sides" do
      expect(kinds_for("ALPHA LOUNGE")).to include(:room)
      expect(kinds_for("alpha lounge")).to include(:room)
    end

    it "carries the community a hit belongs to, so a result reads as its own tenant's" do
      hit = call("alpha Lounge").entities.first

      expect(hit.community_slug).to eq("sample")
      expect(hit.community_name).to eq("alpha Assembly")
    end

    it "points a hit at the page that shows it" do
      hit = call("alpha_greeter").entities.first

      expect(hit.path).to eq("/communities/sample/scripts")
    end

    it "answers one feature hit however many rooms that feature is configured on" do
      room = models.room.where(community_id: community.id).first
      models.feature_setting.create(community_id: community.id, room_id: room.id, feature: "alpha_filter",
                                    enabled: true, config: "{}", created_at: Time.now, updated_at: Time.now)

      expect(kinds_for("alpha_filter").count(:feature)).to eq(1)
    end

    it "reads an operator's name off the person the grant was made to" do
      hit = call("alpha Operator").entities.find { |entry| entry.kind == :operator }

      expect(hit.title).to eq("alpha Operator")
      expect(hit.path).to eq("/communities/sample/operators")
    end
  end

  describe "what it refuses to answer" do
    it "answers nothing for a query shorter than the floor" do
      expect(call("a")).to be_empty
    end

    it "answers nothing for blank input" do
      expect(call("   ")).to be_empty
      expect(call(nil)).to be_empty
    end

    it "treats a LIKE wildcard as the character somebody typed rather than as a wildcard" do
      expect(call("%%")).to be_empty
      expect(call("__")).to be_empty
    end

    it "takes an escaped wildcard literally when a row really contains one" do
      models.community_script.create(community_id: community.id, name: "100%_uptime", kind: "command",
                                     language: "lua", source: "-- x", trigger_type: "command",
                                     created_at: Time.now, updated_at: Time.now)

      expect(call("00%_up").entities.map(&:title)).to eq(["100%_uptime"])
    end
  end

  describe "destinations" do
    it "offers a section by its own name in the communities it can be opened in" do
      offers = call("rooms").destinations

      expect(offers.map(&:section)).to eq(["rooms"])
      expect(offers.map(&:community_slug)).to eq(["sample"])
    end

    it "matches a section by its label as well as its key" do
      expect(call("audit log").destinations.map(&:section)).to eq(["audit"])
      expect(call("discovered connections").destinations.map(&:section)).to eq(["discovered"])
    end

    it "offers a community's own pages when the community itself matched, so a slug is a way in" do
      offers = call("sample").destinations

      expect(offers.map(&:community_slug).uniq).to eq(["sample"])
      expect(offers.first.section).to eq("")
      expect(offers.map(&:section)).to include("rooms", "webhooks")
    end

    it "keeps destinations apart from entities rather than mixing the two lists" do
      results = call("sample")

      expect(results.entities.map(&:kind)).to eq([:community])
      expect(results.destinations).not_to be_empty
    end

    it "puts the mount-relative path on a destination" do
      offer = call("webhooks").destinations.first

      expect(offer.path).to eq("/communities/sample/webhooks")
      expect(offer.label).to eq("Webhooks")
    end

    it "offers only the sections the scope permits" do
      scope = described_class::Scope.communities(actions_by_community_id: { community.id => [:view_community] })

      expect(call("rooms", scope: scope).destinations).to be_empty
      expect(call("alerts", scope: scope).destinations.map(&:section)).to eq(["alerts"])
    end

    it "never offers Files to anybody whose scope was not given the administrator action" do
      viewer = described_class::Scope.deployment_wide(
        actions: described_class::ACTIONS - [described_class::FILES_ACTION]
      )

      expect(call("files", scope: viewer).destinations).to be_empty
      expect(call("files").destinations.map(&:section)).to eq(["files"])
    end
  end

  describe "bounds" do
    it "caps one kind so a noisy table cannot crowd out every other kind" do
      12.times do |index|
        models.alert.create(community_id: community.id, text: "alpha noise #{index}",
                            mode: "quiet", created_at: Time.now)
      end

      results = call("alpha noise")

      expect(results.entities.length).to eq(described_class::PER_KIND_LIMIT)
      expect(results).to be_truncated
    end

    it "caps the entity list at the limit it was given" do
      results = call("alpha", limit: 3)

      expect(results.entities.length).to eq(3)
      expect(results).to be_truncated
    end

    it "refuses to be talked past its own ceiling" do
      results = call("alpha", limit: 10_000)

      expect(results.entities.length).to be <= described_class::MAX_LIMIT
    end

    it "caps destinations on their own so an entity flood cannot take them out" do
      offers = call("sample").destinations

      expect(offers.length).to eq(described_class::DESTINATION_LIMIT)
      expect(call("sample")).to be_truncated
    end

    it "says nothing was truncated when nothing was" do
      expect(call("alpha_greeter")).not_to be_truncated
    end
  end

  describe "the section catalogue" do
    it "gates every kind on a section it actually declares" do
      described_class::KINDS.each do |kind|
        expect(described_class::ACTION_BY_SECTION).to have_key(kind.section)
        expect(described_class::ACTIONS).to include(kind.action)
      end
    end

    it "names no section twice, so a key resolves to one action" do
      keys = described_class::SECTIONS.map(&:first)

      expect(keys.uniq).to eq(keys)
    end
  end
end
