# frozen_string_literal: true

module Rubotty
  module Core
    # The startup banner, posted to endpoints the operator names. `minimal` is the
    # default because the `full` runtime and host lines disclose kernel version,
    # distribution release and hostname to anyone who can read the channel.
    class Announcement
      LEVELS = %i[minimal full].freeze

      TIME_FORMAT = "%a, %d %b %Y %H:%M:%S GMT"

      # Key under which the last announcement time is remembered, so a crash
      # looping bridge does not post on every restart.
      STATE_KEY = "announce.last_posted_at"

      # Key under which the version of the last posted announcement is
      # remembered, so a new build announces regardless of the suppress window.
      VERSION_STATE_KEY = "announce.last_posted_version"

      # @param dialects [Module, nil] answers lua_runtime and version, injected
      #   so a test does not shell out. nil drops the Lua line entirely, which is
      #   what a build with no scripting support should show.
      def initialize(level: :minimal, info: BuildInfo, dialects: Scripting::Dialects, clock: -> { Time.now })
        @level = LEVELS.include?(level.to_sym) ? level.to_sym : :minimal
        @info = info
        @dialects = dialects
        @clock = clock
      end

      attr_reader :level

      # @return [String] the banner, already formatted for a plain text channel
      def text
        lines = [started_line, version_line]
        lines.concat([runtime_line, lua_line, host_line]) if @level == :full
        lines.compact.join("\n")
      end

      # @return [RichText] the banner as canonical rich text
      def body
        RichText.plain(text)
      end

      def started_line
        "Started #{@info.service_name} at #{@clock.call.utc.strftime(TIME_FORMAT)}."
      end

      def version_line
        commit = @info.commit
        suffix = commit == BuildInfo::UNKNOWN ? "" : " (#{commit})"
        "#{@info.service_name} version: #{@info.version}#{suffix}"
      end

      def runtime_line
        "ruby runtime: #{@info.runtime}"
      end

      # Omitted rather than shown empty when no interpreter is on PATH: a
      # build without one cannot run a script at all, so leaving the line
      # out says that on its own.
      def lua_line
        return nil if @dialects.nil?

        runtime = @dialects.lua_runtime
        return nil if runtime.nil?

        "lua runtime: #{runtime}#{dialect_suffix}"
      end

      # Only the transpiled dialects are listed. Lua itself is the runtime named
      # on the line already, so repeating it there would say nothing.
      def dialect_suffix
        listed = @dialects.available.reject(&:native?).filter_map do |dialect|
          version = @dialects.version(dialect)
          version.nil? ? nil : "#{dialect.label} #{version}"
        end
        listed.empty? ? "" : " [dialects: #{listed.join(", ")}]"
      end

      def host_line
        "host: #{@info.hostname} (#{@info.platform})"
      end

      # Decides whether to post, and remembers that we did. The version is
      # persisted alongside the timestamp: a changed version always posts, an
      # unchanged one is time suppressed so a crash loop cannot spam the channel.
      class Suppressor
        # @param scope [String, nil] namespaces the persisted state so two
        #   communities restarting independently each keep their OWN suppression
        #   record. nil keeps the original global keys, which is the
        #   single-config (no control plane) path.
        def initialize(storage:, window:, version:, scope: nil, logger: nil, clock: -> { Time.now })
          @storage = storage
          @window = window.to_i
          @version = version.to_s
          @scope = scope
          @logger = logger
          @clock = clock
        end

        # @return [Boolean] true when the caller should post
        def claim
          now = @clock.call

          # A new build always announces, whatever the window: deploys land
          # inside it.
          if version_changed?
            record(now)
            return true
          end

          # Same build, so the window applies. A non positive window disables
          # suppression entirely.
          return true if @window <= 0

          last = read_time
          if last && (now - last) < @window
            @logger&.info do
              "suppressing the startup announcement, version #{@version} was posted " \
                "#{(now - last).round}s ago (window #{@window}s)"
            end
            return false
          end

          record(now)
          true
        rescue StorageError => e
          # A duplicate banner is a far smaller problem than a bridge that will
          # not start, so an unreadable state posts.
          @logger&.warn { "could not read announcement state: #{e.message}" }
          true
        end

        private

        # True when no announcement has ever been recorded, or the last one was
        # for a different build.
        def version_changed?
          last = read_version
          last.nil? || last != @version
        end

        # The state keys, namespaced by +scope+ when one is set. A nil scope
        # yields the original bare constants.
        def time_key = @scope ? "#{STATE_KEY}.#{@scope}" : STATE_KEY

        def version_key = @scope ? "#{VERSION_STATE_KEY}.#{@scope}" : VERSION_STATE_KEY

        def read_time
          raw = @storage.get_state(time_key)
          return nil if raw.nil? || raw.to_s.empty?

          Time.at(raw.to_i)
        rescue ArgumentError, TypeError
          nil
        end

        def read_version
          raw = @storage.get_state(version_key)
          return nil if raw.nil?

          string = raw.to_s
          string.empty? ? nil : string
        end

        def record(now)
          # Kept a little beyond the window so the row is not reaped mid window.
          expires_at = @window.positive? ? now + (@window * 2) : now + 3600
          @storage.put_state(time_key, now.to_i.to_s, expires_at: expires_at)
          @storage.put_state(version_key, @version, expires_at: expires_at)
        end
      end
    end
  end
end
