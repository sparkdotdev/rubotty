# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "tmpdir"
require "fileutils"

# The portable snapshot tool: dump the whole datastore to one .yaml.gz file and
# restore it, so an operator can move a deployment to a machine that cannot
# reach the old one directly. Same table list and round-trip contract Transfer
# uses: seed a fully-populated sqlite source, export, import, and compare.
RSpec.describe Rubotty::Storage::Snapshot do
  let(:tmp) { Dir.mktmpdir("rubotty-snapshot") }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  let(:config) do
    Rubotty::Config::Loader.load_file(
      File.expand_path("../fixtures/control_plane/sample.config.yaml", __dir__),
      env: { "TELEGRAM_BOT_TOKEN" => "tg", "DISCORD_BOT_TOKEN" => "dc" }
    )
  end

  # Mirrors Transfer's own seed_source: a fully-populated source, one row in
  # each remaining control-plane table plus the whole message-map regime.
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
    db[:scheduled_jobs].insert(community: "sample", kind: "announcement", payload: "{}",
                               run_at: now + 60, status: "pending", attempts: 0, created_at: now)
    db[:warnings].insert(community: "sample", adapter: "telegram", subject_native_id: "555",
                         active: true, issued_at: now)

    store.record(source: ref("tg", "100"), destination: ref("dc", "900"), room_id: "general")
    store.add_reaction(ref("tg", "100"), reaction: Rubotty::Core::Reaction.new(emoji: "👍"),
                       actor_id: "555")
    store.close
  end

  def sqlite_counts(path)
    db = Sequel.connect("sqlite://#{path}")
    Rubotty::Storage::Transfer::TABLES.to_h { |table| [table, db.table_exists?(table) ? db[table].count : 0] }
  ensure
    db&.disconnect
  end

  let(:src) { File.join(tmp, "src.sqlite3") }
  let(:dst) { File.join(tmp, "dst.sqlite3") }
  let(:snapshot_path) { File.join(tmp, "snapshot.yaml.gz") }

  def export = described_class.export(source: { driver: :sqlite, path: src }, path: snapshot_path)

  def import = described_class.import(path: snapshot_path, target: { driver: :sqlite, path: dst })

  describe "round trip" do
    it "restores customized and additional deployment defaults with their original ids" do
      seed_source(src)
      source = Rubotty::Storage::Factory.build({ driver: :sqlite, path: src })
      source.db[:feature_settings].where(community_id: nil).update(
        id: 500, config: '{"ack_ttl_seconds":99,"acknowledge":false}', updated_at: Time.now + 1
      )
      source.db[:feature_settings].insert(
        id: 501, community_id: nil, room_id: nil, feature: "backfill", enabled: true,
        config: '{"safe_horizon_seconds":3600}', created_at: Time.now, updated_at: Time.now
      )
      expected = source.db[:feature_settings].where(community_id: nil).order(:id).all
      export
      import
      target = Rubotty::Storage::Factory.build({ driver: :sqlite, path: dst })
      expect(target.db[:feature_settings].where(community_id: nil).order(:id).all).to eq(expected)
    ensure
      source&.close
      target&.close
    end

    it "reads map state and control-plane parents from one live database snapshot" do
      seed_source(src)
      source = Rubotty::Storage::Factory.build({ driver: :sqlite, path: src })
      source.put_state("audit-state", "before")
      writer = Rubotty::Storage::Factory.build({ driver: :sqlite, path: src })
      snapshot = described_class.new
      inserted = false
      allow(snapshot).to receive(:normalize_row).and_wrap_original do |original, table, row|
        normalized = original.call(table, row)
        if table == :communities && !inserted
          inserted = true
          now = Time.now
          id = writer.db[:communities].insert(slug: "later", name: "Later", created_at: now, updated_at: now)
          writer.db[:platform_connections].insert(community_id: id, adapter: "telegram", account: "later",
                                                   external_id: "123", created_at: now, updated_at: now)
          writer.put_state("audit-state", "after")
          writer.record(source: ref("late", "1"), destination: ref("later", "2"), room_id: "late")
        end
        normalized
      end
      bytes = snapshot.document_bytes(source.db)
      target = Rubotty::Storage::Factory.build({ driver: :sqlite, path: dst })
      expect { described_class.restore_bytes(target.db, bytes) }.not_to raise_error
      expect(target.db[:communities].select_map(:slug)).to eq(["sample"])
      expect(target.get_state("audit-state")).to eq("before")
      expect(target.size).to eq(1)
      expect(writer.get_state("audit-state")).to eq("after")
    ensure
      source&.close
      writer&.close
      target&.close
    end

    it "writes a gzipped file and every table's row count matches after import" do
      seed_source(src)
      export

      expect(File.exist?(snapshot_path)).to be(true)
      # It really is gzip: reading it raw does not look like YAML.
      expect(File.binread(snapshot_path)[0, 2].bytes).to eq([0x1f, 0x8b])

      import
      expect(sqlite_counts(dst)).to eq(sqlite_counts(src))
    end

    it "preserves foreign keys and the message map, so the target can run the bot" do
      seed_source(src)
      export
      import

      store = Rubotty::Storage::Factory.build({ driver: :sqlite, path: dst })
      begin
        models = Rubotty::ControlPlane.models(store.db)
        community = models.community.where(slug: "sample").first
        expect(community).not_to be_nil
        channel = models.channel.where(community_id: community.id).first
        expect(models.platform_connection.where(id: channel.platform_connection_id).first).not_to be_nil

        expect(store.counterparts(ref("tg", "100"))).to eq([ref("dc", "900")])
        expect(store.reactions_on(ref("tg", "100")).map(&:emoji)).to eq(["👍"])
      ensure
        store.close
      end
    end

    it "round-trips a timestamp exactly, not just its row count" do
      seed_source(src)
      before_export = Sequel.connect("sqlite://#{src}")[:warnings].get(:issued_at)
      export
      import

      after_import = Sequel.connect("sqlite://#{dst}")[:warnings].get(:issued_at)
      expect(after_import.to_i).to eq(before_export.to_i)
    end

    it "continues the sqlite id sequence past the imported rows" do
      seed_source(src)
      export
      import

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

    it "reports a non-zero row count per non-empty table" do
      seed_source(src)
      report = export

      by_table = report.tables.to_h { |row| [row[:table], row[:rows]] }
      expect(by_table[:communities]).to eq(1)
      expect(by_table[:message_map]).to eq(1)
      expect(by_table[:reaction_state]).to eq(1)
    end
  end

  # sqlite (what the round-trip specs above seed) never hands back a
  # Sequel::SQL::Blob; MariaDB does, for exactly the JSON-as-text columns
  # this class exists to carry, and it broke the very first real export.
  describe "value normalization" do
    def normalize(table, column, value)
      described_class.new.send(:normalize_value, table, column, value)
    end

    it "collapses a Sequel::SQL::Blob to a plain, YAML-safe String" do
      value = normalize(:communities, :settings, Sequel::SQL::Blob.new("{}"))
      expect(value.class).to eq(String)
      expect(value).to eq("{}")
    end

    it "raises for a blob that is not valid UTF-8" do
      bad = Sequel::SQL::Blob.new("\xFF\xFE".b)
      expect { normalize(:community_scripts, :compiled, bad) }
        .to raise_error(described_class::Invalid, /not valid UTF-8/)
    end

    it "stringifies a Time to ISO8601 so the emitter can carry it" do
      now = Time.now.utc
      expect(normalize(:communities, :created_at, now)).to eq(now.iso8601(6))
    end
  end

  describe "guards" do
    it "uses repeatable read and read-only mode for PostgreSQL exports" do
      db = Sequel.mock(host: "postgres")
      Rubotty::Storage::Transfer.with_consistent_read(db) { db[:message_map].all }
      expect(db.sqls).to include("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
    end

    it "sets MySQL repeatable read before starting the snapshot transaction" do
      db = Sequel.mock(host: "mysql")
      Rubotty::Storage::Transfer.with_consistent_read(db) { db[:message_map].all }
      sql = db.sqls
      expect(sql.index("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")).to be < sql.index("BEGIN")
      expect(sql).to include("SELECT * FROM `message_map`")
    end

    it "refuses nontransactional MySQL tables before beginning an export" do
      db = Sequel.mock(host: "mysql", fetch: { table_name: "message_map" })
      expect do
        Rubotty::Storage::Transfer.with_consistent_read(db) { raise "must not read" }
      end.to raise_error(Rubotty::StorageError, /InnoDB.*message_map/)
      expect(db.sqls).not_to include("BEGIN")
    end

    it "refuses a target carrying only an operator's deployment default" do
      seed_source(src)
      export
      target = Rubotty::Storage::Factory.build({ driver: :sqlite, path: dst })
      Rubotty::ControlPlane.migrate!(target.db)
      target.db[:feature_settings].where(community_id: nil).update(config: '{"acknowledge":false}')
      expect { import }.to raise_error(described_class::Invalid, /already has data/)
      expect(target.db[:feature_settings].get(:config)).to eq('{"acknowledge":false}')
    ensure
      target&.close
    end

    it "rolls back an invalid late row and permits a corrected immediate retry" do
      seed_source(src)
      export
      document = Zlib::GzipReader.open(snapshot_path) { |gz| YAMLCamel.load(gz.read) }
      valid = File.binread(snapshot_path)
      document["tables"]["message_map"].first["source_endpoint"] = nil
      Zlib::GzipWriter.open(snapshot_path) { |gz| gz.write(YAMLCamel.dump(document)) }
      expect { import }.to raise_error(Sequel::NotNullConstraintViolation)
      target = Rubotty::Storage::Factory.build({ driver: :sqlite, path: dst })
      expect(target.db[:communities].count).to eq(0)
      expect(target.db[:feature_settings].count).to eq(1)
      File.binwrite(snapshot_path, valid)
      expect { import }.not_to raise_error
      expect(target.db[:communities].count).to eq(1)
    ensure
      target&.close
    end

    it "validates the table shape before migrating or writing a target" do
      document = { "format" => described_class::FORMAT, "version" => 1, "tables" => { "communities" => "bad" } }
      Zlib::GzipWriter.open(snapshot_path) { |gz| gz.write(YAMLCamel.dump(document)) }
      expect { import }.to raise_error(described_class::Invalid, /rows/)
      db = Sequel.sqlite(dst)
      expect(db.tables).to be_empty
    ensure
      db&.disconnect
    end

    it "refuses to reuse an existing transaction whose snapshot isolation is unknown" do
      db = Sequel.sqlite
      expect do
        db.transaction { described_class.document_bytes(db) }
      end.to raise_error(Rubotty::StorageError, /own read transaction/)
    ensure
      db&.disconnect
    end

    it "refuses to import into a datastore that already has data" do
      seed_source(src)
      export
      seed_source(dst)

      expect { import }.to raise_error(described_class::Invalid, /already has data/)
    end

    it "refuses a file that is not gzip" do
      File.write(snapshot_path, "not gzip")

      expect { import }.to raise_error(described_class::Invalid, /not a gzip file/)
    end

    it "refuses a gzip file that is not a rubotty snapshot" do
      Zlib::GzipWriter.open(snapshot_path) { |gz| gz.write(YAMLCamel.dump({ "hello" => "world" })) }

      expect { import }.to raise_error(described_class::Invalid, /not a rubotty datastore snapshot/)
    end

    it "refuses a snapshot newer than this rubotty understands" do
      seed_source(src)
      export
      document = Zlib::GzipReader.open(snapshot_path) { |gz| YAMLCamel.load(gz.read) }
      document["version"] = described_class::VERSION + 1
      Zlib::GzipWriter.open(snapshot_path) { |gz| gz.write(YAMLCamel.dump(document)) }

      expect { import }.to raise_error(described_class::Invalid, /newer than this rubotty understands/)
    end

    it "refuses a missing file" do
      expect { import }.to raise_error(described_class::Invalid, /no snapshot at/)
    end
  end
end
