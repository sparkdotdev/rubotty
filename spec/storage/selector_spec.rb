# frozen_string_literal: true

require "spec_helper"

# The env-driven backend selection. LIVE_DB_TYPE and the per-backend connection
# vars take precedence over the YAML storage: block; unset, the YAML block is
# returned unchanged so an existing deploy is byte-for-byte the same.
RSpec.describe Rubotty::Storage::Selector do
  let(:yaml) { { driver: :sqlite, path: "data/message_map.sqlite3" } }

  describe ".live_config" do
    it "returns the YAML block unchanged when LIVE_DB_TYPE is unset" do
      expect(described_class.live_config(yaml, env: {})).to eq(yaml)
    end

    it "treats a blank LIVE_DB_TYPE as unset, so an empty variable does not break a deploy" do
      expect(described_class.live_config(yaml, env: { "LIVE_DB_TYPE" => "  " })).to eq(yaml)
    end

    it "takes precedence over the YAML block when LIVE_DB_TYPE is set" do
      env = { "LIVE_DB_TYPE" => "pgsql" }
      expect(described_class.live_config(yaml, env: env)).to eq(driver: :pg, url_env: "PGSQL_DATABASE_URL")
    end
  end

  describe ".config_for" do
    it "maps pgsql to the pg driver reading PGSQL_DATABASE_URL" do
      expect(described_class.config_for("pgsql", env: {})).to eq(driver: :pg, url_env: "PGSQL_DATABASE_URL")
    end

    it "maps mdb to the mdb driver reading MDB_DATABASE_URL" do
      expect(described_class.config_for("mdb", env: {})).to eq(driver: :mdb, url_env: "MDB_DATABASE_URL")
    end

    it "maps sqlite to the file named by SQLITE_FILENAME" do
      expect(described_class.config_for("sqlite", env: { "SQLITE_FILENAME" => "/data/x.sqlite3" }))
        .to eq(driver: :sqlite, path: "/data/x.sqlite3")
    end

    it "falls back to the default sqlite path when SQLITE_FILENAME is unset" do
      expect(described_class.config_for("sqlite", env: {})).to eq(driver: :sqlite)
    end

    it "maps pstore to the file named by PSTORE_FILENAME" do
      expect(described_class.config_for("pstore", env: { "PSTORE_FILENAME" => "/data/x.pstore" }))
        .to eq(driver: :pstore, path: "/data/x.pstore")
    end

    it "maps memory to the memory driver" do
      expect(described_class.config_for("memory", env: {})).to eq(driver: :memory)
    end

    it "is case and whitespace insensitive" do
      expect(described_class.config_for("  PgSql  ", env: {})).to eq(driver: :pg, url_env: "PGSQL_DATABASE_URL")
    end

    it "names the variable and the valid set when the token is unknown" do
      expect { described_class.config_for("mongo", env: {}, var: "LIVE_DB_TYPE") }
        .to raise_error(Rubotty::ConfigError, /LIVE_DB_TYPE.*mongo.*pgsql, mdb, sqlite, pstore, memory/m)
    end
  end

  describe ".build_live" do
    it "builds the env-selected backend, not the YAML one" do
      tmp = Dir.mktmpdir("rubotty-selector")
      path = File.join(tmp, "env.sqlite3")
      store = described_class.build_live(yaml, env: { "LIVE_DB_TYPE" => "sqlite", "SQLITE_FILENAME" => path })
      expect(store).to be_a(Rubotty::Storage::SequelStore)
      expect(store.describe).to include(path)
      store.close
      FileUtils.remove_entry(tmp)
    end

    it "builds the YAML backend when the env layer is silent" do
      store = described_class.build_live({ driver: :memory }, env: {})
      expect(store).to be_a(Rubotty::Storage::Memory)
    end
  end
end
