# frozen_string_literal: true

# {ControlPlane::Search} against a real server. Matching is plain LIKE with both
# sides lowered, which is the one part of this that the three backends disagree
# about if it is written any other way: SQLite's LIKE folds ASCII case on its
# own, MariaDB's collation here does not, and Postgres follows the database's.
# The community predicate is the other half, since an empty IN list has to keep
# meaning "nothing" everywhere.
RSpec.shared_examples "the search backend contract" do |driver, url_env|
  subject(:db) do
    Rubotty::Storage::Factory.build({ driver: driver, url_env: url_env, auto_migrate: false }, env: ENV).db
  end

  let(:models) { Rubotty::ControlPlane.models(db) }
  let(:search) { Rubotty::ControlPlane::Search.new(models: models, logger: Rubotty::Log.null) }
  let(:actions) { Rubotty::ControlPlane::Search::ACTIONS }
  let(:mine) { models.community.where(slug: "alpha-co").first }

  def drop_control_plane(database)
    database.drop_table?(*Rubotty::Storage::Transfer::CONTROL_PLANE_TABLES.reverse)
    database.drop_table?(:schema_info)
  end

  before do
    drop_control_plane(db)
    Rubotty::ControlPlane::Migrator.run(db)
    search_community(models, slug: "alpha-co", marker: "alpha")
    search_community(models, slug: "beta-co", marker: "beta")
  end

  after do
    drop_control_plane(db)
    db.disconnect
  end

  def scoped = Rubotty::ControlPlane::Search::Scope.communities(actions_by_community_id: { mine.id => actions })

  def wide = Rubotty::ControlPlane::Search::Scope.deployment_wide(actions: actions)

  it "matches a substring case-insensitively on #{driver}" do
    %w[lounge LOUNGE LoUnGe].each do |query|
      hits = search.call(query: query, scope: wide).entities

      expect(hits.map(&:community_slug)).to match_array(%w[alpha-co beta-co]), "no case fold for #{query.inspect}"
    end
  end

  it "reaches every kind on #{driver}, so no query here is invalid SQL on this backend" do
    Rubotty::ControlPlane::Search::KINDS.each do |kind|
      hits = search.call(query: search_terms("alpha").fetch(kind.name), scope: wide).entities

      expect(hits.map(&:kind)).to include(kind.name), "#{kind.name} did not come back on #{driver}"
    end
  end

  it "keeps one community's scope out of another's rows on #{driver}" do
    Rubotty::ControlPlane::Search::KINDS.each do |kind|
      results = search.call(query: search_terms("beta").fetch(kind.name), scope: scoped)

      expect(results.entities).to be_empty, "#{kind.name} leaked on #{driver}"
      expect(results.destinations).to be_empty, "#{kind.name} leaked a destination on #{driver}"
    end
  end

  it "answers nothing at all for an empty permitted set on #{driver}" do
    results = search.call(query: "lounge", scope: Rubotty::ControlPlane::Search::Scope.none)

    expect(results.entities).to be_empty
  end

  it "takes a LIKE wildcard literally on #{driver}" do
    expect(search.call(query: "%%", scope: wide).entities).to be_empty
  end
end
