# frozen_string_literal: true

require "spec_helper"

# The property this whole service exists to hold: a reader with grants on
# one community learns nothing whatsoever about another. A result list
# naming another tenant's room gives its existence away exactly as a 403
# would, which is why the REST API answers 404 for the same question.
RSpec.describe "#{Rubotty::ControlPlane::Search} cross-community isolation", :control_plane do
  let(:search) { Rubotty::ControlPlane::Search.new(models: models, logger: Rubotty::Log.null) }
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:actions) { Rubotty::ControlPlane::Search::ACTIONS }

  # Two communities with identical shapes and different marker words, plus the
  # room_key both of them use, since a room_key is unique only within one
  # community and colliding on "general" is ordinary here.
  let!(:mine) { search_community(models, slug: "alpha-co", marker: "alpha") }
  let!(:theirs) { search_community(models, slug: "beta-co", marker: "beta") }

  # Everything a reader could hold in their own community and nothing at all in
  # the other one.
  let(:scope) do
    Rubotty::ControlPlane::Search::Scope.communities(actions_by_community_id: { mine.id => actions })
  end

  def results(query) = search.call(query: query, scope: scope)

  def slugs(query)
    found = results(query)
    (found.entities.map(&:community_slug) + found.destinations.map(&:community_slug)).uniq
  end

  describe "asking for the other community's rows by name" do
    Rubotty::ControlPlane::Search::KINDS.map(&:name).each do |kind|
      it "answers nothing for another community's #{kind}, asked for by its exact stored value" do
        term = search_terms("beta").fetch(kind)

        expect(results(term).entities).to be_empty
        expect(results(term).destinations).to be_empty
      end
    end

    it "finds the same kinds in the reader's own community, so the examples above are not passing on a typo" do
      Rubotty::ControlPlane::Search::KINDS.map(&:name).each do |kind|
        term = search_terms("alpha").fetch(kind)

        expect(results(term).entities.map(&:kind)).to include(kind), "expected to find #{kind} for #{term.inspect}"
      end
    end
  end

  describe "trying to get around it" do
    it "answers nothing for a partial match on another community's room label" do
      expect(results("eta Loun").entities).to be_empty
    end

    it "answers nothing for another community's name in a different case" do
      ["BETA", "BeTa", "BETA ASSEMBLY", "beta assembly", "BeTa LoUnGe"].each do |query|
        expect(results(query).entities).to be_empty, "leaked on #{query.inspect}"
      end
      # The same shapes in the reader's own community do answer, so the case
      # folding above is being exercised rather than quietly failing to match.
      ["ALPHA", "AlPhA LoUnGe"].each do |query|
        expect(results(query).entities).not_to be_empty, "case folding is not working for #{query.inspect}"
      end
    end

    it "answers nothing for another community's slug" do
      expect(results("beta-co").entities).to be_empty
      expect(results("beta-co").destinations).to be_empty
    end

    it "answers only the reader's own room for a room_key both communities use" do
      hits = search.call(query: "general", scope: scope).entities

      expect(hits.map(&:community_slug).uniq).to eq(["alpha-co"])
    end

    it "offers a section only in the community the reader may open it in" do
      expect(slugs("rooms")).to eq(["alpha-co"])
      expect(slugs("webhooks")).to eq(["alpha-co"])
      expect(slugs("audit log")).to eq(["alpha-co"])
    end

    it "answers nothing at all for a wildcard, which would otherwise be the whole deployment" do
      expect(results("%").entities).to be_empty
      expect(results("%%").entities).to be_empty
      expect(results("%a%").entities).to be_empty
    end

    it "leaks nothing through a query that matches rows in both communities" do
      # Every populated community holds a telegram platform connection, so this
      # is the query most likely to walk out of the reader's own tenant.
      expect(slugs("telegram")).to eq(["alpha-co"])
      expect(slugs("hooks.test")).to eq(["alpha-co"])
      expect(slugs("Assembly")).to eq(["alpha-co"])
    end

    it "never names another community's row however high the limit is raised" do
      found = search.call(query: "a", scope: scope, limit: 10_000)
      wider = search.call(query: "as", scope: scope, limit: 10_000)

      expect(found.entities).to be_empty
      expect(wider.entities.map(&:community_slug).uniq).to eq(["alpha-co"])
    end
  end

  describe "a scope that permits less than a whole community" do
    # The read half of the Rooms, Platforms, Scripts, Endpoints, Discovered and
    # Guests pages is not an operator's to take: those are the viewer's reads.
    # Search has to hold the same line or it becomes the way around them.
    let(:scope) do
      Rubotty::ControlPlane::Search::Scope.communities(
        actions_by_community_id: { mine.id => %i[view_community view_operators] }
      )
    end

    it "answers nothing for a kind the reader may not read even in their own community" do
      expect(results("alpha Lounge").entities).to be_empty
      expect(results("alpha_greeter").entities).to be_empty
      expect(results("alpha_weather").entities).to be_empty
      expect(results("alpha Telegram").entities).to be_empty
    end

    it "still answers the kinds that reader may read" do
      expect(results("alpha Operator").entities.map(&:kind)).to eq([:operator])
      expect(results("alpha needs attention").entities.map(&:kind)).to eq([:alert])
    end

    it "offers no destination the reader would be refused at the door" do
      expect(results("rooms").destinations).to be_empty
      expect(results("scripts").destinations).to be_empty
      expect(results("operators").destinations.map(&:section)).to eq(["operators"])
    end
  end

  describe "a scope holding nothing" do
    let(:scope) { Rubotty::ControlPlane::Search::Scope.none }

    it "answers nothing for anything, including a value that certainly exists" do
      ["alpha Lounge", "beta Lounge", "general", "alpha-co", "Assembly", "rooms"].each do |query|
        found = search.call(query: query, scope: scope)

        expect(found.entities).to be_empty, "leaked entities on #{query.inspect}"
        expect(found.destinations).to be_empty, "leaked destinations on #{query.inspect}"
      end
    end
  end

  describe "a deployment-wide scope, which is the one that is meant to see everything" do
    let(:scope) do
      Rubotty::ControlPlane::Search::Scope.deployment_wide(actions: actions)
    end

    it "reads both communities, so the examples above are proving scoping rather than an empty database" do
      expect(slugs("Assembly")).to match_array(%w[alpha-co beta-co])
      expect(slugs("general")).to match_array(%w[alpha-co beta-co])
    end

    it "still answers nothing for a kind its own action list leaves out" do
      partial = Rubotty::ControlPlane::Search::Scope.deployment_wide(actions: actions - [:view_rooms])

      expect(search.call(query: "beta Lounge", scope: partial).entities).to be_empty
      expect(search.call(query: "beta Lounge", scope: scope).entities.map(&:kind)).to eq([:room])
    end
  end

  describe "the query itself" do
    # Reading the statements the search actually issues is the only way to tell
    # "narrowed in the database" from "narrowed in Ruby to the same answer", and
    # that difference is the whole design.
    def statements_for(query, using: scope)
      sink = StringIO.new
      db.loggers << Logger.new(sink)
      search.call(query: query, scope: using)
      db.loggers.clear
      sink.string.lines.grep(/SELECT/)
    end

    it "puts the community predicate in every statement rather than filtering rows afterwards" do
      # A query matching a community, a section and rows of several kinds, so
      # one pass exercises every statement the service can issue.
      selects = statements_for("alpha") + statements_for("rooms")
      # The communities table carries its own id rather than a community_id,
      # which covers the community kind, the destination lookup and the trailing
      # slug lookup alike.
      scoped_by = /community_id` IN \(#{mine.id}\)|FROM `communities` WHERE \(+`id` IN \(#{mine.id}\)/

      expect(selects.length).to be > 20
      expect(selects).to all(match(scoped_by))
    end

    it "reaches every kind's own table, so the example above is checking the whole surface" do
      tables = statements_for("alpha").filter_map { |line| line[/FROM `(\w+)`/, 1] }.uniq

      expect(tables).to include("communities", "rooms", "platform_connections", "script_endpoints",
                                "operators", "feature_settings", "community_scripts",
                                "webhook_subscriptions", "redirections", "alerts", "events", "polls")
    end

    it "never reaches a table at all for a kind the scope permits nowhere" do
      narrow = Rubotty::ControlPlane::Search::Scope.communities(
        actions_by_community_id: { mine.id => [:view_community] }
      )

      expect(statements_for("Lounge", using: narrow).grep(/FROM `rooms`/)).to be_empty
    end
  end
end
