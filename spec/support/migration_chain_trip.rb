# frozen_string_literal: true

require "sequel"

Sequel.extension :migration

# Walks the whole migration chain over {ProdShapedFixture} ONCE per backend, up to
# the head, back down to the fixture's floor and up again, so every example reads
# the recording rather than repeating a walk that is a DDL round trip per step.
module MigrationChainTrip
  DIRECTORY = File.expand_path("../../db/migrations", __dir__)

  # SQLite always runs; the server backends are skipped unless their URL variable
  # points at a real server.
  BACKENDS = [
    { name: "sqlite", driver: :sqlite, url_env: nil },
    { name: "postgres", driver: :pg, url_env: "TEST_DATABASE_URL" },
    { name: "mariadb", driver: :mdb, url_env: "TEST_MYSQL_DATABASE_URL" }
  ].freeze

  def self.available?(backend) = backend[:url_env].nil? || !ENV[backend[:url_env]].nil?

  # Built through Storage::Factory so the dialect preparation (utf8mb4, and the
  # TEXT column defaults MariaDB's Sequel adapter strips) is under test too.
  def self.connect(backend)
    return Sequel.sqlite if backend[:driver] == :sqlite

    Rubotty::Storage::Factory.build(
      { driver: backend[:driver], url_env: backend[:url_env], auto_migrate: false }, env: ENV
    ).db
  end

  def self.observe(backend)
    db = connect(backend)
    begin
      record(db)
    ensure
      clear(db)
      db.disconnect
    end
  end

  def self.record(db)
    clear(db)
    fresh = fresh_shapes(db)
    clear(db)

    ProdShapedFixture.install(db, dir: DIRECTORY)
    climbed = observation(db)

    migrate(db, target: ProdShapedFixture::FLOOR)
    floor = { shapes: SchemaShape.all(db), counts: ProdShapedFixture.row_counts(db) }

    migrate(db)
    reclimbed = observation(db)

    { fresh: fresh, climbed: climbed, floor: floor, reclimbed: reclimbed }
  end

  # Everything readable at the head of the chain, with the script layer kept apart
  # because a rollback below migration 031 takes its tables away.
  def self.observation(db)
    { shapes: SchemaShape.all(db), census: ProdShapedFixture.census(db),
      counts: ProdShapedFixture.row_counts(db), scripts: ProdShapedFixture.script_census(db) }
  end

  # An empty build, stopping at the fixture's floor on the way past so the
  # rolled-back schema has something to be compared against.
  def self.fresh_shapes(db)
    migrate(db, target: ProdShapedFixture::FLOOR)
    floor = SchemaShape.all(db)
    migrate(db)
    { floor: floor, top: SchemaShape.all(db) }
  end

  def self.migrate(db, target: nil)
    if target
      Sequel::Migrator.run(db, DIRECTORY, target: target)
    else
      Sequel::Migrator.run(db, DIRECTORY)
    end
  end

  # Take the database back to nothing, dropping in the reverse of
  # Transfer::CONTROL_PLANE_TABLES' foreign-key-safe insertion order so a second
  # hand-maintained drop order cannot drift out of sync with it.
  def self.clear(db)
    db.drop_table?(*Rubotty::Storage::Transfer::CONTROL_PLANE_TABLES.reverse)
    db.drop_table?(:schema_info)
  end
end
