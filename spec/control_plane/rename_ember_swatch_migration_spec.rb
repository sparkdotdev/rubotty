# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 082: the swatch named "ember" is renamed "forest" everywhere, so
# a dashboard_appearances row that already picked it needs the same rename
# rather than pointing at a swatch that no longer exists.
RSpec.describe "rename_ember_swatch_to_forest migration", :control_plane do
  let(:db) { Sequel.sqlite }
  let(:now) { Time.now }

  before { Rubotty::ControlPlane::Migrator.new(db).run(target: 81) }

  def insert_appearance(swatch:)
    db[:dashboard_appearances].insert(
      name: "default", theme: "code-monkey", swatch: swatch, chart_style: "in-house",
      created_at: now, updated_at: now
    )
  end

  def run_migration! = Rubotty::ControlPlane::Migrator.new(db).run(target: 82)

  def rollback! = Rubotty::ControlPlane::Migrator.new(db).run(target: 81)

  def current_swatch = db[:dashboard_appearances].where(name: "default").first[:swatch]

  it "renames an existing ember row to forest" do
    insert_appearance(swatch: "ember")
    run_migration!

    expect(current_swatch).to eq("forest")
  end

  it "leaves a row already on another swatch alone" do
    insert_appearance(swatch: "harbour")
    run_migration!

    expect(current_swatch).to eq("harbour")
  end

  it "leaves no row untouched when none was saved" do
    run_migration!

    expect(db[:dashboard_appearances].count).to eq(0)
  end

  it "reverses back to ember on rollback" do
    insert_appearance(swatch: "ember")
    run_migration!
    rollback!

    expect(current_swatch).to eq("ember")
  end
end
