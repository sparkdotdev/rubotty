# frozen_string_literal: true

require "uri"

module Rubotty
  module ControlPlane
    # Create, edit, list and remove a community's Fluxer instances (the write
    # side of the fluxer_instances table). Fluxer is self-hostable, so a
    # community may run the flagship instance AND any number of self-hosted
    # ones at once, unlike Telegram/Discord's one shared token. Flagship is
    # API key only (endpoint_url stays NULL); {#validated} requires it for
    # self_hosted. Nothing downstream reads this table at boot yet: a write
    # here only records an operator's intent on the dashboard, it does not
    # yet change what the bot connects to.
    class FluxerInstances
      # Raised for a request that cannot be carried out (a blank label, a
      # self-hosted instance with no usable endpoint_url, a duplicate label).
      class Invalid < Rubotty::Error; end

      # The two connection kinds fluxer_instances.kind accepts. Plain strings on
      # the row, for cross-backend portability.
      KINDS = %w[flagship self_hosted].freeze

      # DB column size limits (migration 014), enforced here because SQLite would
      # silently accept an overlong value and Postgres would refuse it.
      LABEL_MAX = 200
      API_KEY_ENV_MAX = 128

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # The {Config::Schema} one instance's submitted fields are validated and
      # coerced through. Rebuilt per call rather than memoised, so there is no
      # shared schema object a caller could accidentally mutate.
      def self.schema
        Config::Schema.define do
          field :label, :string, required: true,
                                 desc: "community-chosen name for this instance, e.g. 'Flagship', " \
                                       "'Our self-hosted server'"
          field :kind, :symbol, default: :self_hosted, one_of: KINDS.map(&:to_sym),
                                desc: "'flagship' connects to the flagship Fluxer instance, API key only. " \
                                      "'self_hosted' additionally needs endpoint_url"
          field :endpoint_url, :string,
                              desc: "the self-hosted server's API base URL. Required, and only used, when " \
                                    "kind is 'self_hosted'; a flagship instance connects through the " \
                                    "adapter's built-in default"
          field :api_key_env, :string, required: true, env: true,
                                       desc: "name of the environment variable holding this instance's API " \
                                             "key. Never the raw key itself"
        end
      end

      # Every Fluxer instance for a community, flagship first then self-hosted
      # alphabetically by label, for the Platforms page listing.
      def list(community:)
        @models.fluxer_instance.where(community_id: community.id).order(:kind, :label).all
      end

      # Add a new Fluxer instance to a community.
      #
      # @param kind [String, Symbol, nil] "flagship" or "self_hosted"; defaults
      #   to "self_hosted" when blank, matching the DB column's own default
      # @param endpoint_url [String, nil] required for self_hosted, ignored
      #   (cleared) for flagship
      # @return [Models::FluxerInstance]
      def create(community:, label:, kind:, endpoint_url:, api_key_env:)
        attrs = validated(label: label, kind: kind, endpoint_url: endpoint_url, api_key_env: api_key_env)
        now = @clock.call
        row = @models.fluxer_instance.create(community_id: community.id, created_at: now, updated_at: now, **attrs)
        @logger&.info do
          "fluxer instance created: community=#{community.slug} label=#{attrs[:label].inspect} kind=#{attrs[:kind]}"
        end
        row
      rescue Sequel::UniqueConstraintViolation
        raise Invalid, "a Fluxer instance labeled #{label.to_s.inspect} already exists for this community."
      end

      # Edit an existing Fluxer instance's label, kind, endpoint and key env var.
      #
      # @param instance [Models::FluxerInstance]
      # @return [Models::FluxerInstance]
      def update(instance:, label:, kind:, endpoint_url:, api_key_env:)
        attrs = validated(label: label, kind: kind, endpoint_url: endpoint_url, api_key_env: api_key_env)
        instance.update(updated_at: @clock.call, **attrs)
        @logger&.info do
          "fluxer instance updated: id=#{instance.id} label=#{attrs[:label].inspect} kind=#{attrs[:kind]}"
        end
        instance
      rescue Sequel::UniqueConstraintViolation
        raise Invalid, "a Fluxer instance labeled #{label.to_s.inspect} already exists for this community."
      end

      # Remove a Fluxer instance by id, scoped to a community (so a caller
      # cannot remove another community's row by guessing an id).
      #
      # @return [Boolean] whether a row was actually removed
      def remove(community:, id:)
        instance = @models.fluxer_instance.where(community_id: community.id, id: id).first
        return false if instance.nil?

        instance.destroy
        @logger&.info { "fluxer instance removed: id=#{id}" }
        true
      end

      private

      # Validate and coerce one instance's submitted fields, raising {Invalid}
      # with every problem found in one pass, matching {Config::Loader}.
      #
      # @return [Hash] the DB-ready attrs: label, kind (String), endpoint_url,
      #   api_key_env
      def validated(label:, kind:, endpoint_url:, api_key_env:)
        result = self.class.schema.call(
          { label: label, kind: kind, endpoint_url: endpoint_url, api_key_env: api_key_env },
          path: "fluxer_instance"
        )
        value = result.value || {}
        problems = result.problems.dup

        # Config::Schema's `required` check only catches an ABSENT or nil field; a
        # form submits a present but blank string for an empty input, which needs
        # its own check, guarded so it is never reported as "required" twice.
        if value.key?(:label) && value[:label].to_s.strip.empty?
          problems << "fluxer_instance.label: is required"
        end
        if value.key?(:api_key_env) && value[:api_key_env].to_s.strip.empty?
          problems << "fluxer_instance.api_key_env: is required"
        end

        if value[:kind] == :self_hosted
          unless looks_like_url?(value[:endpoint_url])
            problems << "fluxer_instance.endpoint_url: a self-hosted instance needs a valid http(s) endpoint " \
                        "URL, got #{value[:endpoint_url].inspect}"
          end
        else
          # A flagship instance connects through the adapter's built-in default:
          # drop any endpoint_url submitted alongside it rather than keep stale
          # data around from an earlier self-hosted edit.
          value[:endpoint_url] = nil
        end

        raise Invalid, problems.join("; ") if problems.any?

        {
          label: value[:label].to_s.strip[0, LABEL_MAX],
          kind: value[:kind].to_s,
          endpoint_url: value[:endpoint_url],
          api_key_env: value[:api_key_env].to_s.strip[0, API_KEY_ENV_MAX]
        }
      end

      # Whether +value+ parses as an absolute http/https URL with a host.
      # Deliberately loose beyond that: a self-hosted server may run on a bare
      # IP, a nonstandard port or a path prefix.
      def looks_like_url?(value)
        return false if value.to_s.strip.empty?

        uri = URI.parse(value)
        uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
