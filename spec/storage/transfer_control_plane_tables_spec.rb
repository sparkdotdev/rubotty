# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Guards against the failure this constant already had once: CONTROL_PLANE_TABLES
# silently missing a table a migration creates, which lost real data with no error,
# since the transfer tool and boot import only touch the tables it names. The real
# list here is derived from a freshly migrated database, so it cannot drift again.
RSpec.describe Rubotty::Storage::Transfer, "::CONTROL_PLANE_TABLES" do
  subject(:control_plane_tables) { described_class::CONTROL_PLANE_TABLES }

  # schema_info is Sequel::Migrator's own bookkeeping and never copied. Nothing else
  # is excluded: the message-map tables come from Storage::Schema.apply rather than
  # ControlPlane::Migrator, so a database migrated only through the latter, as here,
  # never has them to subtract.
  NON_CONTROL_PLANE_TABLES = %i[schema_info].freeze

  it "covers every control-plane table the migrations actually create" do
    db = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(db)

    actual_tables = (db.tables - NON_CONTROL_PLANE_TABLES).sort
    declared_tables = control_plane_tables.sort

    expect(declared_tables).to eq(actual_tables),
      "Transfer::CONTROL_PLANE_TABLES is out of sync with the migrations. " \
      "Missing from the constant: #{(actual_tables - declared_tables).inspect}. " \
      "Extra in the constant (no longer created by any migration): " \
      "#{(declared_tables - actual_tables).inspect}. " \
      "Update lib/rubotty/storage/transfer.rb, in foreign-key-safe order " \
      "(a table never appears before one it references)."
  ensure
    db&.disconnect
  end

  it "lists every table exactly once, with no duplicate that would double-copy rows" do
    expect(control_plane_tables.uniq).to eq(control_plane_tables)
  end

  it "retains both room summary tables after their community parent" do
    expect(control_plane_tables).to include(:room_summary_messages, :room_summary_watermarks)

    community = control_plane_tables.index(:communities)
    expect(community).to be < control_plane_tables.index(:room_summary_messages)
    expect(community).to be < control_plane_tables.index(:room_summary_watermarks)
  end

  it "orders every table after every table it has a foreign key to" do
    db = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(db)
    position = control_plane_tables.each_with_index.to_h

    control_plane_tables.each do |table|
      db.foreign_key_list(table).each do |fk|
        referenced = fk[:table]
        next unless position.key?(referenced)

        expect(position[referenced]).to be < position[table],
          "#{table} references #{referenced} via a foreign key, so #{referenced} " \
          "must be listed first in CONTROL_PLANE_TABLES"
      end
    end
  ensure
    db&.disconnect
  end
end
