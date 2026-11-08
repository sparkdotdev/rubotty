# frozen_string_literal: true

require "spec_helper"

# The env-driven, one-boot datastore import, exercised sqlite to sqlite so it needs
# no server: the source token reads SQLITE_FILENAME while the live database is a
# distinct path, so the two ends differ and the copy runs. The transfer round-trip
# specs cover cross-server pairings; the orchestration and guards are proven here.
RSpec.describe Rubotty::Storage::BootImport do
  let(:tmp) { Dir.mktmpdir("rubotty-boot-import") }
  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  let(:src) { File.join(tmp, "src.sqlite3") }
  let(:dst) { File.join(tmp, "dst.sqlite3") }
  let(:target_config) { { driver: :sqlite, path: dst } }

  # Selects sqlite:src as the import source, the live database being the distinct
  # target_config, so source and target are different stores.
  def env(extra = {})
    { "LIVE_DB_IMPORT_FROM" => "sqlite", "SQLITE_FILENAME" => src }.merge(extra)
  end

  # A source datastore with one community and one message-map row, enough to prove
  # both regimes copy across.
  def seed(path, slug: "sample")
    store = Rubotty::Storage::Factory.build({ driver: :sqlite, path: path })
    Rubotty::ControlPlane::Migrator.run(store.db)
    now = Time.now
    store.db[:communities].insert(slug: slug, name: slug, status: "active", settings: "{}",
                                  created_at: now, updated_at: now)
    store.record(source: ref("tg", "1"), destination: ref("dc", "2"), room_id: "general")
    store.close
  end

  def community_slugs(path)
    db = Sequel.connect("sqlite://#{path}")
    db.table_exists?(:communities) ? db[:communities].select_map(:slug) : []
  ensure
    db&.disconnect
  end

  it "does nothing when LIVE_DB_IMPORT_FROM is unset" do
    expect(described_class.run(target_config: target_config, env: {})).to be_nil
    expect(File.exist?(dst)).to be(false)
  end

  it "skips, without copying, when the source names the live backend itself" do
    seed(src)
    same = { driver: :sqlite, path: src }
    expect(described_class.run(target_config: same, env: env)).to be_nil
  end

  it "copies every row into an empty live database" do
    seed(src)

    report = described_class.run(target_config: target_config, env: env)

    expect(report).to be_ok
    expect(community_slugs(dst)).to eq(["sample"])
    db = Sequel.connect("sqlite://#{dst}")
    expect(db[:message_map].count).to eq(1)
    db.disconnect
  end

  it "refuses to import over a live database that already holds data" do
    seed(src, slug: "from-source")
    seed(dst, slug: "already-here")

    expect(described_class.run(target_config: target_config, env: env)).to be_nil
    # The live database is untouched: still only its own community.
    expect(community_slugs(dst)).to eq(["already-here"])
  end

  it "refuses conflicting rows even when LIVE_DB_IMPORT_FORCE=1 bypasses the empty guard" do
    seed(src)
    seed(dst, slug: "already-here")

    expect do
      described_class.run(target_config: target_config, env: env("LIVE_DB_IMPORT_FORCE" => "1"))
    end.to raise_error(Rubotty::StorageError, /conflicts/)
    expect(community_slugs(dst)).to eq(["already-here"])
  end

  it "never modifies the source" do
    seed(src)
    before = community_slugs(src)

    described_class.run(target_config: target_config, env: env)

    expect(community_slugs(src)).to eq(before)
  end
end
