# frozen_string_literal: true

require "yamlcamel"

module Rubotty
  module Scripting
    # What a script may remember between invocations, in one of two stores
    # chosen by ttl. The working store takes any table or scalar under a ttl,
    # scoped per (script, room) so one busy room can't spend an allowance the
    # others need. The kept store (ttl: "never") holds only whole numbers,
    # scoped to the whole community, and never expires: the whole-number rule
    # is a privacy design, since a store nothing expires from would otherwise
    # fill up with message content. A bucket and key name one value in
    # exactly one store; {#remember} refuses to write a name the other store already holds.
    class Memory
      # Per script, per room, not per community: a community-wide allowance
      # let one busy room exhaust it for every other room, breaking a rule
      # like "warn this person once a day" as soon as a community got busy.
      MAX_KEYS = 2_000

      # Four kilobytes, not one, because a table can go in here now and a hand
      # of cards or a ranked ballot written out as YAML does not fit in a
      # kilobyte. Still far short of a document: the cap keeps working state
      # working state.
      MAX_VALUE_BYTES = 4096

      MAX_KEY_LENGTH = 128

      # What a bucket may be called. No colon, deliberately: the working
      # store's scope is "s:<script id>" for a private memo and "b:<name>" for
      # a shared bucket, so a name that cannot contain a colon cannot resolve
      # to another script's private scope.
      BUCKET_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/i

      # The default working scope: private to one script, and unreachable by
      # name because no bucket may contain a colon.
      def self.private_scope(script) = "s:#{script.id}"

      # A named working bucket, shared by every script in the community within
      # one room: the room comes from the caller, never the script, so a
      # bucket is per room exactly as a private memo is. Returns nil for a
      # name this will not take; the caller reports that rather than this
      # raising.
      def self.bucket_scope(name)
        text = normalise_bucket(name)
        text.nil? ? nil : "b:#{text}"
      end

      # The bare bucket a kept total lives under. The kept store has no private
      # shape at all, so there is no prefix to disambiguate and nothing here can
      # be made to name a script's own memory.
      def self.normalise_bucket(name)
        text = name.to_s.strip
        text.match?(BUCKET_PATTERN) ? text.downcase : nil
      end

      # A month at the outside, a day when a script does not say. A script that
      # forgets to set one therefore leaks nothing much, and an abandoned key
      # ages out of reads immediately and off disk within a day of {PRUNE_KIND}'s
      # next scheduled sweep.
      MAX_TTL = 30 * 24 * 60 * 60
      DEFAULT_TTL = 24 * 60 * 60

      # The durable job kind that sweeps expired working-store memos, run once a
      # day. Each row already carries its own expiry from {#remember}, so this
      # needs no retention window of its own: {#sweep} only removes what
      # read-time cleanup would already refuse to hand back.
      PRUNE_KIND = "script_memory_sweep"
      PRUNE_INTERVAL = 24 * 60 * 60

      # The ttl that means the kept store. A word rather than a number, and a
      # number rather than nil, because "forever" and "you forgot to say" are
      # different intentions and only one of them should get no expiry.
      KEPT = "never"

      # Kept keys per community, across every bucket. Nothing expires here, so
      # this is the only bound there is, and it is refused at the write rather
      # than evicting something older: a total that quietly disappeared would be
      # worse than a script that can see the write failed.
      MAX_KEPT_KEYS = 5_000

      # How large a kept number may get, either direction. Comfortably inside
      # what an INTEGER column holds on every backend, so the cap and the column
      # agree instead of the column allowing more than this will take.
      MAX_KEPT_VALUE = 1_000_000_000

      # Rows one {#top} answers, and the ceiling on asking for more. A
      # leaderboard is read out loud into a room, so the default is what fits in
      # a message and the maximum is what fits in one frame.
      DEFAULT_TOP_LIMIT = 20
      MAX_TOP_LIMIT = 200

      # Same two numbers for {#keys}, which answers names rather than rows.
      DEFAULT_KEYS_LIMIT = 50
      MAX_KEYS_LIMIT = 500

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Keep +value+ under +key+, in whichever store the ttl asks for.
      # Answers rather than raising, for every refusal alike, so a script
      # reads `if not ok then` and never needs pcall, and cannot lose memory
      # it believes it has without a chance to notice.
      #
      # @return [true, Array(false, String)] true, or false and why not
      def remember(script, room_key, key:, value:, bucket: nil, ttl: nil)
        name = clean_key(key)
        return [false, key_refusal(key)] if name.nil?
        return keep(script, bucket, name, value) if kept?(ttl)

        scope = working_scope(script, bucket)
        return [false, bucket_refusal] if scope.nil?

        write_working(script, room_key, scope, name, value, ttl, bucket)
      end

      # What was kept under +key+, or nil: looks in the working store and then
      # the kept one. A name lives in at most one of them, since {#remember}
      # refuses to put it in both, so this never has to decide which answer wins.
      def recall(script, room_key, key:, bucket: nil)
        name = clean_key(key)
        return nil if name.nil?

        scope = working_scope(script, bucket)
        return nil if scope.nil?

        row = live(script, room_key, name, scope: scope, now: @clock.call)
        return decode(row.value) unless row.nil?

        clear_stale(script, room_key, name, scope: scope)
        kept_value(script, bucket, name)
      end

      # Drop a key from wherever it is, before its ttl runs out or, in the kept
      # store, at all. Answers whether anything was there.
      def forget(script, room_key, key:, bucket: nil)
        name = clean_key(key)
        return false if name.nil?

        scope = working_scope(script, bucket)
        return false if scope.nil?

        dropped = scoped(script, room_key, name, scope: scope).delete.to_i
        return true if dropped.positive?

        kept_rows(script, bucket, name).delete.to_i.positive?
      end

      # Add +by+ to a kept total and answer what it is now, added in the
      # database rather than read-then-written in Ruby so two rules crediting
      # the same total at once can't each read the same value and lose one.
      # The bounds live in the WHERE clause too, so a concurrent add can't
      # slip between a check and the update and carry a balance past its floor.
      #
      # @return [Integer, Array(false, String)] the new total, or false and why not
      def add(script, key:, bucket:, by: 1, floor: nil, ceiling: nil)
        name = clean_key(key)
        return [false, key_refusal(key)] if name.nil?

        held = self.class.normalise_bucket(bucket)
        return [false, bucket_refusal] if held.nil?

        amount = whole(by)
        return [false, "an amount has to be a whole number"] if amount.nil?

        apply_add(script, held, name, amount, whole(floor), whole(ceiling))
      end

      # {#add}, several keys in one call, in one transaction: everybody's
      # total moves or nobody's does, the same guarantee a round used to give
      # when it paid out several winners from one close. What a round's
      # close_round pays out now goes through this instead of a game
      # specific award table.
      #
      # @param by [Hash] key => whole number delta
      # @return [true, Array(false, String)] true, or false and why not
      def add_many(script, bucket:, by:, floor: nil, ceiling: nil)
        held = self.class.normalise_bucket(bucket)
        return [false, bucket_refusal] if held.nil?
        return [false, "add needs at least one key"] if by.nil? || by.empty?
        return [false, "add takes at most #{MAX_KEYS_LIMIT} keys at once"] if by.size > MAX_KEYS_LIMIT

        deltas = {}
        by.each do |raw_key, raw_by|
          name = clean_key(raw_key)
          return [false, key_refusal(raw_key)] if name.nil?

          amount = whole(raw_by)
          return [false, "an amount has to be a whole number"] if amount.nil?

          deltas[name] = amount
        end

        apply_add_many(script, held, deltas, whole(floor), whole(ceiling))
      end

      # Take +amount+ off one kept total and put it on another, in one
      # transaction, so a transfer cannot leave one side changed and the other
      # not. The floor applies to the side being debited and is zero unless a
      # script says otherwise, because the ordinary meaning of moving points
      # somebody does not have is that it does not happen.
      #
      # @return [true, Array(false, String)] true, or false and why not
      def move(script, bucket:, from:, to:, amount:, floor: 0)
        source = clean_key(from)
        target = clean_key(to)
        return [false, key_refusal(source.nil? ? from : to)] if source.nil? || target.nil?
        return [false, "a transfer needs two different keys"] if source == target

        held = self.class.normalise_bucket(bucket)
        return [false, bucket_refusal] if held.nil?

        size = whole(amount)
        return [false, "an amount has to be a whole number"] if size.nil?
        # Negative would flip which side is actually being debited, and the floor
        # above is only ever applied to `from`: a script wanting the other
        # direction makes a second call with the sides swapped instead.
        return [false, "a transfer amount has to be positive"] if size.negative?
        return [false, "a kept number has to be under #{MAX_KEPT_VALUE}"] if size.abs > MAX_KEPT_VALUE

        # The floor comes from the script, so it is clamped into the store's own
        # range: an unbounded one is how a total was driven arbitrarily negative.
        asked = whole(floor) || 0
        apply_move(script, held, source, target, size, asked.clamp(-MAX_KEPT_VALUE, MAX_KEPT_VALUE))
      end

      # The highest kept totals in one bucket, sorted by the database.
      #
      # Ordered here rather than in Lua because a leaderboard otherwise means
      # fetching every key in the bucket to look at ten of them, which is the
      # shape a script cannot afford and the reason this exists.
      #
      # @return [Array<Hash>] {"key" =>, "value" =>}, highest first
      def top(script, bucket, limit = DEFAULT_TOP_LIMIT)
        held = self.class.normalise_bucket(bucket)
        return [] if held.nil?

        wanted = (whole(limit) || DEFAULT_TOP_LIMIT).clamp(1, MAX_TOP_LIMIT)
        # The key breaks a tie, so two people on the same score come back in the
        # same order twice rather than in whatever order the backend liked.
        kept_bucket(script, held).order(Sequel.desc(:value), :key).limit(wanted)
                                 .select_map(%i[key value])
                                 .map { |key, value| { "key" => key.to_s, "value" => value.to_i } }
      end

      # The names in one kept bucket, so a script can walk it; {#top} answers
      # with the numbers attached. The prefix match happens in Ruby rather
      # than SQL LIKE because case sensitivity is the collation's business and
      # this project's three backends do not agree on it (SQLite folds ASCII
      # case, MariaDB here does not, Postgres follows the database's
      # collation).
      #
      # @return [Array<String>]
      def keys(script, bucket, prefix = "", limit = DEFAULT_KEYS_LIMIT)
        held = self.class.normalise_bucket(bucket)
        return [] if held.nil?

        wanted = (whole(limit) || DEFAULT_KEYS_LIMIT).clamp(1, MAX_KEYS_LIMIT)
        names = kept_bucket(script, held).order(:key).select_map(:key).map(&:to_s)
        matching(names, prefix).first(wanted)
      end

      # {#keys}, with the value each name holds: for a script walking what it
      # collected (who answered a round) rather than reading a leaderboard,
      # which is what {#top} is for. Key order rather than highest first.
      #
      # @return [Array<Hash>] {"key" =>, "value" =>}
      def entries(script, bucket, prefix = "", limit = DEFAULT_KEYS_LIMIT)
        held = self.class.normalise_bucket(bucket)
        return [] if held.nil?

        wanted = (whole(limit) || DEFAULT_KEYS_LIMIT).clamp(1, MAX_KEYS_LIMIT)
        rows = kept_bucket(script, held).order(:key).select_map(%i[key value])
                                        .map { |key, value| { "key" => key.to_s, "value" => value.to_i } }
        matching_entries(rows, prefix).first(wanted)
      end

      # How many kept keys there are: in one bucket, or across the community
      # when no bucket is named, which is the number {MAX_KEPT_KEYS} is about.
      def count_keys(script, bucket = nil)
        return @models.script_ledger.where(community_id: script.community_id).count if bucket.nil?

        held = self.class.normalise_bucket(bucket)
        return 0 if held.nil?

        kept_bucket(script, held).count
      end

      # Live working keys only. Counting expired rows towards the cap meant a
      # rule keying on a person filled up permanently in a busy room and every
      # later remember answered false, which is the opposite of what the TTL
      # promises.
      def count(script, room_key, now: @clock.call, scope: nil)
        live_rows(script, room_key, scope: scope, now: now).count
      end

      # Drop everything already expired, anywhere: cheap because expires_at is
      # indexed and the table is mostly live rows. Nothing sweeps the kept
      # store, since {MAX_KEPT_KEYS} is its only bound; {PRUNE_KIND}'s
      # handler, run daily by {Core::Runtime}, calls this.
      def sweep(now: @clock.call)
        @models.script_memo.where { expires_at <= now }.delete
      end

      private

      # ---------------------------------------------------------------------
      # The working store
      # ---------------------------------------------------------------------

      def write_working(script, room_key, scope, name, value, ttl, bucket)
        body = encode(value)
        return [false, "a remembered value has to be under #{MAX_VALUE_BYTES} bytes"] if
          body.bytesize > MAX_VALUE_BYTES

        clash = kept_elsewhere(script, bucket, name)
        return [false, clash] if clash

        row = find(script, room_key, name, scope: scope)
        # Named for whatever the cap really belongs to. A shared bucket's keys
        # are counted per bucket, not per script, so telling somebody "this
        # script is holding 100 keys" sent them looking through a script that
        # might have written none of them.
        return [false, full_message(scope)] if
          row.nil? && count(script, room_key, scope: scope) >= MAX_KEYS

        write(script, room_key, name, body, expiry(ttl), row, scope: scope)
        true
      end

      # Whose allowance this is, in the words of whoever hit it.
      def full_message(scope)
        bucket = scope.to_s.start_with?("b:") ? scope.to_s.delete_prefix("b:") : nil
        return "the #{bucket} bucket is already holding #{MAX_KEYS} keys in this room" if bucket

        "this script is already holding #{MAX_KEYS} keys in this room"
      end

      # Every live row of one working scope in one room. The comparison has to
      # stay in the database: expires_at is written as UTC but read back
      # tagged with the host's local zone, so comparing "expires_at <= now" in
      # Ruby made any short ttl look expired the instant it was written.
      def live_rows(script, room_key, scope: nil, now: @clock.call)
        @models.script_memo
               .where(community_id: script.community_id, room_key: room_key.to_s,
                      scope: scope || self.class.private_scope(script))
               .where { expires_at > now }
      end

      def live(script, room_key, key, scope:, now:)
        scoped(script, room_key, key, scope: scope).where { expires_at > now }.first
      end

      # Drop whatever expired copy is sitting there, so a lapsed memo costs one
      # delete rather than accumulating until a sweep runs.
      def clear_stale(script, room_key, key, scope:)
        scoped(script, room_key, key, scope: scope).delete
        nil
      end

      def scoped(script, room_key, key, scope:)
        @models.script_memo.where(community_id: script.community_id, room_key: room_key.to_s,
                                  scope: scope, key: key)
      end

      def find(script, room_key, key, scope:)
        scoped(script, room_key, key, scope: scope).first
      end

      def write(script, room_key, key, body, expires_at, existing, scope:)
        now = @clock.call
        if existing
          existing.update(value: body, expires_at: expires_at, updated_at: now)
        else
          @models.script_memo.create(
            community_id: script.community_id,
            # Null for a shared bucket, which outlives whichever script happened
            # to create it and must not be cascaded away with that script.
            community_script_id: scope.start_with?("s:") ? script.id : nil,
            scope: scope, room_key: room_key.to_s, key: key, value: body,
            expires_at: expires_at, created_at: now, updated_at: now
          )
        end
      end

      # A ttl above the ceiling is clamped rather than refused. A script asking
      # to remember something for a year is being optimistic rather than wrong,
      # and clamping keeps it working with a shorter memory instead of failing.
      def expiry(ttl)
        seconds = Integer(ttl, exception: false) || DEFAULT_TTL
        seconds = DEFAULT_TTL if seconds <= 0
        @clock.call + [seconds, MAX_TTL].min
      end

      # ---------------------------------------------------------------------
      # The kept store
      # ---------------------------------------------------------------------

      def kept?(ttl) = ttl.to_s.strip.downcase == KEPT

      # Set a kept total outright. The type check is the privacy design: this
      # row has no expiry, so anything that is not a number is refused here
      # rather than sitting in the database until somebody notices.
      def keep(script, bucket, name, value)
        held = self.class.normalise_bucket(bucket)
        return [false, "something kept forever needs a bucket to keep it in"] if held.nil?

        amount = whole(value)
        return [false, kept_type_refusal] if amount.nil?
        return [false, "a kept number has to be under #{MAX_KEPT_VALUE}"] if amount.abs > MAX_KEPT_VALUE

        clash = remembered_elsewhere(script, held, name)
        return [false, clash] if clash

        set_kept(script, held, name, amount)
      end

      def set_kept(script, bucket, name, amount)
        rows = kept_rows(script, bucket, name)
        now = @clock.call
        return true if rows.update(value: amount, updated_at: now).positive?
        return [false, kept_full_message] if count_keys(script) >= MAX_KEPT_KEYS

        create_kept(script, bucket, name, amount, now)
        true
      rescue Sequel::UniqueConstraintViolation
        # Another invocation created the row between the update and the insert.
        # It exists now, so the value this call meant to set is what it gets.
        rows.update(value: amount, updated_at: @clock.call)
        true
      end

      # Refused by raising Sequel::Rollback rather than by returning, because a
      # `return` out of a transaction block commits: Sequel only rolls back for
      # an exception, so a refusal that returned would leave the row this opened
      # at zero sitting there spending a key against the cap.
      def apply_add(script, bucket, name, amount, floor, ceiling)
        refusal = nil
        total = nil
        @models.db.transaction do
          rows = kept_rows(script, bucket, name)
          if rows.first.nil?
            refusal = kept_full_message if count_keys(script) >= MAX_KEPT_KEYS
            raise Sequel::Rollback if refusal

            create_kept(script, bucket, name, 0, @clock.call)
          end

          moved = bounded(rows, amount, floor, ceiling).update(value: Sequel[:value] + amount,
                                                               updated_at: @clock.call)
          if moved.zero?
            refusal = bounds_refusal(name, floor, ceiling)
            raise Sequel::Rollback
          end
          total = rows.get(:value).to_i
        end
        refusal ? [false, refusal] : total
      rescue Sequel::UniqueConstraintViolation
        [false, "#{name} was written at the same moment, so nothing was added"]
      end

      # {#apply_add}, several keys in one transaction: a refusal on any one of
      # them rolls the whole batch back, so a round's payout either lands for
      # everybody it named or for nobody.
      def apply_add_many(script, bucket, deltas, floor, ceiling)
        refusal = nil
        @models.db.transaction do
          deltas.each do |name, amount|
            if kept_rows(script, bucket, name).first.nil?
              refusal = kept_full_message if count_keys(script) >= MAX_KEPT_KEYS
              raise Sequel::Rollback if refusal

              create_kept(script, bucket, name, 0, @clock.call)
            end

            moved = bounded(kept_rows(script, bucket, name), amount, floor, ceiling)
                    .update(value: Sequel[:value] + amount, updated_at: @clock.call)
            next unless moved.zero?

            refusal = bounds_refusal(name, floor, ceiling)
            raise Sequel::Rollback
          end
        end
        refusal ? [false, refusal] : true
      rescue Sequel::UniqueConstraintViolation
        [false, "#{bucket} was written at the same moment, so nothing was added"]
      end

      def apply_move(script, bucket, source, target, amount, floor)
        refusal = nil
        @models.db.transaction do
          refusal = kept_full_message if ensure_kept(script, bucket, [source, target])
          raise Sequel::Rollback if refusal

          now = @clock.call
          # Both sides go through the same bounded clause add uses, so the
          # store's ceiling applies to a transfer as well as to a credit.
          taken = bounded(kept_rows(script, bucket, source), -amount, floor, nil)
                  .update(value: Sequel[:value] - amount, updated_at: now)
          if taken.zero?
            refusal = "#{source} does not have #{amount} to give"
            raise Sequel::Rollback
          end

          given = bounded(kept_rows(script, bucket, target), amount, nil, nil)
                  .update(value: Sequel[:value] + amount, updated_at: now)
          if given.zero?
            refusal = bounds_refusal(target, nil, nil)
            raise Sequel::Rollback
          end
        end
        refusal ? [false, refusal] : true
      rescue Sequel::UniqueConstraintViolation
        [false, "#{bucket} was written at the same moment, so nothing was moved"]
      rescue Sequel::DatabaseError
        [false, "#{bucket} could not take a move that size"]
      end

      # Open both sides of a transfer at zero if they are not there yet, so a
      # move into a total nobody has opened works the way a first credit does.
      # Answers true when the cap refused one of them.
      def ensure_kept(script, bucket, names)
        now = @clock.call
        names.any? do |name|
          next false unless kept_rows(script, bucket, name).first.nil?
          next true if count_keys(script) >= MAX_KEPT_KEYS

          create_kept(script, bucket, name, 0, now)
          false
        end
      end

      # The bounds as a WHERE clause over the value the update would write, so
      # the database refuses a change that would break them rather than this
      # reading the total first and hoping nothing moves in between.
      def bounded(rows, amount, floor, ceiling)
        rows = rows.where { value + amount >= floor } unless floor.nil?
        rows = rows.where { value + amount <= ceiling } unless ceiling.nil?
        # The store's own ceiling applies whether or not the script named one,
        # so a loop that adds cannot walk a total past what the column holds.
        rows.where { value + amount <= MAX_KEPT_VALUE }
            .where { value + amount >= -MAX_KEPT_VALUE }
      end

      def bounds_refusal(name, floor, ceiling)
        limits = []
        limits << "below #{floor}" unless floor.nil?
        limits << "above #{ceiling}" unless ceiling.nil?
        return "that would put #{name} #{limits.join(" or ")}" unless limits.empty?

        "that would put #{name} past #{MAX_KEPT_VALUE}, which is as large as a kept number gets"
      end

      def kept_value(script, bucket, name)
        held = bucket.nil? ? nil : self.class.normalise_bucket(bucket)
        return nil if held.nil?

        kept_rows(script, held, name).get(:value)&.to_i
      end

      def kept_rows(script, bucket, name)
        kept_bucket(script, bucket).where(key: name)
      end

      def kept_bucket(script, bucket)
        @models.script_ledger.where(community_id: script.community_id, bucket: bucket)
      end

      def create_kept(script, bucket, name, amount, now)
        @models.script_ledger.create(community_id: script.community_id, bucket: bucket,
                                     key: name, value: amount, created_at: now, updated_at: now)
      end

      def kept_full_message
        "this community is already keeping #{MAX_KEPT_KEYS} totals, which is the limit"
      end

      def kept_type_refusal
        "something kept forever has to be a whole number, since nothing here expires. " \
          "Keep a number and put the words in the script"
      end

      # ---------------------------------------------------------------------
      # Keeping one name in one store
      # ---------------------------------------------------------------------

      # A private memo cannot collide with anything: no kept row carries a
      # script's own scope, so only a named bucket is worth looking up.
      def kept_elsewhere(script, bucket, name)
        return nil if bucket.nil?

        held = self.class.normalise_bucket(bucket)
        return nil if held.nil? || kept_rows(script, held, name).first.nil?

        "#{held}:#{name} is kept, so it cannot also be remembered with a ttl. Forget it first"
      end

      # The mirror of the above, asked across the whole community rather than
      # one room: a kept total is community wide, so a memo in any room under
      # that name is the same name twice. The refusal deliberately names
      # nothing, since echoing the bucket and key back would tell a caller
      # that name is in use in a room it cannot read, a cross-room existence
      # oracle.
      def remembered_elsewhere(script, bucket, name)
        rows = @models.script_memo.where(community_id: script.community_id,
                                         scope: "b:#{bucket}", key: name)
        return nil if rows.first.nil?

        "that name is already remembered with a ttl somewhere in this community, " \
          "so it cannot also be kept. Forget it first, or keep it under another name"
      end

      # ---------------------------------------------------------------------
      # Shared
      # ---------------------------------------------------------------------

      def working_scope(script, bucket)
        return self.class.private_scope(script) if bucket.nil?

        self.class.bucket_scope(bucket)
      end

      def clean_key(key)
        name = key.to_s.strip
        return nil if name.empty? || name.length > MAX_KEY_LENGTH

        name
      end

      def key_refusal(key)
        return "a memo needs a key" if key.to_s.strip.empty?

        "a memo key has to be under #{MAX_KEY_LENGTH} characters"
      end

      def bucket_refusal = "that is not a bucket name"

      # +names+ that start with +prefix+. An empty prefix keeps everything.
      def matching(names, prefix)
        wanted = prefix.to_s
        return names if wanted.empty?

        names.select { |name| name.start_with?(wanted) }
      end

      # {#matching}, over {#entries}'s key/value hashes rather than bare names.
      def matching_entries(rows, prefix)
        wanted = prefix.to_s
        return rows if wanted.empty?

        rows.select { |row| row["key"].start_with?(wanted) }
      end

      # A whole number, or nil for anything that is not one. Written once
      # because every bound in the kept store asks the same question, and
      # Integer("5.5") raising where Integer(5.5) truncates is exactly the
      # inconsistency a script should not have to know about.
      def whole(value)
        return nil if value.nil? || value.is_a?(TrueClass) || value.is_a?(FalseClass)
        return value.to_i if value.is_a?(Numeric) && value.to_i == value

        Integer(value.to_s, exception: false)
      end

      def encode(value) = YAMLCamel.dump(value)

      # Read back with the same discipline as every other YAML in this project:
      # no permitted classes, no aliases. This is a script's own data rather
      # than a third party's, but the loader should not need to know that.
      def decode(body)
        YAMLCamel.load(body.to_s)
      rescue StandardError
        nil
      end
    end
  end
end
