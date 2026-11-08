# frozen_string_literal: true

module Rubotty
  module Dashboard
    # Both processes' recent log lines, as one list. The web process reads its
    # own {RingBuffer} directly; the bot's come back over the same internal hop
    # the deploy-drift header already makes. One reader behind both the ERB
    # route and the themed surface, so the two cannot drift on what
    # "source=all" means.
    #
    # A source that cannot be read is reported under "errors", never silently
    # as a process that logged nothing.
    class DebugLogs
      SOURCES = %w[web bot all].freeze
      DEFAULT_SOURCE = "web"
      DEFAULT_LIMIT = 200
      # The web buffer holds 500 lines and the bot's is asked for the same, so
      # a larger ceiling would only promise lines neither process still has.
      MAX_LIMIT = 500

      class << self
        # Each reads one query parameter, falling back rather than refusing:
        # this page is somewhere to look at a fault, not somewhere to be told
        # off for mistyping a filter.
        def source_of(raw) = SOURCES.include?(raw.to_s) ? raw.to_s : DEFAULT_SOURCE

        def level_of(raw)
          level = raw.to_s.downcase
          Log::LEVELS.key?(level) ? level : nil
        end

        def limit_of(raw)
          limit = raw.to_i
          return DEFAULT_LIMIT unless limit.positive?

          [limit, MAX_LIMIT].min
        end
      end

      # @param log_buffer [RingBuffer, nil] this process's own lines; nil reads
      #   as "not configured" rather than as a process that logged nothing
      # @param bot_logs [Api::BotLogsClient, nil] the hop to the bot process
      def initialize(log_buffer: nil, bot_logs: nil)
        @log_buffer = log_buffer
        @bot_logs = bot_logs
      end

      # @return [Hash] "entries" oldest first, "errors" by source
      def fetch(source: DEFAULT_SOURCE, level: nil, limit: DEFAULT_LIMIT)
        entries = []
        errors = {}
        read_web(level, limit, entries, errors) if %w[web all].include?(source)
        read_bot(level, limit, entries, errors) if %w[bot all].include?(source)
        # Merged into ONE time-ordered list so a reader sees what happened in
        # order, then trimmed again: two sources of `limit` lines are twice that.
        entries.sort_by! { |entry| entry["time"].to_s }
        entries = entries.last(limit) if source == "all"
        { "entries" => entries, "errors" => errors }
      end

      private

      def read_web(level, limit, entries, errors)
        return errors["web"] = "this process has no log buffer configured" if @log_buffer.nil?

        entries.concat(@log_buffer.entries(level: level, limit: limit).map { |row| entry(row, "web") })
      end

      def read_bot(level, limit, entries, errors)
        return errors["bot"] = "no internal URL and secret are configured for the bot" if @bot_logs.nil?

        result = @bot_logs.fetch(level: level, limit: limit)
        return errors["bot"] = result.error unless result.ok?

        entries.concat(result.entries.map { |row| entry(row, "bot") })
      end

      # The web buffer answers symbol keys and the bot hop string ones, since
      # the latter has been through YAML.
      def entry(row, source)
        time = row[:time] || row["time"]
        {
          "source" => source,
          "time" => time.respond_to?(:utc) ? time.utc.iso8601 : time,
          "level" => row[:level] || row["level"],
          "text" => row[:text] || row["text"]
        }
      end
    end
  end
end
