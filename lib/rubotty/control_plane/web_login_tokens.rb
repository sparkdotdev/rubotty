# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"
require "time"

module Rubotty
  module ControlPlane
    # The bot-DM to web-dashboard login handoff: an operator DMs
    # `/web-login`, {OperatorConsole} resolves them and calls {#issue}, which
    # mints a short-lived token and hands back the URL the dashboard redeems
    # it at. {#issue} mints a high-entropy raw token and returns it ONCE,
    # since the store keeps only its SHA-256 digest; it also refuses a second
    # token for a sender whose existing one is still active, until that one
    # expires or is revoked. A token can carry operator, viewer and
    # administrator access independently, and optionally burns on first use.
    class WebLoginTokens
      TOKEN_BYTES = 32
      DEFAULT_TTL = 3600

      # What a link carrying the administrator role gets instead: ten minutes,
      # because that link is total control of the deployment sitting in a chat
      # message, and the person who sent `web-login` is looking at their DMs
      # right now. Long enough to notice the reply and open it, short enough
      # that a chat log read later is worth nothing. Asking again costs one DM.
      ADMINISTRATOR_TTL = 600

      TOKEN_PREFIX = "web_login:token"
      ACTIVE_PREFIX = "web_login:active"
      INDEX_KEY = "web_login:index"
      INDEX_LOCK = "web_login_index"
      LOCAL_TOKEN_LOCK = Mutex.new

      # The result of {#issue}.
      #
      # @!attribute status
      #   @return [Symbol] :issued or :rate_limited
      Issued = Struct.new(:status, :token, :expires_at, keyword_init: true) do
        def ok? = status == :issued
      end

      # The result of {#redeem}.
      #
      # @!attribute status
      #   @return [Symbol] :ok or :invalid; unknown, malformed, expired and
      #     revoked tokens all read as :invalid alike.
      # @!attribute administrator
      #   @return [Boolean] a claim, not a grant: the roster is re-checked at
      #     redemption, so a revoked administrator's link opens nothing.
      Redeemed = Struct.new(:status, :community_ids, :operator, :viewer, :viewer_communities,
                            :administrator, :token_id, :expires_at, keyword_init: true) do
        def ok? = status == :ok
      end

      # The result of {#preview}: what a live token says about itself, with
      # nothing spent. :invalid covers unknown, malformed, expired and revoked
      # alike, the same as {#redeem}.
      Previewed = Struct.new(:status, :operator, :expires_at, :single_use, :community_ids, :viewer,
                             :viewer_communities, :administrator, keyword_init: true) do
        def ok? = status == :ok
      end

      # @param store [#get_state, #put_state] the key/value state store (the
      #   message map's `bridge_state` table in production)
      # @param ttl [Integer] token lifetime in seconds
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(store:, ttl: DEFAULT_TTL, logger: nil, clock: -> { Time.now })
        @store = store
        @ttl = ttl
        @logger = logger
        @clock = clock
      end

      # Mint a token for one resolved operator identity.
      #
      # @param administrator [Boolean] whether the sender administers the
      #   deployment. Shortens the token's life to {ADMINISTRATOR_TTL}, since
      #   this is the heaviest thing a link can carry.
      # @param single_use [Boolean] burns on first redemption when true; off by
      #   default, for a link fetched by the person who asked for it.
      # @return [Issued]
      def issue(identity_key:, operator:, communities:, viewer: false, viewer_communities: [],
                administrator: false, single_use: false)
        return Issued.new(status: :rate_limited) if active?(identity_key)

        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        digest = self.class.digest(token)
        now = @clock.call
        expires_at = now + ttl_for(administrator == true)
        community_ids = communities.map { |c| c[:id] || c["id"] }
        payload = {
          "operator" => operator,
          "community_ids" => community_ids,
          "communities" => communities,
          # Strict true, so anything else a caller passes stores as no viewer
          # status rather than as something truthy.
          "viewer" => viewer == true,
          "viewer_communities" => Array(viewer_communities),
          # Strict true for the same reason, and a token stored before this key
          # existed carries none of it, which reads as no administrator claim.
          "administrator" => administrator == true,
          # Strict true again: a token stored before this existed carries no key
          # at all, and that has to read as the repeatable behaviour it had.
          "single_use" => single_use == true,
          # #getutc, NOT #utc: the latter mutates its receiver, and `now` and
          # `expires_at` are reused just below as the store's own expires_at.
          "issued_at" => now.getutc.iso8601,
          "expires_at" => expires_at.getutc.iso8601,
          "revoked" => false
        }
        @store.put_state(token_key(digest), JSON.generate(payload), expires_at: expires_at)
        @store.put_state(active_key(identity_key), digest, expires_at: expires_at)
        remember(digest)
        @logger&.info do
          "web-login token issued: #{describe(operator)} communities=#{community_ids.join(",")} " \
            "viewer=#{viewer == true} administrator=#{administrator == true}"
        end
        Issued.new(status: :issued, token: token, expires_at: expires_at)
      end

      # Redeem a presented raw token: live only while it exists, is not expired
      # and has not been revoked. Deliberately repeatable, so a preview-fetch
      # redemption never locks the operator out of their own link.
      #
      # @param token [String, nil]
      # @return [Redeemed]
      def redeem(token:)
        digest = self.class.digest(token)
        return Redeemed.new(status: :invalid) if digest.nil?
        # Unknown public input must not allocate a persistent named lock. This
        # is only a preflight; the authoritative read remains inside the lock.
        return Redeemed.new(status: :invalid) if load(digest).nil?

        with_token_lock(digest) do
          payload = load(digest)
          return Redeemed.new(status: :invalid) if payload.nil? || payload["revoked"]

          burn(digest, payload) if payload["single_use"]
          @logger&.info { "web-login token redeemed: #{describe(payload["operator"])}" }
          Redeemed.new(
            status: :ok, community_ids: payload["community_ids"], operator: payload["operator"],
            token_id: digest, expires_at: to_time(payload["expires_at"]),
            viewer: payload["viewer"] == true,
            viewer_communities: Array(payload["viewer_communities"]),
            administrator: payload["administrator"] == true
          )
        end
      end

      # Resolve a signed-in browser against the server-side grant on every
      # request. A consumed single-use link still authorizes its first session,
      # but an explicit revocation or expiry ends that session too.
      def session_claims(id:)
        return Redeemed.new(status: :invalid) unless id.to_s.match?(/\A[0-9a-f]{64}\z/)

        payload = load(id)
        return Redeemed.new(status: :invalid) if payload.nil? || payload["session_revoked"]
        return Redeemed.new(status: :invalid) if payload["revoked"] && !payload["consumed"]

        Redeemed.new(
          status: :ok, token_id: id, expires_at: to_time(payload["expires_at"]),
          community_ids: payload["community_ids"], operator: payload["operator"],
          viewer: payload["viewer"] == true, viewer_communities: Array(payload["viewer_communities"]),
          administrator: payload["administrator"] == true
        )
      end

      # Reads a live token without spending it: who it would sign in and
      # when it stops working, for a confirmation page to name the session
      # it is about to open. Spends nothing, so it is safe on a GET, which
      # is what lets the sign-in link survive a platform's link preview even
      # when it is single use.
      #
      # @param token [String, nil]
      # @return [Previewed]
      def preview(token:)
        digest = self.class.digest(token)
        return Previewed.new(status: :invalid) if digest.nil?

        payload = load(digest)
        return Previewed.new(status: :invalid) if payload.nil? || payload["revoked"]

        Previewed.new(
          status: :ok, operator: payload["operator"], expires_at: to_time(payload["expires_at"]),
          single_use: payload["single_use"] == true, community_ids: payload["community_ids"],
          viewer: payload["viewer"] == true, viewer_communities: Array(payload["viewer_communities"]),
          administrator: payload["administrator"] == true
        )
      end

      # The currently active (unrevoked, unexpired) tokens, most recently issued
      # first, for the admin revoke view. Lazily prunes the index of any entry that
      # has since expired or been revoked, so the list stays accurate.
      #
      # @return [Array<Hash>] { id:, operator:, communities:, viewer:, issued_at:, expires_at: }
      def active_tokens
        digests = index
        live = []
        stale = []
        digests.each do |digest|
          payload = load(digest)
          if payload.nil? || payload["revoked"]
            stale << digest
            next
          end
          live << {
            id: digest, operator: payload["operator"], communities: payload["communities"],
            viewer: payload["viewer"] == true, administrator: payload["administrator"] == true,
            issued_at: payload["issued_at"], expires_at: payload["expires_at"]
          }
        end
        # Re-read inside the lock: digests is from before the scan, and a token
        # issued during it must not be pruned as though it were never there.
        with_index_lock { save_index(index - stale) } unless stale.empty?
        live.reverse
      end

      # Revoke one active token by the opaque id {#active_tokens} exposes: its
      # digest, never the raw token. Idempotent, and frees the sender's rate
      # limit at once.
      #
      # @param id [String]
      # @return [Boolean] whether a live token was revoked
      def revoke(id:)
        digest = id.to_s
        return false unless digest.match?(/\A[0-9a-f]{64}\z/)
        return false if load(digest).nil?

        with_token_lock(digest) do
          payload = load(digest)
          return false if payload.nil? || payload["session_revoked"]
          return false if payload["revoked"] && !payload["consumed"]

          payload["revoked"] = true
          payload["session_revoked"] = true
          payload["revoked_at"] = @clock.call.getutc.iso8601
          @store.put_state(token_key(digest), JSON.generate(payload), expires_at: to_time(payload["expires_at"]))
          forget(digest)
          @logger&.info { "web-login token revoked: #{describe(payload["operator"])}" }
          true
        end
      end

      # SHA-256 hex digest of a raw token, or nil for a blank one.
      def self.digest(token)
        string = token.to_s
        return nil if string.empty?

        Digest::SHA256.hexdigest(string)
      end

      private

      # Production datastores share the lock across service instances. The
      # process-local fallback keeps simple in-memory stores atomic too.
      def with_token_lock(digest, &block)
        return LOCAL_TOKEN_LOCK.synchronize(&block) unless @store.respond_to?(:with_advisory_lock)

        @store.with_advisory_lock("web_login_token:#{digest}", &block)
      end

      # How long this token lives. An administrator's link takes the shorter of
      # the two, so a deployment that configured something tighter than ten
      # minutes keeps what it configured.
      def ttl_for(administrator)
        administrator ? [@ttl, ADMINISTRATOR_TTL].min : @ttl
      end

      # Spend a single-use token on its first successful redemption, through the
      # same revocation an administrator would take, so it also leaves the
      # active list and frees the sender's rate limit at once.
      def burn(digest, payload)
        payload["revoked"] = true
        payload["consumed"] = true
        payload["revoked_at"] = @clock.call.getutc.iso8601
        @store.put_state(token_key(digest), JSON.generate(payload), expires_at: to_time(payload["expires_at"]))
        forget(digest)
      end

      # Whether the sender already holds a token that is issued, unrevoked and
      # unexpired. Re-reads the token's own live state, so revoking it clears the
      # limit immediately.
      def active?(identity_key)
        digest = @store.get_state(active_key(identity_key))
        return false if digest.nil?

        payload = load(digest)
        !payload.nil? && !payload["revoked"]
      end

      def load(digest)
        raw = @store.get_state(token_key(digest))
        return nil if raw.nil?

        payload = JSON.parse(raw)
        return nil unless payload.is_a?(Hash)
        return nil if to_time(payload["expires_at"]) <= @clock.call

        payload
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def index
        raw = @store.get_state(INDEX_KEY)
        return [] if raw.nil?

        JSON.parse(raw)
      rescue JSON::ParserError
        []
      end

      # The index is one key holding a whole list, so every writer reads it,
      # changes one entry and writes it back. Losing an entry there leaves a live
      # token that active_tokens never lists and revoke can therefore never
      # reach, so the read and the write go under one lock.
      def with_index_lock(&block)
        return yield unless @store.respond_to?(:with_advisory_lock)

        @store.with_advisory_lock(INDEX_LOCK, &block)
      end

      def remember(digest)
        with_index_lock { save_index((index + [digest]).uniq) }
      end

      def forget(digest)
        with_index_lock { save_index(index - [digest]) }
      end

      # No expiry: this pointer list has to outlive any one token's TTL to be able
      # to prune it once that token is gone.
      def save_index(digests)
        @store.put_state(INDEX_KEY, JSON.generate(digests), expires_at: nil)
      end

      def token_key(digest) = "#{TOKEN_PREFIX}:#{digest}"

      def active_key(identity_key) = "#{ACTIVE_PREFIX}:#{identity_key}"

      # A log-safe one-liner for an operator hash, with the symbol keys {#issue}
      # was called with or the string keys a JSON round trip leaves it with.
      def describe(operator)
        return "unknown operator" if operator.nil?

        adapter = operator["adapter"] || operator[:adapter]
        native_id = operator["native_id"] || operator[:native_id]
        "#{adapter}:#{native_id}"
      end

      # The payload's stored ISO8601 "expires_at" back as a Time, for a re-put_state.
      def to_time(value)
        return value if value.is_a?(Time)

        Time.parse(value.to_s)
      end
    end
  end
end
