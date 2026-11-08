# frozen_string_literal: true

require "spec_helper"
require "sequel"

Sequel.extension :migration

# Migrating all the way down and back up has to land on the schema a fresh
# migration builds. A rollback that runs without raising can still fail to undo
# what it claims: 034 made community_script_id nullable and never put that back,
# and its down left behind an index it had added to keep a foreign key covered.
RSpec.describe "the control plane migrations, down and back up" do
  def directory = File.expand_path("../db/migrations", __dir__)

  def migrated(target: nil)
    db = Sequel.sqlite
    if target
      Sequel::Migrator.run(db, directory, target: target)
    else
      Sequel::Migrator.run(db, directory)
    end
    db
  end

  # Shared with spec/migrations_prod_shape_spec.rb so both mean the same by "shape".
  def shape(db, table) = SchemaShape.of(db, table)

  it "runs all the way up" do
    expect(migrated.tables).to include(:script_memos, :script_stats)
  end

  describe "script_memos, which buckets and per room keys both reshaped" do
    it "comes back to the same shape after a full round trip" do
      fresh = shape(migrated, :script_memos)

      round_tripped = migrated
      Sequel::Migrator.run(round_tripped, directory, target: 0)
      Sequel::Migrator.run(round_tripped, directory)

      expect(shape(round_tripped, :script_memos)).to eq(fresh)
    end

    it "comes back to the columns of the version it was rolled back to" do
      at_033 = shape(migrated(target: 33), :script_memos)

      rolled = migrated
      Sequel::Migrator.run(rolled, directory, target: 33)

      expect(shape(rolled, :script_memos)[:columns]).to eq(at_033[:columns])
    end

    # The documented exception: this index goes in on the way down so the scope
    # index can be dropped at all, and it cannot then be dropped itself, being the
    # only one left with community_id leftmost and MariaDB refusing to let the last
    # index covering a foreign key go. Named so the exception stays one index wide.
    it "keeps only the one index MariaDB will not let go of" do
      at_033 = shape(migrated(target: 33), :script_memos)[:indexes]

      rolled = migrated
      Sequel::Migrator.run(rolled, directory, target: 33)

      expect(shape(rolled, :script_memos)[:indexes] - at_033).to eq([:script_memos_community_idx])
    end
  end

  # 045 took the file bytes out of guest_uploads and renamed the serve token to the
  # digest of one. A down that dropped the new columns and stopped there would run
  # clean and leave a table with no way to hold a file, and the round trip through
  # zero would hide that because 011 drops the table on the way past.
  describe "guest_uploads, whose bytes moved to the object store" do
    it "comes back to the shape of the version it was rolled back to" do
      at_044 = shape(migrated(target: 44), :guest_uploads)

      rolled = migrated
      Sequel::Migrator.run(rolled, directory, target: 44)

      expect(shape(rolled, :guest_uploads)).to eq(at_044)
    end

    # Neither direction drops an index: the unique serve index is renamed along with
    # its column, so MariaDB never sees a drop and there is no exception to carve out.
    it "keeps every index it started with, in both directions" do
      names = shape(migrated, :guest_uploads)[:indexes]

      rolled = migrated
      Sequel::Migrator.run(rolled, directory, target: 44)

      expect(names).to eq(%i[guest_uploads_channel_idx guest_uploads_room_idx guest_uploads_token_idx])
      expect(shape(rolled, :guest_uploads)[:indexes]).to eq(names)
    end
  end

  # Two tables that cascade into each other, so the down has to drop the leaf
  # first or the foreign key refuses it: rolled back to 045 rather than through
  # zero, since dropping the communities table would take these with it and
  # hide a down that never worked.
  describe "the participation tables, which a session cascades through" do
    TABLES = %i[script_sessions script_rounds].freeze

    it "takes both away, and puts them back the same" do
      fresh = TABLES.to_h { |table| [table, shape(migrated, table)] }

      rolled = migrated
      Sequel::Migrator.run(rolled, directory, target: 45)
      expect(rolled.tables & TABLES).to be_empty

      Sequel::Migrator.run(rolled, directory)
      TABLES.each { |table| expect(shape(rolled, table)).to eq(fresh[table]) }
    end

    it "drops a session's rounds with it" do
      db = migrated
      db[:communities].insert(slug: "sample", name: "SAMPLE", created_at: Time.now, updated_at: Time.now)
      community = db[:communities].first[:id]
      now = Time.now
      db[:script_sessions].insert(community_id: community, room_key: "general", kind: "trivia",
                                  state: "open", opened_at: now, created_at: now, updated_at: now)
      session = db[:script_sessions].first[:id]
      db[:script_rounds].insert(community_id: community, session_id: session, position: 1,
                                state: "open", opened_at: now, created_at: now, updated_at: now)

      db[:script_sessions].where(id: session).delete

      expect(db[:script_rounds].count).to eq(0)
    end
  end

  # 062 trims what 050 built: script_responses and script_entries go away
  # outright, and script_rounds trades prompt, answer and options for
  # on_close, closes_at and data. Rolled back to 061 rather than through
  # zero, for the same foreign key reason the block above is.
  describe "trimming participation to a round with no game specific columns" do
    it "comes back to the same script_rounds shape after a full round trip" do
      fresh = shape(migrated, :script_rounds)

      round_tripped = migrated
      Sequel::Migrator.run(round_tripped, directory, target: 61)
      Sequel::Migrator.run(round_tripped, directory)

      expect(shape(round_tripped, :script_rounds)).to eq(fresh)
    end

    it "puts script_responses and script_entries back on the way down to 061" do
      at_061 = migrated(target: 61)

      expect(at_061.tables).to include(:script_responses, :script_entries)
    end

    it "takes script_responses and script_entries away again on the way back up" do
      expect(migrated.tables).not_to include(:script_responses, :script_entries)
    end
  end

  it "leaves every table as a fresh migration builds it" do
    fresh = migrated
    rolled = migrated
    Sequel::Migrator.run(rolled, directory, target: 0)
    Sequel::Migrator.run(rolled, directory)

    fresh.tables.sort.each do |table|
      expect(shape(rolled, table)).to eq(shape(fresh, table)), "#{table} differs after a round trip"
    end
  end
end
