# frozen_string_literal: true

require "English"
require "etc"
require "socket"

module Rubotty
  module Core
    # Facts about this build and the machine running it.
    #
    # Nothing shells out except the git fallback for the commit, and that only in a
    # development checkout. Every lookup degrades to nil rather than raising: this
    # must never be the reason a bridge fails to start.
    module BuildInfo
      UNKNOWN = "unknown"

      # Environment variables that may carry the deployed commit, in priority
      # order. BRIDGE_COMMIT is the generic override for anything not listed.
      COMMIT_VARS = %w[
        BRIDGE_COMMIT
        SOURCE_COMMIT
        SOURCE_VERSION
        GIT_COMMIT
        GIT_REV
        COMMIT_SHA
        GITHUB_SHA
        RENDER_GIT_COMMIT
        HEROKU_SLUG_COMMIT
      ].freeze

      class << self
        def version = Rubotty::VERSION

        def service_name = Rubotty::SERVICE_NAME

        # `RUBY_DESCRIPTION` is already exactly the line we want.
        def runtime = RUBY_DESCRIPTION

        def hostname
          @hostname ||= (Socket.gethostname || UNKNOWN)
        rescue StandardError
          UNKNOWN
        end

        # The short commit this build came from. A deployed container has no .git
        # directory, so the environment is consulted first.
        def commit(env: ENV)
          @commit ||= from_env(env) || from_git || UNKNOWN
        end

        # Kernel and distribution, as one readable phrase:
        #   "Linux 7.1.4-200.fc44.x86_64, Fedora Linux 44 (Server Edition) x86_64"
        def platform
          @platform ||= begin
            uname = safe_uname
            kernel = [uname[:sysname], uname[:release]].compact.join(" ")
            parts = [kernel, distribution, uname[:machine]].compact.reject(&:empty?)
            parts.empty? ? UNKNOWN : "#{parts.first}, #{parts[1..].join(" ")}"
          end
        end

        # PRETTY_NAME from /etc/os-release. That file does not exist on macOS or
        # most BSDs, so this returns nil there and the banner omits it.
        def distribution
          return @distribution if defined?(@distribution)

          @distribution = read_os_release
        end

        # Test hook. Memoised values would otherwise leak between examples.
        def reset!
          @hostname = nil
          @commit = nil
          @platform = nil
          remove_instance_variable(:@distribution) if defined?(@distribution)
        end

        private

        def from_env(env)
          COMMIT_VARS.each do |name|
            value = env[name].to_s.strip
            next if value.empty?

            return short(value)
          end
          nil
        end

        # Only attempted in a checkout, and every failure mode ends in nil.
        def from_git
          root = File.expand_path("../../..", __dir__)
          return nil unless File.exist?(File.join(root, ".git"))

          output = IO.popen(
            ["git", "-C", root, "rev-parse", "--short", "HEAD"],
            err: File::NULL, &:read
          )
          return nil unless $CHILD_STATUS&.success?

          value = output.to_s.strip
          value.empty? ? nil : value
        rescue StandardError
          nil
        end

        def short(value) = value[0, 7]

        def safe_uname
          Etc.uname
        rescue StandardError
          {}
        end

        def read_os_release
          path = "/etc/os-release"
          return nil unless File.readable?(path)

          File.foreach(path) do |line|
            # chomp matters: File.foreach yields the trailing newline, so an
            # anchored match would never fire against the raw line.
            match = line.chomp.match(/\APRETTY_NAME=(.*)\z/)
            next if match.nil?

            return match[1].strip.delete_prefix('"').delete_suffix('"')
          end
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
