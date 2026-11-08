# frozen_string_literal: true

require "digest"
require "yamlcamel"

module Rubotty
  module ControlPlane
    # Operator authored scripts: storage, verification, and the rule that only
    # a verified script may run. {#save} never refuses for a broken script,
    # since an operator needs to leave work in progress; only {#enable} is
    # gated, on a smoke test run against the current source and trigger.
    # Verification is recorded as the digest of what passed, not a flag, so
    # editing a character un-verifies the script as a side effect and also
    # switches a live one off, rather than leaving stale code running while
    # the editor shows something new.
    class Scripts
      class Invalid < Rubotty::Error; end

      # What invokes a script, and how the editor says it. A callback is never
      # matched against traffic at all: it exists to be woken by schedule or by
      # an async_http answer, so it has no condition and never sees a message.
      KINDS = %w[processor command callback].freeze

      KIND_LABELS = {
        "processor" => "Message hook, runs on every new message",
        "command" => "Command hook, runs for a specific /thing",
        "callback" => "Callback or handler, invoked only by other scripts, never by people"
      }.freeze
      # The registry is the one list. A dialect whose transpiler this deployment
      # does not have is refused here rather than at compile time, so the message
      # says what is actually wrong.
      def self.languages = Scripting::Dialects.names
      NAME_PATTERN = /\A[a-z0-9][a-z0-9 _-]{0,63}\z/i

      # How many live scripts one community may hold: a slow rule still looks
      # like a working one, and every enabled processor runs on every message,
      # so cost is multiplied by this number. Archived scripts do not count,
      # since they never run.
      MAX_SCRIPTS = 50

      # How large a script's data file may be. A YAML document inflates to
      # roughly 23 times its text size once parsed, so 1 MB is where memory
      # blowup, not appetite, sets the ceiling; anything larger risks taking
      # the box down instead of getting a readable refusal.
      MAX_YAML_BYTES = 1024 * 1024

      # How large a script's source may be: half the data cap, since this is
      # code somebody types rather than data somebody generates, and 512 KB is
      # already more Lua than any rule ought to be or than the frame carrying
      # it to a child process can hold.
      MAX_SOURCE_BYTES = 512 * 1024

      # How much parsed YAML is kept in memory, measured in document text
      # bytes rather than entry count: banks vary too widely in size for a
      # count to bound memory usefully. Set to 2 MB because parsing a 4 MB
      # bank costs 612 ms versus 7 ms to hand back an already-parsed copy, so
      # the cache is worth what it costs to hold.
      MAX_CACHED_YAML_BYTES = 2 * 1024 * 1024

      # What handed a script the work. Traffic is one thing and the clock is
      # another, so a rule that only ever wakes on a schedule does not read as
      # a rule people are using.
      RUN_SOURCES = %w[message wake].freeze

      # How many pending runs to hold before writing them out. Higher than the
      # statistics store's threshold because the keys here are bounded by the
      # script count rather than by anything a script names, so a larger batch
      # still collapses to the same handful of rows.
      RUN_FLUSH_AFTER = 100

      # And a ceiling in time, so a quiet room's counts still land. Only ever
      # reached by {#flush_runs_if_due}, called on a timer by whoever owns this.
      RUN_FLUSH_AFTER_SECONDS = 30

      # How long a day's counts are kept. A lifetime total answers less than a
      # count per day does, and a count per day is a row to age out.
      RUN_RETENTION_DAYS = 90

      # The durable job kind that ages them out, run once a day.
      RUN_PRUNE_KIND = "script_runs_prune"

      RUN_PRUNE_INTERVAL = 24 * 60 * 60

      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now }, compiler: nil, smoke_test: nil)
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
        @compiler = compiler
        @smoke_test = smoke_test
        # [community_id, script_id, day, source] => [runs, failures], held in
        # memory until a threshold. Pending counts die with the process, which
        # is the trade coalescing makes.
        @pending_runs = {}
        @pending_runs_count = 0
        @pending_runs_since = nil
        @runs_lock = Mutex.new
        # digest => [parsed document, document bytes], least recently used first.
        # Ruby's Hash keeps insertion order, so a hit is a delete and a reinsert
        # and eviction is taking from the front.
        @parsed = {}
        @parsed_bytes = 0
        @parsed_lock = Mutex.new
      end

      # How much of a Lua error is kept. A script may write
      # error("bad input: " .. rubotty.text()), so the tail of a message can end up in
      # this column; the useful part of a Lua error is the front, so keeping a
      # short prefix serves the operator and bounds what gets stored.
      ERROR_LIMIT = 300

      # How many past errors the editor shows.
      ERROR_HISTORY = 20

      # Every live script for a community, name order. Archived ones are left
      # out, since they are gone as far as anything but the archive view cares.
      def list(community, archived: false)
        rows = @models.community_script.where(community_id: community.id)
        rows = archived ? rows.exclude(archived_at: nil) : rows.where(archived_at: nil)
        rows.order(:name).all
      end

      def find(community, id)
        @models.community_script.where(community_id: community.id, id: id).first
      end

      def find_by_name(community, name)
        @models.community_script.where(community_id: community.id, name: name.to_s).first
      end

      # The scripts that may actually run: enabled, verified against their
      # current text, and not tripped by the circuit breaker. This is the only
      # method the bot side should use to decide what to load.
      def active(community)
        list(community).select { |row| runnable?(row) }
      end

      # Whether this row is allowed to run right now. Three conditions, and all
      # three are the row's own state, so nothing has to be recomputed anywhere
      # else to answer it.
      def runnable?(row)
        return false unless truthy?(row.enabled)
        return false unless verified?(row)
        return false unless row.disabled_at.nil?
        return false unless row.archived_at.nil?

        true
      end

      # Whether the smoke test that passed was run against what is in the row
      # now. Editing invalidates this without any code having to notice.
      def verified?(row)
        digest = row.verified_digest.to_s
        !digest.empty? && digest == digest_for(row)
      end

      # Create or update. Never refuses because a script is broken (that's
      # {#verify}'s job and {#enable}'s gate), except when the source will not
      # compile or the data file will not parse: neither has anything
      # runnable to store, and a bad data file is better refused here than
      # left to fail in front of a room.
      def save(community:, name:, kind:, source:, trigger_type:, trigger_config: {}, language: "lua",
               created_by: nil, id: nil, yaml_data: nil)
        attributes = validate(name: name, kind: kind, source: source, language: language,
                              trigger_type: trigger_type, trigger_config: trigger_config,
                              yaml_data: yaml_data)
        now = @clock.call
        existing = id ? find(community, id) : find_by_name(community, attributes[:name])
        if existing.nil?
          if list(community).length >= MAX_SCRIPTS
            raise Invalid, "This community already has #{MAX_SCRIPTS} scripts, which is the limit. " \
                           "Delete one you are not using."
          end

          return insert(community, attributes, created_by, now)
        end

        # Any edit drops the verification and switches the rule off, so it can
        # never keep running on text nobody has checked.
        existing.update(**attributes, enabled: false, verified_digest: nil, verified_at: nil,
                        consecutive_failures: 0, disabled_at: nil, disabled_reason: nil, updated_at: now)
        existing.refresh
      end

      # Run the smoke test and record what it found. Returns the result so a
      # caller can show the failures; the row carries them too, so reopening the
      # editor does not mean re-running anything.
      def verify(community, id)
        row = find!(community, id)
        raise Invalid, "no smoke test is configured, so nothing can be verified" if @smoke_test.nil?

        # Probed against the row's real data file, not nothing, so logic that
        # reads a list is actually exercised. Every trigger the row declares is
        # probed, not just the first, so a command-and-condition script is
        # checked against both payload shapes.
        result = @smoke_test.run(kind: row.kind.to_sym, source: row.compiled.to_s,
                                 trigger: Scripting::Triggers.build_all(row.trigger_type, trigger_config(row)),
                                 yaml_data: yaml_data(row))
        record_verification(row, result)
        result
      end

      # Turn a script on. Refuses unless it has passed the smoke test against
      # exactly this text, which is the whole point of the gate. The refusal
      # carries the last check's own notes, so a probe that merely timed out
      # reads as that rather than as a script that failed its check.
      def enable(community, id)
        row = find!(community, id)
        unless verified?(row)
          notes = row.verification_notes.to_s
          detail = notes.empty? ? "Run the check first." : "#{notes} Run the check again."
          raise Invalid, "#{row.name.inspect} has not passed its smoke test since it was last edited. #{detail}"
        end

        row.update(enabled: true, disabled_at: nil, disabled_reason: nil,
                   consecutive_failures: 0, updated_at: @clock.call)
        row.refresh
      end

      def disable(community, id)
        row = find!(community, id)
        row.update(enabled: false, updated_at: @clock.call)
        row.refresh
      end

      # Archive rather than destroy, so a wrongly archived rule can still be
      # read back; destroying for good stays a separate, deliberate act (see
      # {#purge}). The name is stamped on the way out because (community_id,
      # name) is uniquely indexed, so an archived "guard" would otherwise keep
      # the name reserved and block an operator from reusing it for a
      # replacement.
      def archive(community, id)
        row = find!(community, id)
        now = @clock.call
        row.update(archived_at: now, enabled: false, name: archived_name(community, row, now),
                   updated_at: now)
        row.refresh
      end

      # Restoring has to find a free name again, since something may have taken
      # the original in the meantime.
      def restore(community, id)
        row = find!(community, id)
        now = @clock.call
        # Comes back off, and unverified, because the world may have moved on
        # while it sat in the archive.
        row.update(archived_at: nil, enabled: false, verified_digest: nil, verified_at: nil,
                   name: free_name(community, base_name(row.name), row.id), updated_at: now)
        row.refresh
      end

      # Really gone. Kept separate from {#archive} so nothing reaches it by
      # accident, and so a script can never call it.
      def purge(community, id)
        row = find!(community, id)
        row.destroy
        true
      end

      # The circuit breaker: a rule that keeps failing at message time is
      # switched off rather than retried forever, so a broken script degrades
      # once instead of on every message for the life of the process.
      def record_failure(row, reason, threshold: 5)
        count = row.consecutive_failures.to_i + 1
        attributes = { consecutive_failures: count, updated_at: @clock.call }
        if count >= threshold
          attributes[:disabled_at] = @clock.call
          attributes[:disabled_reason] = "switched off after #{count} consecutive failures: #{reason}"
          @logger&.warn { "scripting: disabling #{row.name.inspect} after #{count} failures: #{reason}" }
        end
        row.update(**attributes)
        row.refresh
      end

      # What went wrong the last time this ran on real traffic. Feeds the same
      # counter the circuit breaker reads, so there is one notion of "this keeps
      # failing" rather than two that can disagree.
      def record_error(row, message, threshold: 5)
        text = message.to_s[0, ERROR_LIMIT]
        history = ([{ "at" => @clock.call.to_s, "message" => text }] + error_history(row)).first(ERROR_HISTORY)
        row.update(last_error: text, last_error_at: @clock.call,
                   recent_errors: Models.dump_json(history), updated_at: @clock.call)
        record_failure(row.refresh, text, threshold: threshold)
      end

      def error_history(row)
        parsed = row.json_value(:recent_errors)
        parsed.is_a?(Array) ? parsed : []
      rescue StandardError
        []
      end

      def record_success(row)
        return row if row.consecutive_failures.to_i.zero?

        row.update(consecutive_failures: 0, updated_at: @clock.call)
        row.refresh
      end

      # Count one invocation. A run is the handoff: the router gave this script
      # the work and its body was dispatched, whatever it decided afterwards, so
      # a message a rule rejects counts exactly once, same as one it allows. A
      # run that raised counts as both a run and a failure. Nothing is written
      # here: the count lands in memory and {#flush_runs} persists it later,
      # since a write per message is not worth the cost.
      #
      # @return [Boolean] whether the run was counted
      def record_run(row, source: "message", failed: false)
        return false if row.nil?

        key = [row.community_id, row.id, day_of(@clock.call), run_source(source)]
        due = @runs_lock.synchronize do
          counted = (@pending_runs[key] ||= [0, 0])
          counted[0] += 1
          counted[1] += 1 if failed
          @pending_runs_count += 1
          @pending_runs_since ||= @clock.call
          @pending_runs_count >= RUN_FLUSH_AFTER ||
            (@clock.call - @pending_runs_since) >= RUN_FLUSH_AFTER_SECONDS
        end
        flush_runs if due
        true
      end

      # Write out if the time ceiling has passed. Called on a timer, since
      # nothing else can make a bound in time mean anything on a quiet room.
      def flush_runs_if_due(now: @clock.call)
        due = @runs_lock.synchronize do
          !@pending_runs_since.nil? && (now - @pending_runs_since) >= RUN_FLUSH_AFTER_SECONDS
        end
        due ? flush_runs : 0
      end

      # Write out whatever has been counted since the last flush.
      #
      # @return [Integer] rows really written. A database error is swallowed
      #   per row rather than losing the rest of the batch with it, and never
      #   reaches the caller: a room's traffic does not stop because a counter
      #   could not be written.
      def flush_runs
        batch = @runs_lock.synchronize do
          held = @pending_runs
          @pending_runs = {}
          @pending_runs_count = 0
          @pending_runs_since = nil
          held
        end
        return 0 if batch.empty?

        batch.count do |(community_id, script_id, day, source), (counted, broken)|
          apply_run(community_id, script_id, day, source, counted, broken)
        end
      end

      # One script's counts, newest day first, as
      # [{day:, source:, runs:, failures:}].
      #
      # @param since [String, nil] the earliest day to include, as YYYY-MM-DD
      def runs_for(row, since: nil)
        flush_runs
        rows = @models.script_run.where(script_id: row.id)
        rows = rows.where { day >= since } unless since.nil?
        rows.order(Sequel.desc(:day), :source).all.map do |stored|
          { day: stored.day.to_s, source: stored.source.to_s,
            runs: stored.runs.to_i, failures: stored.failures.to_i }
        end
      end

      # What {#runs_for} adds up to, as { runs:, failures: }. Summed in Ruby
      # because the retention already bounds how many rows there can be.
      def run_totals(row, since: nil)
        counted = runs_for(row, since: since)
        { runs: counted.sum { |entry| entry[:runs] },
          failures: counted.sum { |entry| entry[:failures] } }
      end

      # The day boundary a caller passes to {#runs_for} to ask for a window,
      # so nobody outside this class has to know the day is stored as text.
      def day_window(days, now: @clock.call)
        day_of(now - (days * 24 * 60 * 60))
      end

      # Drop every day past the retention, anywhere. Run daily.
      def prune_runs(now: @clock.call)
        flush_runs
        cutoff = day_window(RUN_RETENTION_DAYS, now: now)
        @models.script_run.where { day < cutoff }.delete
      end

      def trigger_config(row)
        row.json_value(:trigger_config) || {}
      rescue StandardError
        {}
      end

      # This script's data file, parsed and cached, or nil when it has none:
      # the rescue guards a row written before this column existed since
      # {#save} already refuses anything unparseable, and caching matters
      # because a 4 MB bank takes 612 ms to parse. The cache is keyed on
      # {#digest_for}, which already folds the data file in alongside the
      # source and trigger, so any edit misses the cache rather than needing
      # an explicit sweep.
      def yaml_data(row)
        return nil if row.nil?

        body = row.yaml_data.to_s
        return nil if body.strip.empty?

        cached(digest_for(row), body) { self.class.parse_yaml_data(body) }
      rescue StandardError
        nil
      end

      # Read a data file the way the rest of this project reads YAML: no
      # permitted classes, since a community operator's document naming a Ruby
      # class could run code inside the bot; no aliases, since a small document
      # could otherwise expand to a huge one through repeated merges. Blank is
      # no data at all rather than an error.
      #
      # @raise [Invalid] when the document will not parse or is too large
      # @return [Hash, Array, nil]
      def self.parse_yaml_data(text)
        body = text.to_s
        return nil if body.strip.empty?

        if body.bytesize > MAX_YAML_BYTES
          raise Invalid, "A data file has to be under #{size(MAX_YAML_BYTES)}, " \
                         "and this one is #{size(body.bytesize)}."
        end

        shaped(YAMLCamel.load(body))
      rescue YAMLCamel::Error => e
        # The parser's own message names the line, which is the useful half of
        # it, so it is passed through rather than replaced with something
        # vaguer that sounds tidier.
        raise Invalid, "That data file is not valid YAML: #{e.message}"
      end

      # A byte count the way somebody would say it. Held here rather than
      # written out at each call site so raising a cap from kilobytes to
      # megabytes does not leave a refusal reading "1024 KB", and so the editor
      # page and the refusal agree without either restating the arithmetic.
      def self.size(bytes)
        bytes >= 1024 * 1024 ? "#{bytes / (1024 * 1024)} MB" : "#{bytes / 1024} KB"
      end

      # A data file is a set of keys or a list. A document that parses to a bare
      # scalar ("hello", 3, true) is refused rather than handed over, because a
      # script reading `rubotty.yaml_data().words` off a number raises at
      # message time, and the refusal here says what is wrong while somebody is
      # looking at the document.
      def self.shaped(parsed)
        return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array) || parsed.nil?

        raise Invalid, "A data file is a set of keys or a list, and this one is a single value."
      end
      private_class_method :shaped

      # Covers everything that changes what actually runs: source, compiled
      # output, trigger, kind, and the data file, so a compiler upgrade or a
      # changed data list un-verifies the script exactly as an edited source
      # does. Public because {#yaml_data}'s cache also keys on it.
      def digest_for(row)
        Digest::SHA256.hexdigest(
          [row.source, row.compiled, row.trigger_type, row.trigger_config, row.kind,
           row.yaml_data].map(&:to_s).join("\0")
        )
      end

      # How much document text the parse cache is holding, so a spec and an
      # operator reading a console can both see it.
      def cached_yaml_bytes = @parsed_lock.synchronize { @parsed_bytes }

      private

      # One coalesced day's counts, added in the database rather than read,
      # added in Ruby and written back: two threads inside flush with the same
      # key would each read the same total and write it, losing one count.
      def apply_run(community_id, script_id, day, source, counted, broken)
        now = @clock.call
        rows = @models.script_run.where(script_id: script_id, day: day, source: source)
        updated = rows.update(runs: Sequel[:runs] + counted,
                              failures: Sequel[:failures] + broken, updated_at: now)
        return true if updated.positive?

        create_run(rows, community_id, script_id, day, source, counted, broken, now)
      rescue StandardError => e
        @logger&.warn { "scripts: could not write a run count: #{e.class}: #{e.message}" }
        false
      end

      # A day this thread has just decided is missing, which another may be
      # creating at the same moment. Losing that race means the row exists now,
      # so the counts are added to it rather than dropped.
      def create_run(rows, community_id, script_id, day, source, counted, broken, now)
        @models.script_run.create(community_id: community_id, script_id: script_id, day: day,
                                  source: source, runs: counted, failures: broken,
                                  created_at: now, updated_at: now)
        true
      rescue Sequel::UniqueConstraintViolation
        rows.update(runs: Sequel[:runs] + counted, failures: Sequel[:failures] + broken,
                    updated_at: now).positive?
      end

      # UTC, so a deployment that moves between zones does not split one day in
      # two. getutc rather than utc, which converts the caller's Time in place.
      def day_of(time) = time.getutc.strftime("%Y-%m-%d")

      # Anything outside the pair is counted as traffic rather than dropped: a
      # miscounted source is a worse answer than a lost run is.
      def run_source(source)
        text = source.to_s
        RUN_SOURCES.include?(text) ? text : RUN_SOURCES.first
      end

      # The parsed document for +digest+, parsing it through the block on a
      # miss. Held under a lock because one store serves every thread that runs
      # a rule, and a torn read of the byte total would let the budget drift.
      def cached(digest, body)
        @parsed_lock.synchronize do
          found = @parsed.delete(digest)
          if found
            @parsed[digest] = found
            return found.first
          end
        end

        parsed = yield
        store_parsed(digest, parsed, body.bytesize)
        parsed
      end

      # Remember one document and evict from the least recently used end until
      # the total fits. A document larger than the whole budget is parsed and
      # handed back but never kept, since keeping it would evict everything else
      # and then be evicted itself on the next call.
      def store_parsed(digest, parsed, bytes)
        return if bytes > MAX_CACHED_YAML_BYTES

        @parsed_lock.synchronize do
          @parsed[digest] = [parsed, bytes]
          @parsed_bytes += bytes
          while @parsed_bytes > MAX_CACHED_YAML_BYTES && @parsed.length > 1
            _oldest, dropped = @parsed.shift
            @parsed_bytes -= dropped.last
          end
        end
      end

      ARCHIVED_SUFFIX = /\s*\(archived [^)]*\)\z/

      # "guard" becomes "guard (archived 2026-07-28)", and a second archive the
      # same day gets a counter rather than colliding with the first.
      def archived_name(community, row, now)
        free_name(community, "#{base_name(row.name)} (archived #{now.strftime("%Y-%m-%d")})", row.id)
      end

      def base_name(name) = name.to_s.sub(ARCHIVED_SUFFIX, "")

      # The counter has to be kept, not truncated away: trimming the whole
      # candidate to 64 would make a name already at the limit come back
      # identical every pass and loop forever. Room is made for the suffix
      # instead.
      def free_name(community, wanted, own_id)
        candidate = wanted[0, 64]
        suffix = 1
        while taken?(community, candidate, own_id)
          suffix += 1
          tail = " #{suffix}"
          candidate = "#{wanted[0, 64 - tail.length]}#{tail}"
        end
        candidate
      end

      def taken?(community, name, own_id)
        @models.community_script
               .where(community_id: community.id, name: name)
               .exclude(id: own_id)
               .first
      end

      def find!(community, id)
        row = find(community, id)
        raise Invalid, "no script with id #{id.inspect} in this community" if row.nil?

        row
      end

      def insert(community, attributes, created_by, now)
        @models.community_script.create(
          community_id: community.id, created_by: created_by.to_s, enabled: false,
          consecutive_failures: 0, created_at: now, updated_at: now, **attributes
        )
      end

      def record_verification(row, result)
        if result.ok?
          row.update(verified_digest: digest_for(row), verified_at: @clock.call,
                     verification_notes: nil, updated_at: @clock.call)
        else
          row.update(verified_digest: nil, verified_at: nil,
                     verification_notes: result.to_s, enabled: false, updated_at: @clock.call)
        end
        row.refresh
      end

      def validate(name:, kind:, source:, language:, trigger_type:, trigger_config:, yaml_data: nil)
        clean_name = name.to_s.strip
        raise Invalid, "A script needs a name." unless clean_name.match?(NAME_PATTERN)
        raise Invalid, "A script is a command or a processor." unless KINDS.include?(kind.to_s)
        raise Invalid, "Unknown language #{language}." unless self.class.languages.include?(language.to_s)
        unless Scripting::Dialects.available?(language)
          raise Invalid, "#{language} is not installed on this deployment, so it cannot be saved."
        end
        raise Invalid, "A script needs a body." if source.to_s.strip.empty?

        check_source_size(source)

        # Raises Scripting::Failed for a type outside the catalog, which is what
        # keeps the trigger set closed. Every trigger the row declares, not only
        # the first, or a script could be saved with a second condition that
        # names nothing and then refuse to load at message time.
        Scripting::Triggers.build_all(trigger_type, trigger_config)

        # Parsed only to refuse a broken document. What is stored is the text
        # the operator wrote, so the editor loads back their comments and their
        # ordering rather than a re-serialised version of it, which is why the
        # answer here is thrown away.
        self.class.parse_yaml_data(yaml_data)

        { name: clean_name, kind: kind.to_s, language: language.to_s, source: source.to_s,
          compiled: compile(language, source), trigger_type: trigger_type.to_s,
          trigger_config: Models.dump_json(stringify(trigger_config)),
          yaml_data: yaml_data.to_s }
      end

      # A ceiling on the source, in the same shape the data file's already
      # has: a sentence in the editor rather than whatever the database says
      # when a column overflows. The size is in the message because "too big"
      # without a number leaves somebody guessing how much to cut.
      def check_source_size(source)
        bytes = source.to_s.bytesize
        return if bytes <= MAX_SOURCE_BYTES

        raise Invalid, "A script has to be under #{self.class.size(MAX_SOURCE_BYTES)}, " \
                       "and this one is #{self.class.size(bytes)}."
      end

      # Compiled once, here, so nothing downstream needs a transpiler. A compile
      # failure is refused outright: unlike a script that merely misbehaves, one
      # that will not compile has no runnable form to store at all.
      def compile(language, source)
        dialect = Scripting::Dialects.find(language)
        return source.to_s if dialect.nil? || dialect.native?
        raise Invalid, "#{dialect.label} needs a compiler, and none is configured." if @compiler.nil?

        @compiler.compile(source.to_s, language: language)
      rescue Scripting::Error => e
        raise Invalid, "That #{dialect&.label || language} would not compile: #{e.message}"
      end

      def stringify(config)
        (config || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end

      def truthy?(value) = [true, 1, "1", "t", "true"].include?(value)
    end
  end
end
