# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # Create, edit, list, and remove a community's platform connections, and
    # validate and persist the per-account behaviour settings layered on one.
    # A platform connection is one credentialed presence of the shared bot in
    # one community space (adapter, shared-token account, platform's own
    # coarse space id); getting its address wrong breaks the routing lookup a
    # live event depends on, so identity edits are refused for a protected
    # community. Writing to platform_connections.settings records an
    # operator's intent, but nothing downstream reads it at boot yet.
    class PlatformConnections
      # Raised with a human-readable message a caller prints as-is.
      class Invalid < Rubotty::Error; end

      # The adapters a platform connection may declare, closed so a typo cannot
      # silently create an unroutable connection. Deliberately not
      # Adapters::Registry.names, which also carries the internal :guest adapter.
      KNOWN_ADAPTERS = %w[telegram discord stoat matrix xmpp irc fluxer api_wrapper].freeze

      # The per-account fields each adapter exposes as an editable behaviour
      # setting. Curated, because most of an account_schema is transport plumbing
      # that belongs in bridge.config.yaml.
      BEHAVIOR_FIELDS = {
        telegram: %i[reaction_policy cross_delete_on_discord album_window],
        discord: %i[max_upload_bytes]
      }.freeze

      # @param registry [Registry, nil] reloaded after a write, so a running bot's
      #   Snapshot is swapped immediately instead of waiting on the change
      #   detector's poll. Nil in the dashboard.
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
      end

      # Every platform connection for a community, adapter then account.
      #
      # @return [Array<Models::PlatformConnection>]
      def list(community:)
        @models.platform_connection.where(community_id: community.id).order(:adapter, :account).all
      end

      # Add a brand new platform connection to a community, the only way to onboard
      # a platform the initial config seed never declared. Discovery only ATTACHES
      # channels to an existing connection, so the next bulk sync finds this row.
      #
      # @return [Models::PlatformConnection]
      # @raise [Invalid] an unknown adapter, a blank account or external id, or a
      #   (adapter, account, external_id) already in use
      def create(community:, adapter:, account:, external_id:, label: nil)
        adapter = presence(adapter)
        account = presence(account)
        external_id = presence(external_id)
        validate_adapter!(adapter)
        raise Invalid, "Account and external id are both required." if account.nil? || external_id.nil?

        now = @clock.call
        row = @models.platform_connection.create(
          community_id: community.id, adapter: adapter, account: account, external_id: external_id,
          label: presence(label), created_at: now, updated_at: now
        )
        reload
        @logger&.info do
          "platform connection created: community=#{community.slug} adapter=#{adapter} account=#{account}"
        end
        row
      rescue Sequel::UniqueConstraintViolation
        raise Invalid, "A connection for #{adapter}/#{account}/#{external_id} already exists."
      end

      # Update a platform connection's identity: adapter, account, coarse space id
      # and label.
      #
      # @param adapter [String, nil] must be a member of {KNOWN_ADAPTERS}
      # @return [Models::PlatformConnection]
      # @raise [Invalid] the connection belongs to a protected community, the
      #   adapter is unknown, or the account or external id is blank. A protected
      #   refusal happens first and leaves the row untouched.
      def update_identity(connection:, adapter:, account:, external_id:, label: nil)
        if protected?(connection)
          raise Invalid, "This connection belongs to a protected community and its identity can only be changed " \
                         "in config/protected_communities.yml, never from the dashboard."
        end

        adapter = presence(adapter)
        account = presence(account)
        external_id = presence(external_id)
        validate_adapter!(adapter)
        raise Invalid, "Account and external id are both required." if account.nil? || external_id.nil?

        connection.update(adapter: adapter, account: account, external_id: external_id,
                          label: presence(label), updated_at: @clock.call)
        reload
        @logger&.info { "platform connection identity updated: id=#{connection.id} adapter=#{adapter}" }
        connection
      end

      # Validate and persist an edit to a connection's behaviour settings, reusing
      # the owning adapter's account_schema for the fields {BEHAVIOR_FIELDS} names,
      # so a bad value is rejected by the same check {Config::Loader} runs at boot.
      #
      # @return [Models::PlatformConnection]
      # @raise [Invalid] no account configured, no editable behaviour fields, or a
      #   value that fails its schema. Every problem found is joined into one
      #   message.
      def save_behavior_settings(connection:, account:, raw_settings:)
        fields = BEHAVIOR_FIELDS.fetch(connection.adapter.to_sym, [])

        if account.nil?
          raise Invalid, "No account named #{connection.account.inspect} is configured for " \
                         "#{connection.adapter}; add it on the Accounts page before setting its behaviour."
        end
        raise Invalid, "#{connection.adapter} has no editable behaviour settings yet." if fields.empty?

        schema = behavior_schema(account.adapter_class, fields)
        submitted = raw_settings || {}
        raw = fields.each_with_object({}) do |name, out|
          out[name] = coerce_form_value(schema.fields[name], submitted[name.to_s])
        end

        result = schema.call(raw, path: "platforms[#{connection.id}].settings")
        raise Invalid, result.problems.join("; ") if result.problems.any?

        # Held for the read and the write, so two operators saving different
        # fields of the same connection do not each drop the other's.
        @models.db.transaction do
          locked = @models.platform_connection.where(id: connection.id).for_update.first || connection
          stored = locked.json_value(:settings)
          result.value.each { |key, value| stored[key.to_s] = value }
          locked.update(settings: JSON.generate(stored), updated_at: @clock.call)
          connection = locked
        end
        reload
        @logger&.info do
          "platform connection behaviour saved: id=#{connection.id} adapter=#{connection.adapter}"
        end
        connection
      end

      # Remove a platform connection outright. A plain destroy is enough on both
      # backends: channels.platform_connection_id is declared `on_delete: :cascade`.
      # Refused for a protected community, on the same reasoning {#update_identity}
      # refuses an edit: dropping the row unroutes that community until the next
      # boot reconciles the YAML back in.
      #
      # @return [Boolean] always true; the caller already holds the row
      # @raise [Invalid] the connection belongs to a protected community
      def remove(connection:)
        if protected?(connection)
          raise Invalid, "This connection belongs to a protected community and can only be removed " \
                         "in config/protected_communities.yml, never from the dashboard."
        end

        connection.destroy
        reload
        @logger&.info { "platform connection removed: id=#{connection.id}" }
        true
      end

      private

      def validate_adapter!(adapter)
        return if KNOWN_ADAPTERS.include?(adapter)

        raise Invalid, "Unknown adapter #{adapter.inspect}. Known adapters: #{KNOWN_ADAPTERS.join(", ")}."
      end

      # Whether a connection's community is on the protected whitelist. Only
      # identity is guarded; channels and rooms stay fully mutable.
      def protected?(connection)
        community = @models.community[connection.community_id]
        community && ProtectedCommunities.default.protects_community?(community)
      end

      # A {Config::Schema} holding only the named fields of an adapter's
      # account_schema, so an edit is validated by the same rules as
      # bridge.config.yaml. Rebuilt per call, so no shared Schema is mutable.
      def behavior_schema(adapter_class, field_names)
        source = adapter_class.account_schema
        Config::Schema.define do
          field_names.each do |name|
            f = source.fields[name]
            raise Invalid, "#{adapter_class} has no account_schema field named #{name.inspect}." if f.nil?

            field(f.name, f.type, required: false, default: f.default, one_of: f.one_of,
                                  of: f.schema || f.element_type, desc: f.description, &f.validator)
          end
        end
      end

      # Config::Schema's :boolean wants a real true/false, not the "true"/"false"
      # an HTML select submits, and :float only accepts a Numeric. :integer and
      # :symbol take a String as-is.
      def coerce_form_value(field, raw)
        return raw if field.nil? || raw.nil?

        case field.type
        when :boolean then raw == "true"
        when :float then Float(raw, exception: false) || raw
        else raw
        end
      end

      # Rebuild and swap the Snapshot when a Registry is wired, else a no-op. A
      # reload failure never loses the write; only live recognition is delayed.
      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "platform connections: snapshot reload after a write failed: #{e.message}" }
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
