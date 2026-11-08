# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The live-gateway half of channel discovery: feeds real channels from a
    # live gateway to {ChannelMapper} and {NewChannelWatch} through three entry
    # points, {#inventory} (bulk sweep), {#saw} (incremental sighting) and
    # {#recognize_guild} (guild seed resolution), and persists a discovery so
    # the wizard can act on it.
    class ChannelDiscovery
      # Prefix for a discovered channel's endpoint_key, so it reads as discovered
      # and cannot collide with a YAML endpoint id.
      ENDPOINT_KEY_PREFIX = "discovered"

      # The endpoint_key a discovered channel at +route_key+ carries.
      def self.endpoint_key_for(adapter, account, route_key)
        "#{ENDPOINT_KEY_PREFIX}:#{adapter}:#{account}:#{route_key}"
      end

      # @param watch [#observe, nil] the {NewChannelWatch} decision core, consulted
      #   only by {#saw}. Nil suits a caller that only identifies and suggests.
      # @param notifier [#prompt, nil] carries a prompt to the operators; nil just
      #   logs, so discovery still records channels with no notification medium
      # @param pending_spaces [ControlPlane::PendingSpaces, nil] pends a space that
      #   {#saw} could attribute to no community. Nil skips that fallback, which is
      #   what the dashboard and the REST API want: neither holds an adapter.
      def initialize(models:, watch: nil, notifier: nil, operators: nil, pending_spaces: nil, logger: nil,
                     clock: -> { Time.now })
        @models = models
        @watch = watch
        @notifier = notifier
        @operators = operators
        @pending_spaces = pending_spaces
        @logger = logger
        @clock = clock
      end

      # Resolve a guild's seed sentinel from a GUILD_CREATE, for the auto-leave
      # guard. A non-nil return means the guild owns a seeded channel and must be
      # kept; the sentinel is resolved as a side effect.
      #
      # @return [Models::PlatformConnection, nil]
      def recognize_guild(account:, guild_id:, channel_ids:)
        GuildResolver.resolve_from_guild(
          models: @models, account: account, guild_id: guild_id,
          channel_ids: channel_ids, logger: @logger
        )
      end

      # Bulk enumeration of an authorized space's channels: idempotent and
      # dormant, since a newly recorded channel is in no room so nothing
      # bridges. A space still awaiting approval drops its whole listing here
      # (logged); {PendingSpaces#approve} re-asks the adapter once it exists.
      #
      # @param channels [Array<Hash>] { id:, name: } as the adapter enumerated them
      # @return [Integer] how many NEW channel rows were recorded
      def inventory(adapter:, account:, external_id:, channels:)
        connection = connection_for(adapter, account, external_id)
        if connection.nil?
          warn_dropped_listing(adapter, account, external_id, Array(channels).size)
          return 0
        end

        Array(channels).count do |channel|
          record(connection, adapter: adapter, account: account, external_id: external_id,
                             route_key: channel[:id], name: channel[:name])
        end
      end

      # One channel sighting: asks {NewChannelWatch} whether to prompt, and
      # only on a prompt does it persist the channel and notify the
      # operators. An "already mapped" sighting still backfills the name
      # since a later sighting may carry one the first lacked, and
      # "unauthorized" is the fallback for a join event nobody was up to see.
      #
      # @param descriptor [Hash] the shape {NewChannelWatch#observe} expects
      # @return [NewChannelWatch::Decision]
      def saw(descriptor)
        decision = @watch.observe(descriptor)
        backfill_name(decision.descriptor) if decision.reason == :already_mapped
        pend_unattributed(decision.descriptor) if decision.reason == :unauthorized
        return decision unless decision.prompt?

        record_sighting(decision.descriptor)
        notify(decision)
        decision
      end

      # Explicit manual discovery: the /identify-topic fallback for a channel
      # auto-discovery never picked up, always taking effect by renaming an
      # existing row rather than skipping it. An operator's request lands
      # immediately; anyone else's writes the same row but flags it
      # +suggested+, so it shows on the Rooms board for approval.
      #
      # @param operator [Boolean] whether the requester is a community operator
      # @return [Models::Channel, nil] the row, or nil for no active community
      def identify(descriptor:, operator:)
        descriptor = normalize(descriptor)
        return nil if descriptor[:name].empty?

        connection = connection_for(descriptor[:adapter], descriptor[:account], descriptor[:external_id])
        return nil if connection.nil?

        community = @models.community[connection.community_id]
        return nil if community.nil? || community.status.to_s != "active"

        channel = upsert_named(connection, descriptor, suggested: !operator)
        @logger&.info do
          "#{operator ? "identified" : "suggested"} #{descriptor[:adapter]} channel " \
            "#{descriptor[:route_key]} (#{descriptor[:name]}) in #{community.slug}"
        end
        channel
      end

      # Whether the person behind (adapter, native_id[, username]) already operates
      # the community owning that space's platform connection. False, never
      # raising, when there is no active community or no operators service.
      #
      # @return [Boolean]
      def operator_for?(adapter:, account:, external_id:, native_id:, username: nil)
        # The deployment-configured owner floor comes first: a protected operator is authorised
        # everywhere, so they must not depend on a community or operators row.
        if Security::ProtectedOperators.default.owner?(adapter: adapter, username: username, native_id: native_id)
          return true
        end
        return false if @operators.nil?

        connection = connection_for(adapter.to_s, account.to_s, external_id.to_s)
        return false if connection.nil?

        !@operators.resolve_operator(
          community_id: connection.community_id, adapter: adapter.to_s,
          native_id: native_id&.to_s, username: username&.to_s
        ).nil?
      rescue StandardError => e
        @logger&.warn { "channel discovery: operator_for? failed: #{e.class}: #{e.message}" }
        false
      end

      # {#identify}'s companion for the pipeline-level /identify-topic path: a
      # message that reached the pipeline was already matched to a real channel
      # row, so there is no create case here. The community is required and
      # part of the predicate, the same bar {RoomProvisioning} holds: an
      # endpoint key is unique across the whole deployment, so a lookup on the
      # key alone relabels whichever tenant owns it. Nil on an unknown key.
      #
      # @return [Models::Channel, nil]
      def identify_known(community_id:, endpoint_key:, name:, operator:)
        raise ArgumentError, "identifying a channel needs the community that owns it" if community_id.nil?

        name = name.to_s.strip
        return nil if name.empty?

        channel = @models.channel.where(community_id: community_id, endpoint_key: endpoint_key.to_s).first
        return nil if channel.nil?

        channel.update(label: name, suggested: !operator, updated_at: @clock.call)
        @logger&.info do
          "#{operator ? "identified" : "suggested"} #{channel.adapter} channel " \
            "#{channel.route_key} (#{name}) via /identify-topic"
        end
        channel
      end

      # An operator approving a suggested channel: it stops being flagged, nothing
      # else changes. A no-op on an unknown id or a row that was never suggested.
      #
      # @return [Models::Channel, nil]
      def approve_suggestion(channel_id)
        channel = @models.channel[channel_id]
        return nil if channel.nil? || !truthy(channel.suggested)

        channel.update(suggested: false, updated_at: @clock.call)
        channel
      end

      # An operator rejecting a suggested name: clear that name and its pending
      # flag, leaving the channel and any room mapping intact. Only ever touches
      # a row still flagged +suggested+, so this cannot alter an approved channel
      # by guessing its id.
      #
      # @return [Boolean] whether a row was actually removed
      def reject_suggestion(channel_id)
        channel = @models.channel[channel_id]
        return false if channel.nil? || !truthy(channel.suggested)

        channel.update(label: nil, suggested: false, updated_at: @clock.call)
        true
      end

      # A community's channels that are not yet in a room, oldest first. How a
      # channel arrived (discovered, seeded or provisioned) is fixed in its
      # endpoint key, not a statement about whether it needs a room today.
      # Shared by the dashboard and the REST admin API.
      #
      # @return [Array<Models::Channel>]
      def unmapped(community)
        room_ids = @models.room.where(community_id: community.id).select(:id)
        roomed = @models.room_channel.where(room_id: room_ids).select_map(:channel_id)
        scope = @models.channel.where(community_id: community.id)
        scope = scope.exclude(id: roomed) unless roomed.empty?
        scope.order(:created_at).all
      end

      private

      def truthy(value) = [true, 1, "1", "t", "true"].include?(value)

      def normalize(descriptor)
        {
          adapter: descriptor[:adapter].to_s, account: descriptor[:account].to_s,
          external_id: descriptor[:external_id].to_s, route_key: descriptor[:route_key].to_s,
          name: descriptor[:name].to_s.strip,
          # The one existing label +name+ may replace: an adapter's own placeholder
          # for a channel it could not name yet. Nil replaces nothing.
          supersedes: presence(descriptor[:supersedes])
        }
      end

      # Create-or-rename unconditionally, where #record only ever creates.
      def upsert_named(connection, descriptor, suggested:)
        adapter = descriptor[:adapter]
        account = descriptor[:account]
        route_key = descriptor[:route_key]
        now = @clock.call

        existing = @models.channel.where(adapter: adapter, account: account, route_key: route_key).first
        if existing
          existing.update(label: descriptor[:name], suggested: suggested, updated_at: now)
          return existing
        end

        @models.channel.create(
          community_id: connection.community_id, platform_connection_id: connection.id,
          adapter: adapter, account: account, route_key: route_key,
          endpoint_key: endpoint_key(adapter, account, route_key),
          label: descriptor[:name], suggested: suggested,
          settings: Models.dump_json(addressing(adapter, descriptor[:external_id], route_key)),
          created_at: now, updated_at: now
        )
      rescue Sequel::UniqueConstraintViolation
        @models.channel.where(adapter: adapter, account: account, route_key: route_key).first
      end

      # Fill in a previously-blank label now that a sighting has a name to offer.
      def backfill_name(descriptor)
        name = presence(descriptor[:name])
        return if name.nil?

        channel = @models.channel.where(
          adapter: descriptor[:adapter].to_s, account: descriptor[:account].to_s,
          route_key: descriptor[:route_key].to_s
        ).first
        return if channel.nil?
        return if channel.label.to_s == name

        # An existing label is left alone so passive traffic never rewrites a name
        # someone chose. The one exception is the adapter's own placeholder, named
        # exactly by +supersedes+, so a deliberate rename stays safe.
        return if presence(channel.label) && channel.label.to_s != descriptor[:supersedes].to_s

        previous = presence(channel.label)
        channel.update(label: name, updated_at: @clock.call)
        @logger&.info do
          if previous
            "renamed #{channel.adapter} channel #{channel.route_key} from #{previous.inspect} to " \
              "#{name.inspect}, now that the platform's own name is known"
          else
            "learned a name for previously unnamed #{channel.adapter} channel #{channel.route_key}: #{name}"
          end
        end
      end

      # Hand a space nothing could attribute to {PendingSpaces}, so it reaches
      # the dashboard even though no join event ever did; every adapter with a
      # discovery seam feeds this one method. The name is offered only when the
      # sighting IS the space (Telegram's plain group, where route_key and
      # external_id are both the chat id), since a Discord channel or forum
      # topic would otherwise label the whole space after one room inside it.
      def pend_unattributed(descriptor)
        return if @pending_spaces.nil?

        named = descriptor[:route_key].to_s == descriptor[:external_id].to_s
        @pending_spaces.on_traffic!(
          adapter: descriptor[:adapter], account: descriptor[:account],
          external_id: descriptor[:external_id], name: named ? presence(descriptor[:name]) : nil
        )
      rescue StandardError => e
        @logger&.warn { "channel discovery: pending an unattributed space failed: #{e.class}: #{e.message}" }
      end

      def record_sighting(descriptor)
        connection = connection_for(descriptor[:adapter], descriptor[:account], descriptor[:external_id])
        return if connection.nil?

        record(connection, adapter: descriptor[:adapter], account: descriptor[:account],
                           external_id: descriptor[:external_id], route_key: descriptor[:route_key],
                           name: descriptor[:name])
      end

      def notify(decision)
        @notifier&.prompt(community: decision.community, descriptor: decision.descriptor)
      rescue StandardError => e
        @logger&.warn { "channel discovery: notify failed: #{e.class}: #{e.message}" }
      end

      # Create a dormant channel row unless one exists, idempotent by (adapter,
      # account, route_key). Records no room membership, so routing is unchanged.
      def record(connection, adapter:, account:, external_id:, route_key:, name:)
        route_key = route_key.to_s
        return false if route_key.empty?

        adapter = adapter.to_s
        account = account.to_s
        return false if @models.channel.where(adapter: adapter, account: account, route_key: route_key).first

        now = @clock.call
        @models.channel.create(
          community_id: connection.community_id,
          platform_connection_id: connection.id,
          adapter: adapter, account: account, route_key: route_key,
          endpoint_key: endpoint_key(adapter, account, route_key),
          label: presence(name),
          settings: Models.dump_json(addressing(adapter, external_id, route_key)),
          created_at: now, updated_at: now
        )
        @logger&.info { "discovered #{adapter} channel #{route_key} (#{presence(name) || "unnamed"})" }
        true
      rescue Sequel::UniqueConstraintViolation
        # A concurrent sighting created the row, so this counts as already there.
        false
      end

      # Name what a dropped listing cost, so the loss leaves a trace. An empty
      # listing dropped nothing, so it says nothing.
      def warn_dropped_listing(adapter, account, external_id, count)
        return if count.zero?

        @logger&.warn do
          "channel discovery: dropped #{count} enumerated #{adapter} channels for account #{account} " \
            "in space #{external_id}, which has no platform connection yet"
        end
      end

      def connection_for(adapter, account, external_id)
        @models.platform_connection.where(
          adapter: adapter.to_s, account: account.to_s, external_id: external_id.to_s
        ).first
      end

      def endpoint_key(adapter, account, route_key) = self.class.endpoint_key_for(adapter, account, route_key)

      # The adapter addressing keys a channel row needs so it projects to a
      # working Core::Endpoint once mapped, read from the owning adapter
      # rather than kept here, so it can never drift from what
      # {ControlPlane::RoomProvisioning} produces for the same adapter.
      def addressing(adapter, external_id, route_key)
        Adapters::Registry.fetch(adapter).addressing(route_key, external_id: external_id)
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
