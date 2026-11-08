# frozen_string_literal: true

require "sequel"
require "json"
require "time"

module Rubotty
  module Storage
    # Copies the whole datastore from one Sequel backend to another, in
    # either direction, so an operator can graduate from single-file SQLite
    # to a shared PostgreSQL without losing state. A plain row copy is
    # enough because portability is already an invariant of every table
    # (JSON stored as TEXT, no Postgres-only column type). The source is
    # only ever read (auto_migrate off, never written); the copy is
    # idempotent and resumable, keeping original primary keys and accepting
    # an existing row only when its source values match.
    class Transfer
      # The versioned control-plane tables, in foreign-key-safe insertion
      # order: a table never appears before one it references, communities
      # is the root, and a new table goes after everything it points at.
      # rehosted_files, rehosted_upload_tickets and guest_uploads carry only
      # metadata, since the bytes live in Storage::ObjectStore on disk, so
      # copy that directory too or the rows will name objects nothing can
      # find.
      CONTROL_PLANE_TABLES = %i[
        communities
        platform_connections
        channels
        rooms
        room_channels
        people
        person_identities
        operators
        operator_requests
        feature_settings
        observed_identities
        observed_identity_names
        bridged_nicknames
        bridged_nickname_history
        ephemeral_messages
        scheduled_jobs
        warnings
        active_sanctions
        audit_events
        content_policy_actions
        content_policy_misfires
        content_policy_reposts
        content_policy_revisions
        topic_move_proposals
        undelivered_dms
        warning_announcements
        member_reports
        guest_invites
        guest_messages
        guest_uploads
        irc_networks
        fluxer_instances
        events
        event_rsvps
        event_cards
        polls
        poll_options
        poll_votes
        poll_cards
        pending_spaces
        backfill_proposals
        backfill_proposal_items
        dashboard_action_permissions
        dashboard_appearances
        dashboard_viewers
        dashboard_viewer_requests
        dashboard_administrators
        community_viewers
        community_viewer_requests
        auth_tokens
        auth_token_redemptions
        keyword_watches
        accounts
        api_keys
        api_request_log
        community_scripts
        script_runs
        script_endpoints
        script_memos
        script_ledgers
        script_stats
        model_call_stats
        script_sessions
        script_rounds
        api_pending_messages
        api_pending_message_actions
        live_room_messages
        room_summary_messages
        room_summary_watermarks
        room_summary_pins
        bot_messages
        redirections
        redirection_window_messages
        alerts
        relay_fingerprints
        rehosted_files
        rehosted_upload_tickets
        webhook_subscriptions
        webhook_deliveries
        integrations
        api_wrapper_pending_events
      ].freeze

      # The ad-hoc message-map tables (Storage::Schema). Foreign-key-free derived
      # state, so their order among themselves does not matter.
      MESSAGE_MAP_TABLES = %i[message_map reaction_state bridge_state relay_claims multipost_fingerprints].freeze

      # Every table the tool copies, in the order it copies them.
      TABLES = (CONTROL_PLANE_TABLES + MESSAGE_MAP_TABLES).freeze

      # Rows per multi-row INSERT.
      BATCH = 1_000

      # Whether +table+ holds a row worth calling data, shared by every
      # caller deciding if a target datastore is really empty
      # (Storage::Snapshot's import guard, Storage::BootImport's boot-time
      # check). Only the untouched moderation row seeded by a fresh migration
      # is excluded; customized deployment defaults are real data too.
      def self.occupied?(db, table)
        return false unless db.table_exists?(table)

        return db[table].any? unless table.to_s == "feature_settings"

        db[table].any? { |row| !seeded_feature_setting?(row) }
      end

      # Only the untouched migration seed is disposable. A global setting is
      # otherwise operator data, even when no community has been created yet.
      def self.seeded_feature_setting?(row)
        row[:community_id].nil? && row[:room_id].nil? && row[:feature] == "moderation" &&
          [true, 1].include?(row[:enabled]) && row[:created_at] == row[:updated_at] &&
          JSON.parse(row[:config].to_s) == {
            "ack_ttl_seconds" => Core::CommandAck::DEFAULT_TTL_SECONDS, "acknowledge" => true
          }
      rescue JSON::ParserError
        false
      end

      def self.remove_seeded_settings(db)
        db[:feature_settings].where(community_id: nil).each do |row|
          db[:feature_settings].where(row).delete if seeded_feature_setting?(row)
        end
      end

      # A single consistent read covers both schema regimes. A nested ordinary
      # transaction cannot be upgraded to repeatable read, so refuse it.
      def self.with_consistent_read(db, &block)
        raise StorageError, "a datastore snapshot needs its own read transaction" if db.in_transaction?

        options = case db.database_type
                  when :sqlite then { mode: :deferred }
                  when :postgres then { isolation: :repeatable, read_only: true }
                  when :mysql then { isolation: :repeatable }
                  else raise StorageError, "unsupported datastore snapshot backend #{db.database_type}"
                  end
        require_transactional_tables(db)
        db.transaction(**options, &block)
      end

      def self.with_data_write(db, &block)
        raise StorageError, "a datastore restore needs its own write transaction" if db.in_transaction?

        require_transactional_tables(db)
        Dialect.for(db).with_advisory_lock("rubotty:datastore:write") do
          options = db.database_type == :sqlite ? { mode: :immediate } : {}
          db.transaction(**options, &block)
        end
      end

      # MyISAM and similar tables ignore rollback and consistent snapshots.
      # Refuse those existing schemas instead of claiming atomic restoration.
      def self.require_transactional_tables(db)
        return unless db.database_type == :mysql

        unsafe = db[Sequel[:information_schema][:tables]]
                 .where(table_schema: Sequel.function(:database), table_name: TABLES.map(&:to_s))
                 .where(Sequel.|({ engine: nil }, Sequel.~(engine: "InnoDB"))).select_map(:table_name)
        return if unsafe.empty?

        raise StorageError, "datastore snapshots require InnoDB tables: #{unsafe.join(', ')}"
      end

      # The outcome of a run: one entry per table plus credential-free labels for
      # the two ends, so the CLI can report and pick an exit code.
      Report = Struct.new(:rows, :dry_run, :source_label, :target_label, keyword_init: true) do
        # Every table's source count equalled its target count.
        def ok? = rows.all? { |row| row[:ok] }

        def mismatches = rows.reject { |row| row[:ok] }

        def total_source = rows.sum { |row| row[:source] }

        def total_target = rows.sum { |row| row[:target] }
      end

      # Turn a compact datastore spec ("sqlite:<path>", "pg:<env-var-name>")
      # into a storage config hash the same shape Storage::Factory.build and the
      # `storage:` config block accept.
      #
      # A bare env var name after `pg:` keeps credentials out of the shell
      # history and the process table, so prefer it to an inline URL.
      #
      # @return [Hash]
      def self.storage_config(spec)
        text = spec.to_s.strip
        if text.empty?
          raise ConfigError,
                ["a datastore spec is required, for example sqlite:data/message_map.sqlite3 " \
                 "or pg:DATABASE_URL"]
        end
        return { driver: :pg, url: text } if text.match?(%r{\Apostgres(?:ql)?://})
        return { driver: :memory } if text == "memory"

        match = text.match(/\A(?<driver>[a-z0-9_]+):(?<rest>.*)\z/mi)
        unless match
          raise ConfigError,
                ["cannot read #{spec.inspect} as a datastore spec. Use sqlite:<path>, " \
                 "pg:<env-var-name>, pg:<postgres:// url>, or a bare postgres:// url."]
        end

        driver = match[:driver].downcase.to_sym
        rest = match[:rest]
        case driver
        when :sqlite then { driver: :sqlite, path: rest }
        when :pstore then { driver: :pstore, path: rest }
        when :memory then { driver: :memory }
        when :pg, :postgres
          rest.match?(%r{\Apostgres(?:ql)?://}) ? { driver: :pg, url: rest } : { driver: :pg, url_env: rest }
        when :mdb, :mariadb, :mysql
          rest.match?(%r{\A(?:mariadb|mysql2?)://}) ? { driver: :mdb, url: rest } : { driver: :mdb, url_env: rest }
        else
          raise ConfigError, ["unknown storage driver #{driver.inspect} in datastore spec #{spec.inspect}"]
        end
      end

      # A one-line label that never prints a raw pg URL, so a connection string
      # with a password in it stays out of the report.
      #
      # @param config [Hash]
      # @return [String]
      def self.safe_label(config)
        case config[:driver]
        when :sqlite then "sqlite:#{config[:path] || Factory::DEFAULT_SQLITE_PATH}"
        when :pstore then "pstore:#{config[:path] || Factory::DEFAULT_PSTORE_PATH}"
        when :pg then config[:url_env] ? "pg (env #{config[:url_env]})" : "pg (url)"
        when :mdb, :mariadb, :mysql then config[:url_env] ? "mdb (env #{config[:url_env]})" : "mdb (url)"
        when :memory then "memory"
        else config[:driver].to_s
        end
      end

      # @param source [Hash] storage config for the store to copy FROM (read only)
      # @param target [Hash] storage config for the store to copy TO
      # @param env [Hash] environment, for pg url_env resolution
      # @param logger [#info, nil]
      # @param dry_run [Boolean] when true, only report source counts; write nothing
      def initialize(source:, target:, env: ENV, logger: nil, dry_run: false)
        @source_config = source
        @target_config = target
        @env = env
        @logger = logger
        @dry_run = dry_run
      end

      # Run the migration (or, in dry-run mode, only measure the source).
      #
      # @return [Report]
      def run
        guard_distinct_endpoints

        # Schema untouched: the store being left behind is never migrated.
        @source = build(@source_config, auto_migrate: false)
        @source_db = require_db(@source, role: "source")

        return dry_run_report if @dry_run

        @target = build(@target_config, auto_migrate: false)
        @target_db = require_db(@target, role: "target")

        ensure_target_schema
        rows = self.class.with_consistent_read(@source_db) do
          self.class.with_data_write(@target_db) do
            self.class.remove_seeded_settings(@target_db)
            copied = TABLES.map { |table| migrate_table(table) }
            unless copied.all? { |row| row[:ok] }
              raise StorageError, "datastore transfer has different source and target row counts"
            end
            reset_target_sequences if @target_db.database_type == :postgres
            copied
          end
        end

        Report.new(rows: rows, dry_run: false, source_label: safe_label(@source_config),
                   target_label: safe_label(@target_config))
      ensure
        @source&.close
        @target&.close
      end

      private

      def safe_label(config) = self.class.safe_label(config)

      # Copying a datastore onto itself would otherwise "succeed": every row
      # conflicts with itself and is ignored.
      def guard_distinct_endpoints
        return unless @source_config == @target_config

        raise ConfigError,
              ["the source and target datastores are the same (#{safe_label(@source_config)}); " \
               "point --from and --to at different stores."]
      end

      def build(config, auto_migrate:)
        Storage::Factory.build(config.merge(auto_migrate: auto_migrate), env: @env, logger: @logger)
      end

      def require_db(store, role:)
        db = ControlPlane::Boot.db_of(store)
        return db if db.is_a?(Sequel::Database)

        raise StorageError,
              "the #{role} store (#{store.describe}) is not Sequel-backed; " \
              "datastore migrate needs storage.driver sqlite, pg or mdb on both ends."
      end

      # Bring the target up to the schema a running bridge would. Both halves are
      # idempotent, so a target already carrying some of it is fine.
      def ensure_target_schema
        Storage::Schema.apply(@target_db)
        ControlPlane::Migrator.run(@target_db)
      end

      # Copy one table and return its verification row. Source count then target
      # count, so a mismatch is caught right here.
      def migrate_table(table)
        source_count = row_count(@source_db, table)
        copy_table(table)
        target_count = row_count(@target_db, table)
        { table: table, source: source_count, target: target_count, ok: source_count == target_count }
      end

      # Existing primary keys are resumable only if every source column agrees.
      # A natural-key conflict with a different id fails the ordinary INSERT.
      def copy_table(table)
        return unless @source_db.table_exists?(table)

        target = @target_db[table]
        primary_key = @source_db.schema(table).find { |_column, meta| meta[:primary_key] }&.first
        raise StorageError, "#{table} has no primary key for a resumable transfer" if primary_key.nil?

        source = @source_db[table].order(primary_key)
        source.enum_for(:paged_each, rows_per_fetch: BATCH, strategy: :filter).each_slice(BATCH) do |slice|
          held = target.where(primary_key => slice.map { |row| row.fetch(primary_key) })
                       .all.to_h { |row| [row.fetch(primary_key), row] }
          missing = slice.reject do |row|
            existing = held[row.fetch(primary_key)]
            next false if existing.nil?

            unless same_row?(row, existing)
              raise StorageError, "datastore transfer conflicts with an existing #{table} row"
            end
            true
          end
          target.multi_insert(missing) unless missing.empty?
          copied = target.where(primary_key => slice.map { |row| row.fetch(primary_key) })
                         .all.to_h { |row| [row.fetch(primary_key), row] }
          unless slice.all? { |row| same_row?(row, copied[row[primary_key]]) }
            raise StorageError, "datastore transfer could not preserve a #{table} row"
          end
        end
      rescue Sequel::ConstraintViolation
        raise StorageError, "datastore transfer conflicts with an existing #{table} row"
      end

      def same_row?(source, target)
        target && source.all? { |column, value| same_value?(value, target[column]) }
      end

      def same_value?(source, target)
        if source.is_a?(Time) || source.is_a?(DateTime)
          return false unless target.is_a?(Time) || target.is_a?(DateTime)

          # MariaDB's ordinary DATETIME stores whole seconds. Its schema has
          # always used that precision, so compare at the destination's limit.
          precision = @target_db.database_type == :mysql ? 0 : 6
          source.to_time.utc.iso8601(precision) == target.to_time.utc.iso8601(precision)
        else
          source.is_a?(String) && target.is_a?(String) ? source.b == target.b : source == target
        end
      end

      # Copying rows with explicit primary keys does not advance a PostgreSQL
      # sequence, so the bot's next insert would reuse id 1 and collide. SQLite's
      # AUTOINCREMENT tracks the max itself, hence pg only.
      def reset_target_sequences
        TABLES.each do |table|
          @target_db.reset_primary_key_sequence(table) if @target_db.table_exists?(table)
        end
      end

      def row_count(db, table)
        db.table_exists?(table) ? db[table].count : 0
      end

      def dry_run_report
        rows = TABLES.map do |table|
          count = row_count(@source_db, table)
          { table: table, source: count, target: nil, ok: true }
        end
        Report.new(rows: rows, dry_run: true, source_label: safe_label(@source_config),
                   target_label: safe_label(@target_config))
      end
    end
  end
end
