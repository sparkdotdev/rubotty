# frozen_string_literal: true

require "yamlcamel"
require "sequel"
require "time"

module Rubotty
  module Storage
    # Exports the whole datastore to a single gzipped YAML file, and imports one
    # back, so an operator can move a deployment to a new machine (or a new
    # storage engine) without both ends being reachable from the same process at
    # once, the way Transfer needs. Same table list and ordering as Transfer,
    # same portability invariant: every column is already engine-neutral (JSON as
    # TEXT, timestamps pinned to UTC), so a plain row dump round-trips cleanly.
    class Snapshot
      GZIP = YAMLCamel::IO::GzipCompression.new
      private_constant :GZIP
      FORMAT = "rubotty-datastore-snapshot"
      VERSION = 1

      TABLES = Transfer::TABLES

      # Rows per multi-row INSERT on import.
      BATCH = 1_000

      class Invalid < Rubotty::Error; end

      Report = Struct.new(:tables, :path, keyword_init: true) do
        def total = tables.sum { |row| row[:rows] }
      end

      def self.export(source:, path:, env: ENV, logger: nil)
        new(env: env, logger: logger).export(source: source, path: path)
      end

      def self.import(path:, target:, env: ENV, logger: nil)
        new(env: env, logger: logger).import(path: path, target: target)
      end

      # The gzipped YAML bytes for +db+, an ALREADY OPEN connection: the seam
      # a caller that holds its own live connection (the dashboard, mid
      # request) uses instead of #export, which opens a second one. No file
      # touched; the caller decides where the bytes go.
      def self.document_bytes(db, label: "live")
        new.document_bytes(db, label: label)
      end

      # The counterpart to .document_bytes: restores a snapshot's gzipped
      # bytes into +db+, an ALREADY OPEN connection, the seam the dashboard
      # import route uses instead of #import, which opens its own.
      def self.restore_bytes(db, bytes, source: "upload")
        new.restore_bytes(db, bytes, source: source)
      end

      def initialize(env: ENV, logger: nil)
        @env = env
        @logger = logger
      end

      # @param source [Hash] storage config for the store to read (read only)
      # @param path [String] where to write the .yaml.gz snapshot
      # @return [Report]
      def export(source:, path:)
        store = build(source, auto_migrate: false)
        db = require_db(store, role: "source")

        document, counts = build_document(db, label: Transfer.safe_label(source))
        YAMLCamel::Files.dump(path, document, compress: true)
        Report.new(tables: counts, path: path)
      ensure
        store&.close
      end

      # The gzipped bytes of a snapshot built from an already open connection.
      # See {.document_bytes}.
      def document_bytes(db, label: "live")
        document, = build_document(db, label: label)
        GZIP.compress(YAMLCamel.dump(document))
      end

      # @param path [String] a .yaml.gz snapshot written by #export
      # @param target [Hash] storage config for the store to write into. Must be
      #   empty: this restores a snapshot, it does not merge one into live data.
      # @return [Report]
      def import(path:, target:)
        document = read(path)
        store = build(target, auto_migrate: false)
        db = require_db(store, role: "target")
        report = restore_document(db, document)
        Report.new(tables: report.tables, path: path)
      ensure
        store&.close
      end

      # The counterpart to #document_bytes: restores +bytes+ (gzipped YAML,
      # as produced by #document_bytes or #export) into +db+, an already open
      # connection. See {.restore_bytes}.
      def restore_bytes(db, bytes, source: "upload")
        document = parse(decompress(bytes, source: source), source: source)
        restore_document(db, document)
      end

      private

      # @return [Array(Hash, Array<Hash>)] the document, and the same per-table
      #   counts #export's Report exposes, so both callers show identical numbers.
      def build_document(db, label:)
        Transfer.with_consistent_read(db) { read_document(db, label: label) }
      end

      def read_document(db, label:)
        tables = {}
        counts = TABLES.map do |table|
          rows = db.table_exists?(table) ? db[table].all.map { |row| normalize_row(table, row) } : []
          tables[table.to_s] = rows
          { table: table, rows: rows.length }
        end

        document = {
          "format" => FORMAT,
          "version" => VERSION,
          "exported_at" => Time.now.utc.iso8601,
          "source" => label,
          "tables" => tables
        }
        [document, counts]
      end

      # YAMLCamel's emitter only knows YAML 1.2.2's core schema (Hash, Array,
      # String, Integer, Float, true, false, nil), so every value leaving the
      # database needs to already be one of those. Two things Sequel hands
      # back never are: a real Time for every timestamp column, and (on
      # MariaDB specifically) a Sequel::SQL::Blob instead of a plain String
      # for several JSON-as-text columns. Both get collapsed here; #insert_rows
      # reverses the Time side using the target schema's own column types.
      def normalize_row(table, row)
        row.each_with_object({}) do |(column, value), out|
          out[column.to_s] = normalize_value(table, column, value)
        end
      end

      def normalize_value(table, column, value)
        case value
        when Time
          value.utc.iso8601(6)
        when Sequel::SQL::Blob
          text = String.new(value)
          text.force_encoding(Encoding::UTF_8)
          unless text.valid_encoding?
            raise Invalid,
                  "#{table}.#{column} holds bytes that are not valid UTF-8; datastore snapshots only " \
                  "support JSON-as-text columns today"
          end
          text
        else
          value
        end
      end

      def restore_document(db, document)
        validate_document(document)
        ensure_target_schema(db)
        Transfer.with_data_write(db) do
          guard_target_empty(db)
          Transfer.remove_seeded_settings(db)
          counts = TABLES.map do |table|
            rows = document.fetch("tables").fetch(table.to_s, [])
            insert_rows(db, table, rows)
            { table: table, rows: rows.length }
          end
          reset_target_sequences(db) if db.database_type == :postgres

          Report.new(tables: counts, path: nil)
        end
      end

      def validate_document(document)
        tables = document["tables"]
        unless tables.is_a?(Hash) && (tables.keys - TABLES.map(&:to_s)).empty?
          raise Invalid, "snapshot tables must name known datastore tables"
        end
        tables.each_value do |rows|
          unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row.keys.all? { |key| key.is_a?(String) } }
            raise Invalid, "each snapshot table must contain rows with named columns"
          end
        end
      end

      def read(path)
        raise Invalid, "no snapshot at #{path}" unless File.exist?(path)

        raw = decompress(File.binread(path), source: path)
        parse(raw, source: path)
      end

      def decompress(bytes, source:)
        GZIP.decompress(bytes)
      rescue YAMLCamel::CompressionError
        raise Invalid, "#{source} is not a gzip file"
      end

      def parse(raw, source:)
        document = YAMLCamel.load(raw)
        unless document.is_a?(Hash) && document["format"] == FORMAT
          raise Invalid, "#{source} is not a rubotty datastore snapshot"
        end
        if document["version"].to_i > VERSION
          raise Invalid, "#{source} is snapshot version #{document["version"]}, newer than this rubotty " \
                         "understands (#{VERSION}). Use a matching or newer rubotty to import it."
        end

        document
      rescue YAMLCamel::ParseError
        raise Invalid, "#{source} is not valid YAML"
      end

      def build(config, auto_migrate:)
        Storage::Factory.build(config.merge(auto_migrate: auto_migrate), env: @env, logger: @logger)
      end

      def require_db(store, role:)
        db = ControlPlane::Boot.db_of(store)
        return db if db.is_a?(Sequel::Database)

        raise StorageError,
              "the #{role} store (#{store.describe}) is not Sequel-backed; " \
              "datastore export/import needs storage.driver sqlite, pg or mdb."
      end

      def ensure_target_schema(db)
        Storage::Schema.apply(db)
        ControlPlane::Migrator.run(db)
      end

      # An import restores a snapshot; it is not a merge tool. Refusing a
      # non-empty target is cheap insurance against silently interleaving two
      # unrelated datasets under one set of primary keys.
      def guard_target_empty(db)
        occupied = TABLES.select { |table| Transfer.occupied?(db, table) }
        return if occupied.empty?

        raise Invalid,
              "the target datastore already has data in #{occupied.join(", ")}; " \
              "datastore import only writes into an empty datastore"
      end

      def insert_rows(db, table, rows)
        return if rows.empty?
        raise Invalid, "the target schema has no #{table} table" unless db.table_exists?(table)

        time_columns = datetime_columns(db, table)
        dataset = db[table]
        rows.each_slice(BATCH) do |slice|
          dataset.multi_insert(slice.map { |row| coerce_row(row, time_columns) })
        end
      end

      # The columns .normalize_value stringified from a real Time, so
      # #insert_rows knows which ones to parse back rather than hand the
      # database a bare ISO8601 string and hope its implicit cast agrees.
      def datetime_columns(db, table)
        db.schema(table).each_with_object([]) { |(name, meta), out| out << name if meta[:type] == :datetime }
      end

      def coerce_row(row, time_columns)
        row.each_with_object({}) do |(column, value), out|
          sym = column.to_sym
          out[sym] = time_columns.include?(sym) && value.is_a?(String) ? Time.iso8601(value) : value
        end
      end

      # Mirrors Transfer#reset_target_sequences: inserting rows with explicit
      # primary keys does not advance a PostgreSQL sequence.
      def reset_target_sequences(db)
        TABLES.each do |table|
          db.reset_primary_key_sequence(table) if db.table_exists?(table)
        end
      end
    end
  end
end
