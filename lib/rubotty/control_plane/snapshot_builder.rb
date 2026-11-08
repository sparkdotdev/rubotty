# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Reads the control-plane rows and projects them into a frozen Snapshot of
    # the value objects the rest of the system already uses.
    #
    # A full rebuild: at this scale a rebuild is cheap and the projection logic
    # stays simple. It reuses the existing constructors verbatim, so the source
    # moves from YAML to rows and the value classes do not change.
    module SnapshotBuilder
      module_function

      # @param models [ControlPlane::Models]
      # @param accounts [Hash] fallback account name => Config::Account, used
      #   only while the accounts table has never been seeded at all
      # @param env [Hash] environment to resolve a row's token_env against
      # @return [Snapshot]
      def build(models, accounts: {}, env: ENV)
        communities = models.community.order(:id).all.map do |row|
          build_community(row, models)
        end
        Snapshot.new(
          communities: communities, accounts: build_accounts(models, accounts, env),
          feature_settings: build_global_feature_settings(models)
        )
      end

      # The table is the sole source once it holds a single row, resolved into
      # live Config::Account objects the same way {Accounts#live} resolves one
      # for the dashboard, keyed by name: a name an operator has since deleted
      # drops out here too, and a row that fails to resolve costs only that
      # one account. +fallback+ shows through whole otherwise, for a database
      # nothing has populated yet: an operator adding an account through the
      # dashboard, or running `rubotty seed`, ends the fallback for good.
      def build_accounts(models, fallback, env)
        return fallback if models.account.count.zero?

        Accounts.new(models: models).live(env: env).to_h { |account| [account.name, account] }
      end

      def build_community(row, models)
        channel_rows = models.channel.where(community_id: row.id).order(:id).all
        mapped_at = mapped_at_by_channel(row, models)
        channels = channel_rows.map { |chrow| build_channel(chrow, mapped_at[chrow.id]) }
        channel_by_row_id = channel_rows.zip(channels).to_h { |chrow, ch| [chrow.id, ch] }

        # Which rooms admit guests: the "guest_portal" feature resolved room-row
        # over community-default. A guest endpoint is synthesised into a room only
        # here, so no guest surface exists until an operator enables it.
        guests_allowed = guests_allowed_room_ids(row, models)

        topology = Core::Topology.new(build_rooms(row, models, channel_by_row_id, guests_allowed))
        operators = build_operators(row, models)

        Snapshot::Community.new(
          id: row.id, slug: row.slug, name: row.name, status: row.status,
          settings: row.json_value(:settings),
          topology: topology,
          channels: channels,
          operators: operators,
          people: build_people(row, models, operators),
          feature_settings: build_feature_settings(row, models)
        )
      end

      # When each channel first joined a room, keyed by channel row id:
      # room_channels is insert-only, so its created_at is the mapping moment
      # and stays true. A channel in more than one room takes the earliest,
      # since it has been bridging somewhere since then.
      def mapped_at_by_channel(community_row, models)
        room_ids = models.room.where(community_id: community_row.id).select(:id)
        rows = models.room_channel.where(room_id: room_ids).select_map(%i[channel_id created_at])
        rows.each_with_object({}) do |(channel_id, created_at), out|
          held = out[channel_id]
          out[channel_id] = created_at if created_at && (held.nil? || created_at < held)
        end
      end

      def build_channel(row, mapped_at = nil)
        settings = coerce_settings(row.adapter, symbolize(row.json_value(:settings)))
        display = row.json_value(:display_name)
        endpoint = Core::Endpoint.owned_by(
          row.community_id,
          id: row.endpoint_key,
          adapter_name: row.adapter,
          account: row.account,
          settings: settings,
          receives: to_bool(row.receives),
          sends: to_bool(row.sends),
          relay: symbolize(row.json_value(:relay)),
          display_name_template: display["format"],
          display_name_fallback: display["fallback_format"],
          label: row.label
        )
        Snapshot::Channel.new(endpoint: endpoint, community_id: row.community_id,
                              route_key: row.route_key, mapped_at: mapped_at)
      end

      def build_rooms(community_row, models, channel_by_row_id, guests_allowed = Set.new)
        models.room.where(community_id: community_row.id).order(:id).all.map do |room_row|
          joins = models.room_channel.where(room_id: room_row.id).order(:id).all
          endpoints = joins.filter_map { |join| channel_by_row_id[join.channel_id]&.endpoint }
          # ONE synthetic guest endpoint per admitting room, not one per channel:
          # a guest session targets the whole room, so the bridge's ordinary N-way
          # fan-out (room.targets_for) is what reaches every platform. "landing" is
          # the first channel joined, for resolving moderation config only.
          landing = joins.filter_map { |join| channel_by_row_id[join.channel_id] }.first
          if landing && guests_allowed.include?(room_row.id)
            endpoints << guest_endpoint(room_row, landing, community_row.id)
          end
          # ONE synthetic API endpoint per room, with no feature gate: what a
          # client may post to is decided by the scope of the bearer key it
          # presents, room by room, at the moment of the request.
          endpoints << api_endpoint(room_row, landing, community_row.id) if landing
          display = room_row.json_value(:display_name)
          Core::Room.owned_by(
            community_row.id,
            id: room_row.room_key,
            label: room_row.label,
            endpoints: endpoints,
            display_name_template: display["format"],
            display_name_fallback: display["fallback_format"]
          )
        end
      end

      # The room ids whose "guest_portal" feature resolves ENABLED (room row over
      # community default). Empty unless an operator has turned the feature on.
      def guests_allowed_room_ids(community_row, models)
        feature = Features::GuestPortal.feature_name
        rows = models.feature_setting.where(community_id: community_row.id, feature: feature).all
        community_default = rows.find { |row| row.room_id.nil? }
        default_on = community_default ? to_bool(community_default.enabled) : false
        by_room = rows.reject { |row| row.room_id.nil? }
                      .to_h { |row| [row.room_id, to_bool(row.enabled)] }
        models.room.where(community_id: community_row.id).select_map(:id).select do |room_id|
          by_room.fetch(room_id, default_on)
        end.to_set
      end

      # The guest endpoint for a guest-enabled room: a virtual endpoint the
      # {Adapters::Guest::Adapter} serves for the WHOLE room. It carries the ids it
      # needs, and via +landing+ a real channel to resolve moderation scope through.
      def guest_endpoint(room_row, landing, community_id)
        Core::Endpoint.owned_by(
          community_id,
          id: Adapters::Guest.endpoint_key_for(room_row.id),
          adapter_name: Adapters::Guest::NAME,
          account: Adapters::Guest::ACCOUNT,
          settings: {
            room_key: room_row.room_key,
            room_id: room_row.id,
            channel_endpoint_key: landing.endpoint_key,
            community_id: community_id
          },
          receives: true,
          sends: true,
          label: "guest:#{room_row.room_key}"
        )
      end

      # The API endpoint for a room: the virtual endpoint {Adapters::Api::Adapter}
      # emits a queued post through, carrying the same ids the guest endpoint does.
      #
      # receives: true puts the key in {Core::Topology}'s index, so a message
      # ORIGINATING here is routed into the room; sends: false keeps it out of
      # every fan-out, so an API post reaches EVERY real channel in the room.
      def api_endpoint(room_row, landing, community_id)
        Core::Endpoint.owned_by(
          community_id,
          id: Adapters::Api.endpoint_key_for(room_row.id),
          adapter_name: Adapters::Api::NAME,
          account: Adapters::Api::ACCOUNT,
          settings: {
            room_key: room_row.room_key,
            room_id: room_row.id,
            channel_endpoint_key: landing.endpoint_key,
            community_id: community_id
          },
          receives: true,
          sends: false,
          label: "api:#{room_row.room_key}"
        )
      end

      def build_operators(community_row, models)
        operators = models.operator.where(community_id: community_row.id).order(:id).all.map do |op_row|
          person = models.person[op_row.person_id]
          Core::Moderation::Operator.new(
            name: person.name,
            identities: identities_of(person, models),
            actions: json_scalar_or_list(op_row.json_value(:actions)) { |list| list.map(&:to_sym) },
            rooms: json_scalar_or_list(op_row.json_value(:scope)) { |list| list.map(&:to_s) },
            # The rooms above are keys in THIS community's key space, so the
            # operator carries the community they are keyed against.
            community_id: community_row.id
          )
        end
        Core::Moderation::Directory.new(operators)
      end

      # Mirrors Config::Loader#build_people: the people rows are the general
      # registry, and the operators are folded in as people (without handles).
      # Order matters: the Directory indexes with ||= and first write wins.
      def build_people(community_row, models, operators)
        nicknames = BridgedNicknames.new(models: models).by_person(community_id: community_row.id)
        entries = models.person.where(community_id: community_row.id).order(:id).all.map do |person|
          mine = nicknames[person.id] || {}
          Core::Person.new(
            name: person.name,
            identities: identities_of(person, models),
            # Folded in as handles, so a nickname resolves through the same
            # lookup a real username does rather than needing its own path.
            handles: with_nicknames(handles_of(person, models), mine),
            nicknames: mine
          )
        end

        operator_people = operators.operators.map do |operator|
          Core::Person.new(name: operator.name, identities: operator.identities)
        end

        Core::Directory.new(entries + operator_people)
      end

      def build_feature_settings(community_row, models)
        room_key_by_id = models.room.where(community_id: community_row.id).all.to_h { |room| [room.id, room.room_key] }
        models.feature_setting.where(community_id: community_row.id).all.map do |row|
          room_key = row.room_id && room_key_by_id[row.room_id]
          Snapshot::FeatureSetting.new(
            room_key: room_key,
            feature: row.feature,
            enabled: to_bool(row.enabled),
            config: symbolize_deep(row.json_value(:config))
          )
        end
      end

      # The deployment-wide feature_settings rows: community_id AND room_id both
      # NULL, one per feature at most (the partial unique index migration 081
      # adds alongside community_id's own nullability enforces that on Postgres
      # and SQLite).
      def build_global_feature_settings(models)
        models.feature_setting.where(community_id: nil).all.map do |row|
          Snapshot::FeatureSetting.new(
            feature: row.feature,
            enabled: to_bool(row.enabled),
            config: symbolize_deep(row.json_value(:config))
          )
        end
      end

      def identities_of(person, models)
        rows = models.person_identity.where(person_id: person.id).order(:id).all
        rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, out|
          out[row.adapter.to_sym] << row.native_id.to_s unless row.native_id.nil?
        end.transform_values(&:freeze)
      end

      def handles_of(person, models)
        rows = models.person_identity.where(person_id: person.id).order(:id).all
        rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, out|
          out[row.adapter.to_sym] << row.username.to_s unless row.username.nil?
        end.transform_values(&:freeze)
      end

      # +handles+ plus each nickname under the platform it is shown on, so
      # @nickname typed there resolves to this person like a real handle would.
      def with_nicknames(handles, nicknames)
        return handles if nicknames.empty?

        merged = handles.transform_values(&:dup)
        nicknames.each do |adapter, nickname|
          (merged[adapter.to_sym] ||= []) << nickname
        end
        merged.transform_values { |list| list.uniq.freeze }
      end

      def coerce_settings(adapter, settings)
        adapter_class = Adapters::Registry.fetch(adapter)
        result = adapter_class.endpoint_schema.call(settings, path: "channel")
        result.problems.empty? ? result.value : settings
      rescue UnknownAdapterError
        settings
      end

      # A JSON value that is either the string "all" or a list. Yields the list
      # for transformation; returns :all for the scalar.
      def json_scalar_or_list(value)
        return :all if value == "all"

        yield Array(value)
      end

      def symbolize(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
      end

      def symbolize_deep(value)
        case value
        when Hash then value.each_with_object({}) { |(k, v), out| out[k.to_sym] = symbolize_deep(v) }
        when Array then value.map { |v| symbolize_deep(v) }
        else value
        end
      end

      # Booleans survive a SQLite round trip as 0/1 in some Sequel paths, and 0 is
      # truthy in Ruby, which would otherwise flip a "sends: false" endpoint on.
      def to_bool(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end
    end
  end
end
