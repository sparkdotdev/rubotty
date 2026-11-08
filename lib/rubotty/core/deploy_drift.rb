# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Rubotty
  module Core
    # Whether what this process is running still matches the head of the default
    # branch, and whether the bot process agrees with it.
    #
    # A merge that never deployed leaves no trace anywhere: the queue is empty,
    # the container is healthy, and the only symptom is a version that stopped
    # moving. Every lookup here degrades to silence rather than raising, since a
    # header that cannot render is worse than one that cannot check.
    class DeployDrift
      # A deploy takes several minutes, so a difference is only reported once it
      # has lasted this long. Without it every merge would warn on the way out.
      DEFAULT_GRACE = 900
      # How long one answer is reused. One outbound request per window, however
      # many pages are rendered inside it.
      DEFAULT_TTL = 300
      # Short, because this runs inline in a page render.
      REQUEST_TIMEOUT = 3
      # GitHub's commits endpoint answers with a bare sha under this Accept,
      # which is the shape a CI-published file already has.
      SHA_ACCEPT = "application/vnd.github.sha"
      SHA = /\A[0-9a-f]{7,40}\z/

      # @param head_url [String, nil] a URL answering with the head commit of the
      #   default branch, bare sha or GitHub's commit JSON. Nil turns the
      #   upstream comparison off, the default.
      # @param bot_info [#call, nil] returns the bot process's own facts, the hash
      #   {Api::BotLogsClient#fetch_info} answers with. Nil turns the process
      #   comparison off.
      # @param grace [Numeric] seconds a difference must last before it is reported
      # @param ttl [Numeric] seconds one answer is cached for
      def initialize(head_url: nil, token: nil, bot_info: nil, version: Rubotty::VERSION,
                     commit: nil, grace: DEFAULT_GRACE, ttl: DEFAULT_TTL, logger: nil,
                     clock: -> { Time.now })
        @head_url = presence(head_url)
        @token = presence(token)
        @bot_info = bot_info
        @version = version.to_s
        @commit = presence(commit)
        @grace = grace.to_i
        @ttl = ttl.to_i
        @logger = logger
        @clock = clock
        @lock = Mutex.new
        @warnings = []
        @checked_at = nil
        @head_seen = nil
        @head_since = nil
        @pair_seen = nil
        @pair_since = nil
      end

      # Whether anything is configured for this to compare at all.
      def configured? = !@head_url.nil? || !@bot_info.nil?

      # Short sentences an operator can act on, empty when everything agrees,
      # when a difference is still inside its grace period, or when nothing
      # could be checked.
      #
      # @return [Array<String>]
      def warnings
        @lock.synchronize do
          now = @clock.call
          if @checked_at.nil? || (now - @checked_at) >= @ttl
            @checked_at = now
            @warnings = []
            @warnings = build(now)
          end
          @warnings
        end
      rescue StandardError => e
        @logger&.debug { "deploy drift check failed: #{e.class}: #{e.message}" }
        []
      end

      private

      def build(now)
        [upstream_warning(now), process_warning(now)].compact
      end

      # This deployment against the head of the default branch.
      def upstream_warning(now)
        return nil if @head_url.nil? || @commit.nil? || @commit == BuildInfo::UNKNOWN

        head = fetch_head
        if head.nil? || same_commit?(head, @commit)
          @head_since = nil
          @head_seen = nil
          return nil
        end

        @head_since = now if @head_seen != head
        @head_seen = head
        return nil if (now - @head_since) < @grace

        "main is at #{short(head)} and this deployment is still running #{short(@commit)}, " \
          "so the last merge never went out"
      end

      # This deployment against the bot process, which deploys separately and so
      # can be a version behind or ahead of the web process on its own.
      def process_warning(now)
        info = bot_facts
        theirs = info ? presence(info["version"]) : nil
        if theirs.nil? || theirs == @version
          @pair_since = nil
          @pair_seen = nil
          return nil
        end

        @pair_since = now if @pair_seen != theirs
        @pair_seen = theirs
        return nil if (now - @pair_since) < @grace

        "the bot process is running #{theirs} and this one is running #{@version}, " \
          "so only one of the two deployed"
      end

      # The bot's own facts, or nil when there is nothing to ask or the answer
      # says it could not be reached.
      def bot_facts
        return nil if @bot_info.nil?

        info = @bot_info.call
        return nil unless info.is_a?(Hash) && info["reachable"]

        info
      rescue StandardError => e
        @logger&.debug { "could not read the bot process's build facts: #{e.class}: #{e.message}" }
        nil
      end

      # The head commit the upstream reports, or nil when it could not be read.
      def fetch_head
        uri = URI.parse(@head_url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: REQUEST_TIMEOUT, read_timeout: REQUEST_TIMEOUT) do |http|
          request = Net::HTTP::Get.new(uri)
          request["Accept"] = SHA_ACCEPT
          request["User-Agent"] = "#{Rubotty::SERVICE_NAME}/#{@version}"
          request["Authorization"] = "Bearer #{@token}" if @token
          http.request(request)
        end
        return nil unless response.is_a?(Net::HTTPSuccess)

        parse_head(response.body.to_s)
      rescue StandardError => e
        @logger&.debug { "could not read the head of the default branch: #{e.class}: #{e.message}" }
        nil
      end

      # A bare sha, or the "sha" key of GitHub's commit JSON for an upstream that
      # ignored the Accept header.
      def parse_head(body)
        text = body.strip
        return text.downcase if text.downcase.match?(SHA)
        return nil unless text.start_with?("{")

        sha = JSON.parse(text)["sha"].to_s.strip.downcase
        sha.match?(SHA) ? sha : nil
      rescue StandardError
        nil
      end

      # One side is often the 7 characters a banner shows and the other the full
      # 40, so they are compared over the length they have in common.
      def same_commit?(one, other)
        length = [one.length, other.length].min
        length.positive? && one[0, length].casecmp?(other[0, length])
      end

      def short(sha) = sha[0, 7]

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
