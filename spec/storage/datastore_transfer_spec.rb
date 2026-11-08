# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "tmpdir"
require "fileutils"

# The datastore migration tool: copy the WHOLE datastore between Sequel backends,
# in either direction, without losing state. The SQLite round trip runs everywhere
# and is the contract every backend pairing must satisfy; the server round trips
# are guarded on their URL variables so CI's storage job exercises them.
RSpec.describe Rubotty::Storage::Transfer do
  let(:tmp) { Dir.mktmpdir("rubotty-transfer") }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  # The same fixture the seed and control-plane pg specs use, so the source starts
  # from a realistic interconnected topology.
  let(:config) do
    Rubotty::Config::Loader.load_file(
      File.expand_path("../fixtures/control_plane/sample.config.yaml", __dir__),
      env: { "TELEGRAM_BOT_TOKEN" => "tg", "DISCORD_BOT_TOKEN" => "dc" }
    )
  end

  # Stand up a fully-populated source datastore at +path+: the control plane seeded
  # from the config, one row in each remaining control-plane table, and the whole
  # message-map regime written through the store API.
  def seed_source(path)
    store = Rubotty::Storage::Factory.build({ driver: :sqlite, path: path })
    db = store.db
    Rubotty::ControlPlane::Migrator.run(db)
    models = Rubotty::ControlPlane.models(db)
    community_id = Rubotty::ControlPlane::Seed.from_model(config, models: models, slug: "sample")
    now = Time.now

    db[:operator_requests].insert(community_id: community_id, adapter: "telegram",
                                  requester_native_id: "555", state: "pending", requested_at: now)
    db[:observed_identities].insert(community_id: community_id, adapter: "telegram",
                                    native_id: "555", username: "alex",
                                    first_seen_at: now, last_seen_at: now)
    db[:ephemeral_messages].insert(group_id: "g1", endpoint_id: "tg-general",
                                   native_id: "9001", delete_at: now + 60,
                                   session_id: "s1", created_at: now)
    db[:scheduled_jobs].insert(community: "sample", kind: "announcement", payload: "{}",
                               run_at: now + 60, status: "pending", attempts: 0, created_at: now)
    db[:warnings].insert(community: "sample", adapter: "telegram", subject_native_id: "555",
                         active: true, issued_at: now)
    db[:active_sanctions].insert(community: "sample", adapter: "telegram", subject_native_id: "555",
                                 action: "mute", endpoints: "[]", until_at: now + 3600,
                                 active: true, created_at: now)
    db[:audit_events].insert(community: "sample", source: "moderation", action: "delete",
                             created_at: now)

    store.record(source: ref("tg", "100"), destination: ref("dc", "900"), room_id: "general")
    store.add_reaction(ref("tg", "100"), reaction: Rubotty::Core::Reaction.new(emoji: "👍"),
                       actor_id: "555")
    store.put_state("last_announce", now.to_i.to_s)
    store.claim_relay(source: ref("tg", "100"), operation: "new")
    store.close
  end

  # Raw per-table row counts for a sqlite file, over exactly the tables the tool
  # copies, so schema_info and the other internals are left out as it leaves them.
  def sqlite_counts(path)
    db = Sequel.connect("sqlite://#{path}")
    described_class::TABLES.to_h { |table| [table, db.table_exists?(table) ? db[table].count : 0] }
  ensure
    db&.disconnect
  end

  describe ".storage_config" do
    it "reads a sqlite path" do
      expect(described_class.storage_config("sqlite:data/message_map.sqlite3"))
        .to eq(driver: :sqlite, path: "data/message_map.sqlite3")
    end

    it "treats a bare env var name after pg: as url_env, so no credential is on the command line" do
      expect(described_class.storage_config("pg:DATABASE_URL")).to eq(driver: :pg, url_env: "DATABASE_URL")
    end

    it "reads an inline pg url" do
      expect(described_class.storage_config("pg:postgres://u:p@h/db"))
        .to eq(driver: :pg, url: "postgres://u:p@h/db")
    end

    it "reads a bare postgres:// url as pg" do
      expect(described_class.storage_config("postgres://u:p@h/db")).to eq(driver: :pg, url: "postgres://u:p@h/db")
    end

    it "accepts the postgresql:// scheme some providers hand out" do
      expect(described_class.storage_config("postgresql://h/db")).to eq(driver: :pg, url: "postgresql://h/db")
    end

    it "treats a bare env var name after mdb: as url_env" do
      expect(described_class.storage_config("mdb:MDB_DATABASE_URL")).to eq(driver: :mdb, url_env: "MDB_DATABASE_URL")
    end

    it "reads an inline mdb url and accepts the mariadb alias" do
      expect(described_class.storage_config("mdb:mysql://u:p@h/db")).to eq(driver: :mdb, url: "mysql://u:p@h/db")
      expect(described_class.storage_config("mariadb:mariadb://h/db")).to eq(driver: :mdb, url: "mariadb://h/db")
    end

    it "rejects an empty spec" do
      expect { described_class.storage_config("") }.to raise_error(Rubotty::ConfigError, /required/)
    end

    it "rejects an unparseable spec" do
      expect { described_class.storage_config("not a spec") }.to raise_error(Rubotty::ConfigError, /cannot read/)
    end
  end

  describe ".safe_label" do
    it "never prints a raw pg url, so a password cannot leak into a report" do
      expect(described_class.safe_label(driver: :pg, url: "postgres://user:secret@host/db")).to eq("pg (url)")
    end

    it "names the environment variable for a pg url_env" do
      expect(described_class.safe_label(driver: :pg, url_env: "DATABASE_URL")).to eq("pg (env DATABASE_URL)")
    end

    it "shows the file for a sqlite store" do
      expect(described_class.safe_label(driver: :sqlite, path: "/data/x.sqlite3")).to eq("sqlite:/data/x.sqlite3")
    end

    it "never prints a raw mdb url either" do
      expect(described_class.safe_label(driver: :mdb, url: "mysql://user:secret@host/db")).to eq("mdb (url)")
      expect(described_class.safe_label(driver: :mdb, url_env: "MDB_DATABASE_URL")).to eq("mdb (env MDB_DATABASE_URL)")
    end
  end

  describe "sqlite to sqlite" do
    let(:src) { File.join(tmp, "src.sqlite3") }
    let(:dst) { File.join(tmp, "dst.sqlite3") }

    def transfer(dry_run: false)
      described_class.new(
        source: { driver: :sqlite, path: src },
        target: { driver: :sqlite, path: dst },
        dry_run: dry_run
      ).run
    end

    it "preserves a customized deployment default instead of keeping the target seed" do
      seed_source(src)
      db = Sequel.sqlite(src)
      config = '{"ack_ttl_seconds":99,"acknowledge":false}'
      db[:feature_settings].where(community_id: nil).update(config: config)
      expect(transfer).to be_ok
      target = Sequel.sqlite(dst)
      expect(target[:feature_settings].where(community_id: nil).get(:config)).to eq(config)
      expect(transfer).to be_ok
    ensure
      db&.disconnect
      target&.disconnect
    end

    it "copies and verifies all rows across small keyset batches on a resumed run" do
      stub_const("Rubotty::Storage::Transfer::BATCH", 2)
      seed_source(src)
      expect(transfer).to be_ok
      expect(transfer).to be_ok
      source = Sequel.sqlite(src)
      target = Sequel.sqlite(dst)
      expect(source[:feature_settings].count).to be > 2
      expect(target[:feature_settings].order(:id).all).to eq(source[:feature_settings].order(:id).all)
    ensure
      source&.disconnect
      target&.disconnect
    end

    it "rejects a same-id parent from another dataset without changing either side" do
      seed_source(src)
      seed_source(dst)
      target = Sequel.sqlite(dst)
      target[:communities].update(slug: "unrelated", name: "Unrelated")
      before = target[:communities].all
      expect { transfer }.to raise_error(Rubotty::StorageError, /conflicts.*communities/)
      expect(target[:communities].all).to eq(before)
    ensure
      target&.disconnect
    end

    it "rolls back earlier tables when a later table holds unrelated target rows" do
      seed_source(src)
      expect(transfer).to be_ok
      target = Sequel.sqlite(dst)
      target[:bridge_state].update(key: "different-key")
      source = Sequel.sqlite(src)
      source[:communities].insert(slug: "new", name: "New", created_at: Time.now, updated_at: Time.now)
      expect { transfer }.to raise_error(Rubotty::StorageError, /different.*row counts/)
      expect(target[:communities].where(slug: "new").count).to eq(0)
      expect(target[:bridge_state].select_map(:key)).to eq(["different-key"])
    ensure
      target&.disconnect
      source&.disconnect
    end

    it "copies every table and verification passes" do
      seed_source(src)
      report = transfer

      expect(report).to be_ok
      expect(sqlite_counts(src)).to eq(sqlite_counts(dst))

      by_table = report.rows.to_h { |row| [row[:table], row] }
      # Both regimes carried rows across, beyond copying the empty tables.
      expect(by_table[:communities][:target]).to eq(1)
      expect(by_table[:channels][:target]).to be > 0
      expect(by_table[:audit_events][:target]).to eq(1)
      expect(by_table[:message_map][:target]).to eq(1)
      expect(by_table[:reaction_state][:target]).to eq(1)
      expect(by_table[:bridge_state][:target]).to eq(1)
      expect(by_table[:relay_claims][:target]).to eq(1)
    end

    it "preserves foreign keys and the message map, so the target can run the bot" do
      seed_source(src)
      transfer

      store = Rubotty::Storage::Factory.build({ driver: :sqlite, path: dst })
      begin
        models = Rubotty::ControlPlane.models(store.db)
        community = models.community.where(slug: "sample").first
        expect(community).not_to be_nil
        channel = models.channel.where(community_id: community.id).first
        # The channel's foreign key still resolves to a real platform_connection.
        expect(models.platform_connection.where(id: channel.platform_connection_id).first).not_to be_nil

        # The message map reads back through the store API, both directions.
        expect(store.counterparts(ref("tg", "100"))).to eq([ref("dc", "900")])
        expect(store.origins(ref("dc", "900"))).to eq([ref("tg", "100")])
        expect(store.reactions_on(ref("tg", "100")).map(&:emoji)).to eq(["👍"])
        expect(store.get_state("last_announce")).not_to be_nil
        expect(store.relay_claimed?(source: ref("tg", "100"), operation: "new")).to be(true)
      ensure
        store.close
      end
    end

    it "continues the sqlite id sequence past the copied rows, so a new insert does not collide" do
      seed_source(src)
      transfer

      db = Sequel.connect("sqlite://#{dst}")
      begin
        now = Time.now
        new_id = db[:communities].insert(slug: "fresh", name: "Fresh", status: "active",
                                         settings: "{}", created_at: now, updated_at: now)
        expect(new_id).to be > db[:communities].where(slug: "sample").get(:id)
      ensure
        db.disconnect
      end
    end

    it "is idempotent: a second run neither duplicates nor breaks verification" do
      seed_source(src)
      transfer
      first = sqlite_counts(dst)

      report = transfer
      expect(report).to be_ok
      expect(sqlite_counts(dst)).to eq(first)
    end

    it "dry run reports source counts and does not create the target at all" do
      seed_source(src)
      report = transfer(dry_run: true)

      expect(report.dry_run).to be(true)
      expect(report.total_source).to be > 0
      expect(File.exist?(dst)).to be(false)
    end
  end

  describe "guards" do
    it "refuses a source that is not Sequel-backed" do
      expect do
        described_class.new(source: { driver: :memory },
                            target: { driver: :sqlite, path: File.join(tmp, "d.sqlite3") }).run
      end.to raise_error(Rubotty::StorageError, /source.*not Sequel-backed/)
    end

    it "refuses a target that is not Sequel-backed" do
      src = File.join(tmp, "src.sqlite3")
      seed_source(src)
      expect do
        described_class.new(source: { driver: :sqlite, path: src }, target: { driver: :memory }).run
      end.to raise_error(Rubotty::StorageError, /target.*not Sequel-backed/)
    end

    it "refuses to copy a datastore onto itself" do
      cfg = { driver: :sqlite, path: File.join(tmp, "same.sqlite3") }
      expect { described_class.new(source: cfg, target: cfg).run }
        .to raise_error(Rubotty::ConfigError, /same/)
    end
  end

  # Copies sqlite to Postgres and back, and proves the pg id sequence was reset so
  # the target can take fresh inserts after the copy.
  describe "postgres round trip", if: ENV["TEST_DATABASE_URL"] do
    let(:pg_url) { ENV.fetch("TEST_DATABASE_URL") }

    def drop_all
      db = Sequel.connect(pg_url)
      described_class::TABLES.reverse_each { |table| db.drop_table?(table) }
      db.drop_table?(:schema_info)
      db.disconnect
    end

    before { drop_all }
    after { drop_all }

    it "copies sqlite to postgres and back, matching row counts and resetting the id sequence" do
      src = File.join(tmp, "src.sqlite3")
      back = File.join(tmp, "back.sqlite3")
      seed_source(src)

      to_pg = described_class.new(
        source: { driver: :sqlite, path: src },
        target: { driver: :pg, url: pg_url }
      ).run
      expect(to_pg).to be_ok

      pg = Sequel.connect(pg_url)
      begin
        expect(pg[:communities].count).to eq(1)
        # The sequence advanced past the copied ids, so a fresh insert does not
        # collide on the primary key.
        now = Time.now
        expect do
          pg[:communities].insert(slug: "fresh", name: "Fresh", status: "active",
                                  settings: "{}", created_at: now, updated_at: now)
        end.not_to raise_error
        pg[:communities].where(slug: "fresh").delete
      ensure
        pg.disconnect
      end

      from_pg = described_class.new(
        source: { driver: :pg, url: pg_url },
        target: { driver: :sqlite, path: back }
      ).run
      expect(from_pg).to be_ok
      expect(sqlite_counts(src)).to eq(sqlite_counts(back))
    end
  end

  # Copies sqlite to MariaDB and back. MariaDB advances its own AUTO_INCREMENT past
  # the copied ids, so it needs no sequence reset and a fresh insert still fits.
  describe "mariadb round trip", if: ENV["TEST_MYSQL_DATABASE_URL"] do
    let(:mdb_url) { ENV.fetch("TEST_MYSQL_DATABASE_URL") }

    # Built through the Factory so the connection carries the MariaDB dialect setup
    # (utf8mb4 and kept TEXT defaults), the same way the app connects.
    def mdb_connection
      Rubotty::Storage::Factory.build(
        { driver: :mdb, url_env: "TEST_MYSQL_DATABASE_URL", auto_migrate: false }, env: ENV
      ).db
    end

    def drop_all
      db = mdb_connection
      # The tool's TABLES list is parents-first, so drop it in reverse to satisfy
      # MariaDB's foreign keys (children before their parents).
      described_class::TABLES.reverse_each { |table| db.drop_table?(table) }
      db.drop_table?(:schema_info)
      db.disconnect
    end

    before { drop_all }
    after { drop_all }

    it "copies sqlite to mariadb and back, matching row counts, with mariadb tracking the id" do
      src = File.join(tmp, "src.sqlite3")
      back = File.join(tmp, "back.sqlite3")
      seed_source(src)

      to_mdb = described_class.new(
        source: { driver: :sqlite, path: src },
        target: { driver: :mdb, url: mdb_url }
      ).run
      expect(to_mdb).to be_ok

      mdb = mdb_connection
      begin
        expect(mdb[:communities].count).to eq(1)
        now = Time.now
        expect do
          mdb[:communities].insert(slug: "fresh", name: "Fresh", status: "active",
                                   settings: "{}", created_at: now, updated_at: now)
        end.not_to raise_error
        mdb[:communities].where(slug: "fresh").delete
      ensure
        mdb.disconnect
      end

      from_mdb = described_class.new(
        source: { driver: :mdb, url: mdb_url },
        target: { driver: :sqlite, path: back }
      ).run
      expect(from_mdb).to be_ok
      expect(sqlite_counts(src)).to eq(sqlite_counts(back))
    end
  end
end
