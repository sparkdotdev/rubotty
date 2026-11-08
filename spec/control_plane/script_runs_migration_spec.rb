# frozen_string_literal: true

require "spec_helper"
require "sequel"

# A row per script per day per source, which is what makes a count something
# retention can age out rather than a lifetime total nothing ever reclaims.
RSpec.describe "script runs migration", :control_plane do
  let(:db) { Sequel.sqlite }

  def migrated
    Rubotty::ControlPlane::Migrator.run(db)
    db
  end

  it "creates the table with both counters" do
    columns = migrated.schema(:script_runs).to_h

    expect(columns.keys).to include(:community_id, :script_id, :day, :source, :runs, :failures)
    expect(columns[:runs][:allow_null]).to be(false)
    expect(columns[:failures][:allow_null]).to be(false)
  end

  it "starts both counters at zero, so an insert only has to name what it counted" do
    columns = migrated.schema(:script_runs).to_h

    expect(columns[:runs][:ruby_default]).to eq(0)
    expect(columns[:failures][:ruby_default]).to eq(0)
  end

  # The whole coalescing scheme depends on a second writer for the same day
  # colliding rather than making a parallel row nobody adds up.
  it "keeps one row per script per day per source" do
    indexes = migrated.indexes(:script_runs)

    expect(indexes[:script_runs_day_idx][:columns]).to eq(%i[script_id day source])
    expect(indexes[:script_runs_day_idx][:unique]).to be(true)
  end

  it "indexes the day, since the retention sweep reads nothing else" do
    expect(migrated.indexes(:script_runs)[:script_runs_age_idx][:columns]).to eq([:day])
  end

  it "takes a script's counts with the script" do
    references = migrated.foreign_key_list(:script_runs).to_h { |key| [key[:columns], key[:table]] }

    expect(references[[:script_id]]).to eq(:community_scripts)
    expect(references[[:community_id]]).to eq(:communities)
  end

  it "is idempotent" do
    migrated
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
  end

  it "rolls back to 70, dropping the table but keeping the scripts" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 70)

    expect(db.table_exists?(:script_runs)).to be(false)
    expect(db.table_exists?(:community_scripts)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)

    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:script_runs)).to be(true)
  end
end
