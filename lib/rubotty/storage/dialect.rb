# frozen_string_literal: true

require "sequel"
require "zlib"
require "digest"

module Rubotty
  module Storage
    # The thin per-dialect seam. Sequel already provides one shared layer
    # across SQLite, PostgreSQL and MariaDB; this class holds only the
    # handful of places that abstraction leaks (the upsert syntax, partial
    # indexes, TEXT column defaults, the migration lock), so nothing else in
    # the codebase has to branch on the backend. JSON-stored-as-TEXT needs no
    # seam: every backend stores it as TEXT and the model layer
    # (de)serialises in Ruby, so it already reads and writes identically on
    # all three dialects.
    class Dialect
      # The dialect for an already-connected database.
      def self.for(db)
        klass = case db.database_type
                when :postgres then Pgsql
                when :mysql then Mysql
                when :sqlite then Sqlite
                else self
                end
        klass.new(db)
      end

      # utf8mb4 with a binary collation, so that every CREATE TABLE names the same
      # character set regardless of the server or database default. utf8mb4 is
      # required to store emoji (the reaction column) at all, and the binary
      # collation makes string comparison byte-for-byte, matching SQLite (BINARY)
      # and Postgres, so a unique key that separates two values on those backends
      # separates them here too rather than folding case.
      MYSQL_CHARSET = "utf8mb4"
      MYSQL_COLLATE = "utf8mb4_bin"

      # One lock, shared by every process that might migrate this database, so a
      # bot and a rubotty-web instance racing the same deploy contend for the
      # same name rather than two unrelated locks that would not serialize
      # anything.
      MIGRATION_LOCK_NAME = "rubotty_migrate"

      # How long a caller waits for the lock before giving up: generous on
      # purpose, since a real migration run takes seconds rather than
      # minutes, so this is sized for "another deploy is genuinely ahead of
      # me." {#migration_lock!} raises rather than letting a caller proceed
      # unlocked once this elapses.
      MIGRATION_LOCK_TIMEOUT = 60

      # How often {Pgsql#migration_lock!} retries pg_try_advisory_lock while
      # waiting. Postgres has no "block up to N seconds" advisory lock call, so
      # the timeout above is enforced by polling at this interval instead.
      LOCK_POLL_INTERVAL = 0.5

      # How long a caller of {#with_advisory_lock} waits before giving up.
      # Deliberately much shorter than {MIGRATION_LOCK_TIMEOUT}: the Telegram
      # poller, the durable scheduler and the control-plane watcher all call
      # this from a loop, so a caller that cannot get the lock should find
      # that out quickly and let its own retry cadence take over instead of
      # blocking the loop.
      APP_LOCK_TIMEOUT = 5

      # Prepare a freshly connected MySQL/MariaDB database (a no-op
      # elsewhere). Called by {Factory} before any migration runs, so the
      # CREATE TABLE charset/collation and the TEXT-default extension
      # ({MysqlTextDefaults}) apply to every table the migrations create.
      def self.prepare(db)
        return db unless db.database_type == :mysql

        db.default_charset = MYSQL_CHARSET
        db.default_collate = MYSQL_COLLATE
        db.extend(MysqlTextDefaults)
        db
      end

      def initialize(db)
        @db = db
      end

      attr_reader :db

      # Whether this backend enforces a WHERE clause on an index (a partial
      # index). True on SQLite and Postgres; false on MySQL/MariaDB.
      def partial_indexes? = true

      # The column type for text that has to hold more than 64 KB, or nil
      # where the ordinary TEXT column already does: nil on SQLite and
      # Postgres, whose text columns are unbounded. MySQL and MariaDB cap
      # TEXT at 65,535 bytes, under the ceiling the script store puts on a
      # data file, so there the type has to be named.
      def long_text = nil

      # Acquire the cross-process migration advisory lock, blocking up to
      # +timeout+ seconds. Raises StorageError rather than returning when
      # the lock cannot be had, so a caller can never mistake "I gave up
      # waiting" for "I hold the lock"; every dialect below (including the
      # SQLite no-op) overrides this base raise.
      #
      # @return [true]
      def migration_lock!(name: MIGRATION_LOCK_NAME, timeout: MIGRATION_LOCK_TIMEOUT)
        raise NotImplementedError, "#{self.class} must implement #migration_lock!"
      end

      # Release a lock taken by {#migration_lock!}. Called from the caller's
      # ensure block, so this must not raise on a lock that, for whatever
      # reason, is not held.
      #
      # @param name [String] the same name passed to {#migration_lock!}
      # @return [void]
      def migration_unlock!(name: MIGRATION_LOCK_NAME)
        raise NotImplementedError, "#{self.class} must implement #migration_unlock!"
      end

      # The generalized named app lock: the same primitive {#migration_lock!}
      # uses, but reusable for any caller that needs a cross-process mutual
      # exclusion window, releasing even when +block+ raises. Unlike
      # {#migration_lock!}, this never blocks unboundedly and raises
      # {LockUnavailable} (a StorageError subclass) on a timeout.
      #
      # @yield runs while the lock is held
      # @raise [LockUnavailable] the lock was not free within +timeout+
      def with_advisory_lock(name, timeout: APP_LOCK_TIMEOUT)
        raise NotImplementedError, "#{self.class} must implement #with_advisory_lock"
      end

      # Build the upsert dataset for +dataset+: on a conflict against the
      # unique key +target+, overwrite each column in +update+ with the
      # value the insert proposed, returning a dataset ready for #insert.
      # The base spelling is the Postgres/SQLite one (ON CONFLICT DO
      # UPDATE); {Mysql} overrides it.
      #
      # @return [Sequel::Dataset]
      def upsert(dataset, target:, update:)
        dataset.insert_conflict(target: target, update: excluded_map(update))
      end

      private

      def excluded_map(columns)
        columns.to_h { |column| [column, Sequel[:excluded][column]] }
      end

      # Postgres shares the base ON CONFLICT spelling verbatim; only the lock
      # methods diverge here.
      class Pgsql < Dialect
        # pg_advisory_lock takes a bigint, not a name, and there is no built in
        # timeout, so this polls pg_try_advisory_lock rather than blocking on
        # pg_advisory_lock directly. Every process hashes the same constant
        # +name+ to the same key with {#lock_key}, which is all two processes
        # need to agree they are contending for the same lock.
        def migration_lock!(name: MIGRATION_LOCK_NAME, timeout: MIGRATION_LOCK_TIMEOUT)
          key = lock_key(name)
          deadline = Time.now + timeout
          loop do
            return true if db.get(Sequel.function(:pg_try_advisory_lock, key))
            if Time.now >= deadline
              raise StorageError,
                    "timed out after #{timeout}s waiting for the migration lock " \
                    "(pg_advisory_lock #{key}, name #{name.inspect}); " \
                    "another process is migrating and never finished"
            end
            sleep(LOCK_POLL_INTERVAL)
          end
        end

        def migration_unlock!(name: MIGRATION_LOCK_NAME)
          db.get(Sequel.function(:pg_advisory_unlock, lock_key(name)))
        end

        # The generalized named app lock. db.synchronize checks out one
        # physical connection for the acquire, the guarded block and the
        # release, which pg_advisory_lock/pg_advisory_unlock require: they
        # are scoped to the connection that took them rather than to the
        # session or the transaction, so acquiring on one pooled connection
        # and running the block on another would silently serialize nothing.
        def with_advisory_lock(name, timeout: APP_LOCK_TIMEOUT)
          key = lock_key(name)
          db.synchronize do
            unless try_pg_advisory_lock(key, timeout: timeout)
              raise LockUnavailable,
                    "timed out after #{timeout}s waiting for the #{name.inspect} lock " \
                    "(pg_advisory_lock #{key}); another process already holds it"
            end

            begin
              yield
            ensure
              db.get(Sequel.function(:pg_advisory_unlock, key))
            end
          end
        end

        private

        # A stable 32 bit key from the lock name. pg_advisory_lock takes a
        # bigint (up to 63 usable bits); crc32 comfortably fits and is stable
        # across Ruby versions and processes, which is all that matters since
        # nothing outside this method ever needs to invert it.
        def lock_key(name)
          Zlib.crc32(name)
        end

        # Polls pg_try_advisory_lock rather than blocking on pg_advisory_lock
        # directly, for the same reason {#migration_lock!} does: Postgres has
        # no "block up to N seconds" advisory lock call.
        def try_pg_advisory_lock(key, timeout:)
          deadline = Time.now + timeout
          loop do
            return true if db.get(Sequel.function(:pg_try_advisory_lock, key))
            return false if Time.now >= deadline

            sleep(LOCK_POLL_INTERVAL)
          end
        end
      end

      # SQLite allows exactly one writer at a time, so two rubotty processes
      # cannot interleave DDL the way MariaDB's auto-committing DDL lets
      # them: a second process migrating concurrently just blocks on
      # SQLite's own write lock, then finds the migrations already applied.
      # This is a documented no-op rather than the base class's raise, so a
      # SQLite deploy (development, or any single-writer production use)
      # does not fail on a NotImplementedError it does not need.
      class Sqlite < Dialect
        def migration_lock!(name: MIGRATION_LOCK_NAME, timeout: MIGRATION_LOCK_TIMEOUT) = true

        def migration_unlock!(name: MIGRATION_LOCK_NAME) = nil

        # File-backed databases share OS locks without holding a database
        # transaction through the caller's work. Memory databases use the local
        # mutex table. Persistent lock files must never be unlinked while any
        # database user is running; see docs/sqlite-locks.md for maintenance.
        def with_advisory_lock(name, timeout: APP_LOCK_TIMEOUT)
          directory = lock_directory
          return with_local_lock(name, timeout: timeout) { yield } if directory.nil?

          lock = open_lock_file(directory, name)
          begin
            acquire_before(name, timeout: timeout) { try_file_lock(lock) }
            yield
          ensure
            lock.close
          end
        end

        private

        def with_local_lock(name, timeout:)
          mutex = LOCKS_ACCESS.synchronize { (LOCKS[name.to_s] ||= Mutex.new) }
          acquire_before(name, timeout: timeout) { mutex.try_lock }
          begin
            yield
          ensure
            mutex.unlock
          end
        end

        def acquire_before(name, timeout:)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
          loop do
            return if yield

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              raise LockUnavailable,
                    "timed out after #{timeout}s waiting for the #{name.inspect} lock"
            end
            sleep([remaining, 0.02].min)
          end
        end

        def lock_directory
          unless instance_variable_defined?(:@lock_directory)
            main = db.fetch("PRAGMA database_list").all.find { |row| row[:name] == "main" }
            file = main&.fetch(:file, nil).to_s
            @lock_directory = file.empty? ? nil : "#{File.realpath(file)}.rubotty-locks"
          end
          return nil if @lock_directory.nil?

          begin
            Dir.mkdir(@lock_directory, 0o700)
          rescue Errno::EEXIST
            nil
          end
          stat = File.lstat(@lock_directory)
          unless stat.directory? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o700
            raise StorageError, "the SQLite lock directory must be private and owned by the current user"
          end
          @lock_directory
        rescue SystemCallError, IOError, Sequel::Error => e
          raise StorageError, "could not prepare the SQLite lock directory: #{e.message}"
        end

        def open_lock_file(directory, name)
          path = File.join(directory, "#{Digest::SHA256.hexdigest(name.to_s)}.lock")
          lock = File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
          lock.close_on_exec = true
          validate_lock_file(lock)
          lock
        rescue SystemCallError, IOError => e
          lock&.close
          raise StorageError, "could not open a SQLite lock file: #{e.message}"
        rescue Exception
          lock&.close
          raise
        end

        def try_file_lock(lock)
          lock.flock(File::LOCK_EX | File::LOCK_NB)
        rescue SystemCallError, IOError => e
          raise StorageError, "could not acquire a SQLite file lock: #{e.message}"
        end

        def validate_lock_file(lock)
          stat = lock.stat
          unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o600 && stat.nlink == 1
            raise StorageError, "SQLite lock files must be private, singly linked files owned by the current user"
          end
        end

        # The process-wide named lock table {#with_advisory_lock} contends on,
        # and the mutex guarding access to it (as distinct from the named
        # locks themselves).
        LOCKS = {}
        LOCKS_ACCESS = Mutex.new
        private_constant :LOCKS, :LOCKS_ACCESS
      end

      # MariaDB / MySQL.
      class Mysql < Dialect
        # MySQL/MariaDB have no partial (WHERE) indexes.
        def partial_indexes? = false

        # TEXT is 65,535 bytes here. MEDIUMTEXT is 16 MB, which is past every
        # cap the application puts on the columns that need it.
        def long_text = "mediumtext"

        # ON DUPLICATE KEY UPDATE col=VALUES(col), ... . MySQL ignores an explicit
        # conflict target (it fires on whichever unique key the row collides with,
        # and every call site here has exactly one candidate unique key), so
        # +target+ is accepted for a uniform signature but not emitted.
        def upsert(dataset, target:, update:)
          dataset.on_duplicate_key_update(*update)
        end

        # GET_LOCK(name, timeout) blocks server side for up to +timeout+ seconds
        # and returns 1 (acquired), 0 (timed out) or NULL (error, e.g. killed
        # while waiting). Anything other than 1 means this caller does not hold
        # the lock, so it must raise rather than let the migration run.
        def migration_lock!(name: MIGRATION_LOCK_NAME, timeout: MIGRATION_LOCK_TIMEOUT)
          result = db.get(Sequel.function(:get_lock, name, timeout))
          return true if result == 1 || result == true

          raise StorageError,
                "could not acquire the migration lock (GET_LOCK #{name.inspect} " \
                "returned #{result.inspect}, wanted 1); another process is " \
                "migrating and either never finished or the lock call errored"
        end

        # RELEASE_LOCK(name) returns 1 (released), 0 (held by someone else) or
        # NULL (was not held). Nothing to do with the result: the ensure block
        # calling this only ever runs after a successful {#migration_lock!} on
        # the same connection, so 0/NULL here would mean the connection itself
        # changed underneath us, which there is no sane recovery from anyway.
        def migration_unlock!(name: MIGRATION_LOCK_NAME)
          db.get(Sequel.function(:release_lock, name))
        end

        # The generalized named app lock. See {Pgsql#with_advisory_lock} for
        # why db.synchronize matters: GET_LOCK/RELEASE_LOCK are per-connection
        # too, so the acquire, the guarded block and the release all have to
        # share the same one.
        def with_advisory_lock(name, timeout: APP_LOCK_TIMEOUT)
          db.synchronize do
            result = db.get(Sequel.function(:get_lock, name, timeout))
            unless result == 1 || result == true
              raise LockUnavailable,
                    "timed out waiting for the #{name.inspect} lock (GET_LOCK returned " \
                    "#{result.inspect}); another process already holds it"
            end

            begin
              yield
            ensure
              db.get(Sequel.function(:release_lock, name))
            end
          end
        end
      end
    end

    # Restores TEXT column defaults on MariaDB. Sequel's shared MySQL adapter
    # strips :default off a generic TEXT column unconditionally, since MySQL
    # forbade TEXT/BLOB defaults until 8.0.13; MariaDB has allowed them since
    # 10.2.1, and the control plane depends on one (channels,
    # communities.settings, operators.actions and other TEXT-stored JSON all
    # expect the "{}" default), so without this a fresh MariaDB would reject
    # those inserts or store "" and later fail JSON.parse. Only the exact
    # leaking column is regenerated; everything else falls through untouched.
    module MysqlTextDefaults
      # The generic Sequel::Database column builder, captured once. Calling it
      # instead of `super` deliberately bypasses the MySQL adapter's override (the
      # one that strips the default) while still dispatching every sub-fragment
      # (type, null, default) back through the MySQL overrides via +self+.
      GENERIC_COLUMN_DEFINITION_SQL = Sequel::Database.instance_method(:column_definition_sql)

      def column_definition_sql(column)
        return super unless keep_text_default?(column)

        GENERIC_COLUMN_DEFINITION_SQL.bind_call(self, column)
      end

      private

      def keep_text_default?(column)
        column[:type] == String && column[:text] == true &&
          column.key?(:default) && text_column_defaults_supported?
      end

      # MariaDB 10.2.1+ and MySQL 8.0.13+ accept a literal DEFAULT on TEXT/BLOB.
      def text_column_defaults_supported?
        mariadb? ? server_version >= 100201 : server_version >= 80013
      end
    end
  end
end
