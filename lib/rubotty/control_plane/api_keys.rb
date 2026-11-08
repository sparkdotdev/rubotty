# frozen_string_literal: true

require "securerandom"
require "digest"

module Rubotty
  module ControlPlane
    # Issue, authenticate, list and revoke REST API keys: the only place a key
    # token is minted or checked. A "developer" key belongs to one community and
    # an "administrator" key is global; {#issue} refuses either mismatched with
    # its scope, before a row is written. The raw token is returned ONCE, at
    # {#issue}; only its SHA-256 digest is stored, so a table dump cannot
    # reconstruct a working token. A key authenticates only while LIVE (issued,
    # not revoked, no expiry of its own); public_id is a separate, non-secret
    # identifier used to address a key from the dashboard.
    class ApiKeys
      # Raised for a request that cannot be carried out (an unknown scope, a
      # scope/community mismatch, a blank label). The message is printed as-is.
      class Invalid < Rubotty::Error; end

      # Bytes of entropy in a raw token, matching {GuestInvites::TOKEN_BYTES}.
      TOKEN_BYTES = 32

      SCOPE_DEVELOPER = "developer"
      SCOPE_ADMINISTRATOR = "administrator"
      SCOPES = [SCOPE_DEVELOPER, SCOPE_ADMINISTRATOR].freeze

      LABEL_MAX = 200
      CREATED_BY_MAX = 200

      # A newly issued key plus the ONE-TIME raw token, which is never
      # recoverable afterwards.
      Issued = Struct.new(:key_row, :token, keyword_init: true)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      PLATFORM_ACCOUNT_MAX = 64

      # Mint a new API key.
      #
      # @param scope [String, Symbol] "developer" or "administrator"
      # @param community [Models::Community, nil] required for a developer key,
      #   nil for an administrator key
      # @param platform_account [String, nil] narrows a developer key to one
      #   api_wrapper account rather than the whole community
      # @return [Issued] the row and the one-time raw token
      def issue(scope:, community: nil, label:, created_by: nil, platform_account: nil)
        scope_value = scope.to_s
        raise Invalid, "scope must be one of #{SCOPES.join(", ")}." unless SCOPES.include?(scope_value)

        if scope_value == SCOPE_ADMINISTRATOR
          raise Invalid, "an administrator key cannot be scoped to a community." unless community.nil?
          raise Invalid, "a platform-account key must be scoped to a community." unless platform_account.nil?
        elsif community.nil?
          raise Invalid, "a developer key needs a community."
        end

        label_value = label.to_s.strip
        raise Invalid, "an API key needs a label." if label_value.empty?

        account_value = presence(platform_account)&.[](0, PLATFORM_ACCOUNT_MAX)

        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        now = @clock.call
        row = @models.api_key.create(
          public_id: SecureRandom.uuid,
          key_hash: self.class.hash_token(token),
          scope: scope_value,
          community_id: community&.id,
          label: label_value[0, LABEL_MAX],
          created_by: created_by&.to_s&.[](0, CREATED_BY_MAX),
          platform_account: account_value,
          created_at: now,
          updated_at: now
        )
        @logger&.info do
          "api key issued: public_id=#{row.public_id} scope=#{scope_value} " \
            "community=#{community&.slug || "(global)"} label=#{label_value.inspect} " \
            "platform_account=#{account_value.inspect}"
        end
        Issued.new(key_row: row, token: token)
      end

      # The live API key a raw token names, or nil.
      #
      # An unknown token and a revoked one are indistinguishable: a caller
      # presenting a dead token learns only that it does not work.
      #
      # @param token [String, nil]
      # @return [Models::ApiKey, nil]
      def authenticate(token:)
        digest = self.class.hash_token(token)
        return nil if digest.nil?

        # The liveness bound is applied in SQL, so it is right on every backend.
        @models.api_key.where(key_hash: digest, revoked_at: nil).first
      end

      # Every API key, newest first, optionally scoped to one community.
      # +community: nil+ lists every key, administrator keys included.
      #
      # @param community [Models::Community, nil]
      def list(community: nil)
        dataset = @models.api_key.reverse(:id)
        dataset = dataset.where(community_id: community.id) unless community.nil?
        dataset.all
      end

      # Revoke a key by its public_id, or nil when there is no such key.
      # Idempotent: an already-revoked key keeps its original revoked_at.
      #
      # @param public_id [String]
      # @return [Models::ApiKey, nil]
      def revoke_by_public_id(public_id:)
        row = @models.api_key.where(public_id: public_id.to_s).first
        return nil if row.nil?
        return row unless row.revoked_at.nil?

        row.update(revoked_at: @clock.call, updated_at: @clock.call)
        @logger&.info { "api key revoked: public_id=#{row.public_id}" }
        row
      end

      # Stamp last_used_at on an authenticated key, once per authenticated
      # request. Not called from anywhere in this file.
      #
      # @param key [Models::ApiKey]
      # @return [Models::ApiKey]
      def touch_last_used(key)
        key.update(last_used_at: @clock.call)
        key
      end

      # SHA-256 hex digest of a raw token, or nil for a blank token. The digest is
      # what the row stores and what authentication matches, so a leak of the
      # table never yields a usable key.
      def self.hash_token(token)
        string = token.to_s
        return nil if string.empty?

        Digest::SHA256.hexdigest(string)
      end

      private

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
