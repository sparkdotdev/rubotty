# frozen_string_literal: true

module Rubotty
  module Scripting
    # What wakes a script. An operator declares a rule from the fixed catalog
    # below rather than getting a lookback function, since a script that could
    # read recent messages itself could ask for anything and would run on
    # every message whether or not it had something to do. Each rule is
    # evaluated incrementally as messages arrive and keeps only the RESULT
    # (a ring of match flags or author ids, never message content), which is
    # both why PRIVACY.md's storage claim survives this feature and why a rule
    # cannot re-examine old messages under criteria taken from the current one.
    module Triggers
      # What a trigger sees, kept separate from Core::Message: this layer is
      # tested without the pipeline, and only carries facts the pipeline can
      # actually establish, since a script would branch on an always-false
      # field and be quietly wrong. +edited+ marks a changed message, seen
      # only when a trigger asked for it (see {Base#hears_edits?}) so the
      # rings below are never double pushed; +attachments+, +reply_to+ and
      # +handle+ fill in only when a real Core::Message backs the invocation.
      Event = Struct.new(:text, :author_id, :author_name, :room_key,
                         :author_is_operator, :origin_platform, :edited,
                         :attachments, :reply_to, :handle, keyword_init: true) do
        def text_s = text.to_s

        def author_key = author_id.to_s

        def edited? = !!edited
      end

      # A fixed size ring of the last N values. The whole state budget of this
      # feature: bounded by rule count rather than by traffic, and holding
      # booleans or author ids rather than anything anybody wrote.
      class Ring
        def initialize(size)
          @size = [size.to_i, 1].max
          @items = []
        end

        attr_reader :size

        def push(value)
          @items.push(value)
          @items.shift while @items.length > @size
          value
        end

        def to_a = @items.dup

        def count(value) = @items.count(value)

        def include?(value) = @items.include?(value)

        def length = @items.length
      end

      # A ring of WHEN something happened, for a window measured in minutes
      # rather than in messages: still nothing worth leaking, just an
      # instant, and only for messages that already matched. Old entries
      # fall off as they age rather than when the ring fills, which is the
      # whole difference from {Ring}.
      class TimeRing
        # Bounded anyway, so a very busy room cannot grow this without limit
        # between prunes.
        MAX = 500

        def initialize = @times = []

        def push(now)
          @times.push(now)
          @times.shift while @times.length > MAX
          now
        end

        # How many are still inside +seconds+ of +now+, pruning as it goes.
        def count_within(now, seconds)
          cutoff = now - seconds
          @times.shift while !@times.empty? && @times.first < cutoff
          @times.length
        end
      end

      class Base
        def self.type_name = raise(NotImplementedError, "#{self} must declare a type_name")

        # How the editor explains this trigger to somebody who does not write
        # Ruby. Lives on the trigger rather than in the template, so the
        # description, the fields the form shows, and the code that actually
        # decides all change together, rather than a page offering a Window
        # box for a trigger that never reads one.
        def self.summary = ""

        # Which of the form's trigger fields this one actually reads: any of
        # "name", "words", "names", "window", "count", "minutes", "every",
        # "at". "edits" is deliberately absent from every list here, since it
        # widens which messages a condition is offered rather than deciding
        # anything itself, so the form shows it once for the whole script
        # instead (see {#hears_edits?}).
        def self.fields = []

        # The keys the script finds on m, beyond the ones every payload has.
        def self.hands_over = []

        # Raise Failed if the saved config could never work, called by
        # {build} so a trigger is checked at the point it is constructed
        # rather than the point it first fires, which for a recurring one is
        # inside the scheduler at boot. Most triggers read their config
        # leniently and have nothing to say here.
        def check! = nil

        def initialize(config = {}, clock = nil)
          @config = normalize(config)
          @clock = clock || -> { Time.now.utc }
        end

        attr_reader :config

        # Whether this trigger wants message EDITS as well as new messages,
        # off unless the operator said so: surfacing edits to every trigger
        # would make a windowed condition count one message twice, and a
        # rule that replies would reply again every time somebody fixed a
        # typo. An edit reaches only the scripts that asked for it.
        def hears_edits? = [true, 1, "1", "t", "true", "yes", "on"].include?(@config["edits"])

        # Fold one message in and answer whether the script should wake.
        #
        # @return [Hash, nil] the payload handed to the script, or nil to
        #   stay asleep: what the rule matched on, never a window of other
        #   people's messages.
        def observe(_event) = raise(NotImplementedError)

        # Payloads shaped exactly like the ones {#observe} produces, for the
        # save-time smoke test to run a script against. Comes from the
        # trigger rather than one generic hash, or the gate is theatre: a
        # command script reads rubotty.args() and a recent_contains script
        # reads rubotty.matched(), so a shared payload would pass scripts
        # that break on their real input, and the second element of each
        # pair empties the optional lists since "matched()[1] on an empty
        # list" is the error this actually catches.
        def probe_payloads(text)
          [{ "text" => text, "author" => "smoke-test" }]
        end

        private

        def normalize(config)
          (config || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v }
        end

        def list(key) = Array(@config[key]).map(&:to_s).reject(&:empty?)

        def positive(key, default)
          value = Integer(@config[key], exception: false)
          value.nil? || value < 1 ? default : value
        end

        def haystack(text) = @config["case_sensitive"] ? text : text.downcase

        def needles(key) = @config["case_sensitive"] ? list(key) : list(key).map(&:downcase)
      end

      # Every message. The plain processor hook, for a rule whose whole logic
      # lives in the script.
      class Always < Base
        def self.type_name = "always"

        def self.summary = "Runs on every message in the room. Use it when the rule itself decides."

        def self.hands_over = %w[text author]

        def observe(event) = { "text" => event.text_s, "author" => event.author_name.to_s }
      end

      # This message contains any of the configured words.
      class Contains < Base
        def self.type_name = "contains"

        def self.summary = "Runs when a message contains any of your words. Matching ignores case."

        def self.fields = %w[words]

        def self.hands_over = %w[text author matched]

        def observe(event)
          text = haystack(event.text_s)
          hits = needles("words").select { |word| text.include?(word) }
          return nil if hits.empty?

          { "text" => event.text_s, "author" => event.author_name.to_s, "matched" => hits }
        end

        def probe_payloads(text)
          base = { "text" => text, "author" => "smoke-test" }
          [base.merge("matched" => needles("words").first(1)), base.merge("matched" => [])]
        end
      end

      # At least +count+ of the last +window+ messages contained one of the
      # words. State is a ring of booleans, so nothing anybody wrote is kept.
      class RecentContains < Base
        DEFAULT_WINDOW = 20
        DEFAULT_COUNT = 3

        def self.type_name = "recent_contains"

        def self.summary =
          "Runs once your words have shown up in at least Count of the last Window messages, " \
          "and this message is one of them. For a word that is fine occasionally and a problem repeatedly."

        def self.fields = %w[words window count]

        def self.hands_over = %w[text author matched hits window]

        def initialize(config = {}, clock = nil)
          super
          @ring = Ring.new(positive("window", DEFAULT_WINDOW))
          @needed = positive("count", DEFAULT_COUNT)
        end

        def observe(event)
          text = haystack(event.text_s)
          hits = needles("words").select { |word| text.include?(word) }
          @ring.push(!hits.empty?)
          seen = @ring.count(true)
          return nil unless !hits.empty? && seen >= @needed

          # "matched" is the operator's own configured words, never anything a
          # member wrote, so handing it over adds no content to the payload.
          { "text" => event.text_s, "author" => event.author_name.to_s,
            "matched" => hits, "hits" => seen, "window" => @ring.size }
        end

        def probe_payloads(text)
          base = { "text" => text, "author" => "smoke-test", "hits" => @needed, "window" => @ring.size }
          [base.merge("matched" => needles("words").first(1)), base.merge("matched" => [])]
        end
      end

      # Every configured name is among the last +window+ senders. A ring of
      # author ids, no text at all.
      class RecentSenders < Base
        DEFAULT_WINDOW = 10

        def self.type_name = "recent_senders"

        def self.summary =
          "Runs when everybody in your Names list has spoken within the last Window messages. " \
          "For noticing that a particular group is all here."

        def self.fields = %w[names window]

        def self.hands_over = %w[text author present]

        def initialize(config = {}, clock = nil)
          super
          @ring = Ring.new(positive("window", DEFAULT_WINDOW))
        end

        def observe(event)
          @ring.push(event.author_name.to_s.downcase)
          wanted = list("names").map(&:downcase)
          return nil if wanted.empty?
          return nil unless wanted.all? { |name| @ring.include?(name) }

          { "text" => event.text_s, "author" => event.author_name.to_s, "present" => wanted }
        end

        def probe_payloads(text)
          base = { "text" => text, "author" => "smoke-test" }
          [base.merge("present" => list("names")), base.merge("present" => [])]
        end
      end

      # This author has sent at least +count+ of the last +window+ messages.
      class AuthorRepeat < Base
        DEFAULT_WINDOW = 10
        DEFAULT_COUNT = 4

        def self.type_name = "author_repeat"

        def self.summary =
          "Runs when one person has sent at least Count of the last Window messages. " \
          "For somebody dominating a room, whatever they are saying."

        def self.fields = %w[window count]

        def self.hands_over = %w[text author count window]

        def initialize(config = {}, clock = nil)
          super
          @ring = Ring.new(positive("window", DEFAULT_WINDOW))
          @needed = positive("count", DEFAULT_COUNT)
        end

        def observe(event)
          @ring.push(event.author_key)
          seen = @ring.count(event.author_key)
          return nil if seen < @needed

          { "text" => event.text_s, "author" => event.author_name.to_s,
            "count" => seen, "window" => @ring.size }
        end

        def probe_payloads(text)
          [{ "text" => text, "author" => "smoke-test", "count" => @needed, "window" => @ring.size }]
        end
      end

      # This author has not spoken in the last +window+ messages. Useful for
      # greeting somebody, and for catching a first post that is a link dump.
      class NewVoice < Base
        DEFAULT_WINDOW = 50

        def self.type_name = "new_voice"

        def self.summary =
          "Runs the first time somebody speaks who has not been heard in the last Window messages. " \
          "For greeting a newcomer."

        def self.fields = %w[window]

        def self.hands_over = %w[text author]

        def initialize(config = {}, clock = nil)
          super
          @ring = Ring.new(positive("window", DEFAULT_WINDOW))
        end

        def observe(event)
          seen_before = @ring.include?(event.author_key)
          @ring.push(event.author_key)
          return nil if seen_before

          { "text" => event.text_s, "author" => event.author_name.to_s }
        end
      end

      # A slash or bang command, which is what a custom command hangs off.
      class Command < Base
        PREFIXES = %w[/ !].freeze

        def self.type_name = "command"

        def self.summary =
          "Runs when somebody types your command, with either / or ! in front of it. " \
          "Write the name without the slash."

        def self.fields = %w[name]

        def self.hands_over = %w[text author command args]

        def observe(event)
          name = @config["name"].to_s.downcase
          return nil if name.empty?

          body = event.text_s.strip
          prefix = PREFIXES.find { |p| body.start_with?(p) }
          return nil if prefix.nil?

          word, rest = body[1..].to_s.split(/\s+/, 2)
          return nil unless word.to_s.split("@").first.to_s.downcase == name

          { "text" => event.text_s, "author" => event.author_name.to_s,
            "command" => name, "args" => rest.to_s.strip }
        end

        # A bare invocation is the shape most command scripts forget: args is an
        # empty string, never nil, and a script indexing into it has to cope.
        def probe_payloads(text)
          name = @config["name"].to_s
          base = { "text" => "/#{name} #{text}".strip, "author" => "smoke-test", "command" => name }
          [base.merge("args" => text), base.merge("args" => "")]
        end
      end

      # A trigger with nothing to react to: it answers nil to every message and
      # is woken on a clock instead, by a durable job Core::Runtime keeps in
      # step with the live scripts. Modeled as a trigger like the rest, rather
      # than a separate concept, so an operator picks it from the same list
      # and the smoke test and editor need no special case.
      class Recurring < Base
        DEFAULT_EVERY = 24 * 60 * 60

        # What the form offers, in seconds. A short cadence is deliberately not
        # among them: this wakes a whole Lua invocation, and "every minute" is
        # somebody wanting a message trigger.
        EVERY = { "hour" => 60 * 60, "day" => 24 * 60 * 60, "week" => 7 * 24 * 60 * 60 }.freeze

        def self.type_name = "recurring"

        def self.summary =
          "Runs on a clock rather than because somebody spoke. Pick how often, and the time of day " \
          "for a daily or weekly one."

        def self.fields = %w[every at]

        def self.hands_over = %w[kind]

        # Never woken by traffic. A recurring script that also answered messages
        # would be two rules wearing one name.
        def observe(_event) = nil

        # How often, in seconds, whatever the form was given.
        def interval = EVERY[@config["every"].to_s] || DEFAULT_EVERY

        # The next time this should fire, at or after +now+. Interpreted in UTC,
        # the same clock everything else here keeps, so a deployment does not
        # move somebody's daily digest twice a year.
        def next_run(now)
          hour, minute = time_of_day
          return boundary_after(now) if hour.nil? || interval < EVERY["day"]

          target = Time.utc(now.year, now.month, now.day, hour, minute)
          target <= now ? target + interval : target
        end

        # The next interval boundary from the epoch, for a cadence with no time
        # of day to anchor to; an hourly script runs on the hour. The whole
        # schedule rebuilds at boot, so anchoring matters: measuring from "now"
        # would push a script out by every restart, and one on a deployment
        # that redeploys more often than hourly would never run.
        def boundary_after(now)
          Time.at(((now.to_i / interval) + 1) * interval).utc
        end

        # The editor's time field is free text; an unchecked bad value (like an
        # hour of 25) used to reach Time.utc and raise at boot, inside the loop
        # that rebuilds every community's wakes, taking down every
        # deployment's recurring scripts over one community's typo. Refused
        # here instead, where the operator is looking at it.
        def check!
          return if @config["at"].to_s.strip.empty? || !time_of_day.first.nil?

          raise Failed, "#{@config["at"].to_s.inspect} is not a time of day. Use HH:MM, such as 09:00."
        end

        private

        # Hour and minute, or nil for anything this cannot use. Nothing here
        # raises: a stored row with a bad time predates the check above, and
        # falling back to the plain interval keeps that one script odd rather
        # than stopping every script.
        def time_of_day
          # Base 10 explicitly. A bare Integer("09") is read as octal and is
          # invalid, so every time before 10:00 silently became "no time set".
          hour, minute = @config["at"].to_s.split(":").map { |part| Integer(part, 10, exception: false) }
          minute ||= 0
          return [nil, nil] unless hour&.between?(0, 23) && minute.between?(0, 59)

          [hour, minute]
        end

        # Nothing about a message reaches this script, so the smoke test runs it
        # against the one payload it will really see.
        def probe_payloads(_text) = [{}]
      end

      # Counts by time rather than by message: every other windowed trigger
      # counts MESSAGES, the wrong unit for pace, since twenty messages is a
      # minute in a busy room and a week in a quiet one. Kept incrementally as
      # a ring of the instants the words matched, no text and no author, so a
      # room's traffic is still not stored to answer this.
      class ContainsRate < Base
        DEFAULT_MINUTES = 10
        DEFAULT_COUNT = 3

        def self.type_name = "contains_rate"

        def self.summary =
          "Runs when your words have shown up Count times in the last Minutes minutes, however many " \
          "messages that took. For pace rather than volume, like a third link in ten minutes."

        def self.fields = %w[words count minutes]

        def self.hands_over = %w[text author matched count minutes]

        def initialize(config = {}, clock = nil)
          super
          @ring = TimeRing.new
          @needed = positive("count", DEFAULT_COUNT)
          @minutes = positive("minutes", DEFAULT_MINUTES)
        end

        def observe(event)
          text = haystack(event.text_s)
          hits = needles("words").select { |word| text.include?(word) }
          return nil if hits.empty?

          now = @clock.call
          @ring.push(now)
          seen = @ring.count_within(now, @minutes * 60)
          return nil if seen < @needed

          { "text" => event.text_s, "author" => event.author_name.to_s,
            "matched" => hits, "count" => seen, "minutes" => @minutes }
        end

        # Both variants carry every key, because observe always supplies all
        # three when it fires: a variant that DROPPED them made the gate fail
        # any script reading rubotty.count(), which is the whole point of this trigger,
        # so it could never be turned on. The second empties the list instead,
        # matching what contains and recent_contains do.
        def probe_payloads(text)
          base = { "text" => text, "author" => "smoke-test", "count" => @needed, "minutes" => @minutes }
          [base.merge("matched" => needles("words")), base.merge("matched" => [])]
        end
      end

      TYPES = [Always, Contains, RecentContains, ContainsRate, RecentSenders, AuthorRepeat, NewVoice,
               Command, Recurring].freeze

      BY_NAME = TYPES.to_h { |type| [type.type_name, type] }.freeze

      # Where a script's second and later triggers are stored: a row has one
      # trigger_type column and one trigger_config column, so extras ride
      # inside the config under a key no trigger reads, rather than a schema
      # migration for a handful of short strings. A row written before this
      # existed has no such key and builds exactly the one trigger it always did.
      EXTRA_KEY = "triggers"

      # How many a script may carry. Every one is folded in on every message,
      # so this bounds per-message work rather than ambition: four covers a
      # command, some free text, a timer, and one more.
      MAX = 4

      module_function

      # +clock+ is positional on purpose. As a keyword it made Ruby read a
      # trailing config hash as keyword arguments instead, so every existing
      # build(type, "window" => 2) call started raising "unknown keyword".
      def build(type, config = {}, clock = nil)
        klass = BY_NAME[type.to_s]
        raise Failed, "no trigger type called #{type.to_s.inspect}" if klass.nil?

        trigger = klass.new(config, clock)
        trigger.check!
        trigger
      end

      # Every trigger one stored row declares, in the order they will be
      # tried. A script used to have exactly one, forcing anything that needed
      # a command AND free text AND a clock to be three scripts unable to
      # share memos, since those are scoped per script.
      def build_all(type, config = {}, clock = nil)
        declared(type, config).map { |name, own| build(name, own, clock) }
      end

      # The [type, config] pairs a row declares, without building anything,
      # for a caller that only wants to know what is there. An extra is
      # written either as a bare type name, sharing the primary's settings, or
      # as a table carrying its own that merges over the shared ones, which is
      # what lets "also run on edits" be ticked once for the whole script.
      def declared(type, config = {})
        shared = stringify(config)
        extra = Array(shared.delete(EXTRA_KEY))
        if extra.length + 1 > MAX
          raise Failed, "a script may carry #{MAX} triggers, and this one declares #{extra.length + 1}"
        end

        [[type.to_s, shared], *extra.filter_map { |entry| pair(entry, shared) }]
      end

      # One extra entry as a [type, config] pair, or nil for something too
      # malformed to be a trigger at all. A blank entry is dropped rather than
      # refused: the form can produce one, and an empty row in a list is
      # somebody who changed their mind rather than an error worth a red box.
      def pair(entry, shared)
        return [entry.to_s, shared] if entry.is_a?(String) && !entry.strip.empty?
        return nil unless entry.is_a?(Hash)

        own = stringify(entry)
        name = own.delete("type").to_s
        name.empty? ? nil : [name, shared.merge(own)]
      end

      def stringify(config)
        (config || {}).each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def type_names = BY_NAME.keys
    end
  end
end
