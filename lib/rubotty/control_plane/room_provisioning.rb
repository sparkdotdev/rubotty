# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # Creates and deletes meta-channels (rooms) from the dashboard:
    # {#request_create}/{#request_delete} validate, audit and enqueue a
    # durable job, while {#create}/{#delete} are the handlers that run only
    # where live adapters exist. Admin-only is enforced by the caller;
    # deleting platform channels is a separate opt-in, and a channel the bot
    # did not create is never deleted unless named in `force_channel_ids:`.
    # {#create} rolls back on any platform failure: every channel this
    # request created is deleted again and no Channel/Room row is written.
    class RoomProvisioning
      class Invalid < Rubotty::Error; end

      CREATE_KIND = "room_provisioning_create"
      DELETE_KIND = "room_provisioning_delete"

      Result = Struct.new(:status, :room, :channels, :failures, :job, keyword_init: true) do
        def ok? = %i[requested created deleted].include?(status)
      end

      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] live adapters,
      #   real only in the bot process; empty in the dashboard
      # @param channel_mapper [ChannelMapper, nil] reused for the room-linking
      #   half of #create, built fresh with the same models/registry when nil
      def initialize(models:, scheduler: nil, adapters: {}, registry: nil, audit: nil,
                     channel_mapper: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @scheduler = scheduler
        @adapters = adapters
        @registry = registry
        @audit = audit || Core::AuditLog::Null.new
        @channel_mapper = channel_mapper || ChannelMapper.new(models: models, registry: registry, logger: logger,
                                                                clock: clock)
        @logger = logger
        @clock = clock
      end

      # Request a new room, provisioned on each of +platforms+.
      #
      # @param platforms [Array<Hash>] each { adapter:, account: }, naming one
      #   of the community's platform_connections
      # @param template_channel [String, nil] an existing channel's
      #   endpoint_key to copy permissions from, where the platform supports it
      # @return [Result] :requested
      def request_create(community:, name:, platforms:, template_channel: nil, requested_by:)
        name = name.to_s.strip
        raise Invalid, "a room needs a name" if name.empty?

        platform_list = Array(platforms).map { |entry| normalize_platform(entry) }
        raise Invalid, "choose at least one platform to create the room on" if platform_list.empty?

        platform_list.each { |entry| resolve_connection!(community, entry) }
        resolve_template!(community, template_channel)

        payload = {
          "community_id" => community.id, "name" => name, "platforms" => platform_list,
          "template_channel" => template_channel, "requested_by" => requested_by.to_s
        }
        job = @scheduler&.schedule(kind: CREATE_KIND, run_at: @clock.call, payload: payload, community: community.slug)
        @audit.record(
          community: community.slug, source: "room_provisioning", action: "room_create_requested",
          actor: requested_by, metadata: { name: name, platforms: platform_list }, now: @clock.call
        )
        Result.new(status: :requested, room: nil, channels: [], failures: nil, job: job)
      end

      # Request a room's deletion. Always unmaps; deletes the underlying platform
      # channels only when +delete_platform_channels+ is true, and even then only
      # for a channel the bot provisioned or whose id is in +force_channel_ids+.
      #
      # @param room [Models::Room] must belong to +community+
      # @param confirmed_name [String] must equal the room's label or key,
      #   case-insensitively, so a delete cannot fire on a misclick
      # @return [Result] :requested
      def request_delete(community:, room:, confirmed_name:, requested_by:, delete_platform_channels: false,
                          force_channel_ids: [])
        unless room && room.community_id == community.id
          raise Invalid, "that room does not belong to this community."
        end

        expected = [room.label, room.room_key].compact.map { |v| v.to_s.strip.downcase }
        typed = confirmed_name.to_s.strip.downcase
        raise Invalid, "type the room's name to confirm deletion" unless expected.include?(typed)

        payload = {
          "community_id" => community.id, "room_id" => room.id,
          "delete_platform_channels" => !!delete_platform_channels,
          "force_channel_ids" => Array(force_channel_ids).map(&:to_i),
          "requested_by" => requested_by.to_s
        }
        job = @scheduler&.schedule(kind: DELETE_KIND, run_at: @clock.call, payload: payload, community: community.slug)
        @audit.record(
          community: community.slug, source: "room_provisioning", action: "room_delete_requested",
          actor: requested_by, target_ref: room.room_key,
          metadata: { delete_platform_channels: !!delete_platform_channels }, now: @clock.call
        )
        Result.new(status: :requested, room: room, channels: [], failures: nil, job: job)
      end

      # {DurableScheduler} handler for {CREATE_KIND}. Only ever registered where
      # +adapters+ is a real, live map.
      def create(job)
        payload = job.payload
        community = @models.community[payload["community_id"]]
        return Result.new(status: :failed, failures: ["community no longer exists"]) if community.nil?

        name = payload["name"]
        platform_list = Array(payload["platforms"])
        template_endpoint_key = payload["template_channel"]

        created = []
        failure = nil
        platform_list.each do |entry|
          adapter_name = entry["adapter"] || entry[:adapter]
          account = entry["account"] || entry[:account]
          adapter = @adapters[[adapter_name.to_s.to_sym, account.to_s]]
          if adapter.nil? || !adapter.supports_channel_management?
            failure = "#{adapter_name}/#{account}: channel management is not supported here"
            break
          end

          begin
            template_native_id = native_id_for_endpoint_key(community.id, template_endpoint_key,
                                                              adapter: adapter_name, account: account)
            native_id = adapter.create_channel(name: name, community_id: community.id,
                                               template: template_native_id)
            raise AdapterError.new("no channel id returned", adapter: adapter_name.to_s.to_sym) if native_id.nil?

            if template_native_id
              begin
                adapter.copy_channel_permissions(from: template_native_id, to: native_id)
              rescue StandardError => e
                @logger&.warn { "room provisioning: permission copy failed, continuing: #{e.message}" }
              end
            end
            created << { adapter: adapter_name.to_s, account: account.to_s, native_id: native_id }
          rescue StandardError => e
            failure = "#{adapter_name}/#{account}: #{e.message}"
            break
          end
        end

        if failure
          rollback(created, community)
          @audit.record(
            community: community.slug, source: "room_provisioning", action: "room_create_failed",
            actor: payload["requested_by"], metadata: { name: name, reason: failure }, now: @clock.call
          )
          return Result.new(status: :failed, failures: [failure])
        end

        room, channel_rows = persist(community, name, created)
        @audit.record(
          community: community.slug, source: "room_provisioning", action: "room_created",
          actor: payload["requested_by"], target_ref: room.room_key,
          metadata: { platforms: created.map { |c| "#{c[:adapter]}/#{c[:account]}" } }, now: @clock.call
        )
        Result.new(status: :created, room: room, channels: channel_rows, failures: nil)
      end

      # {DurableScheduler} handler for {DELETE_KIND}.
      def delete(job)
        payload = job.payload
        community = @models.community[payload["community_id"]]
        room = @models.room[payload["room_id"]]
        return Result.new(status: :failed, failures: ["room no longer exists"]) if community.nil? || room.nil?

        # The two ids crossed a process boundary and are reloaded independently,
        # so the pair is checked again here rather than trusted because the
        # request checked it. Refuses loudly: destroying rows and real platform
        # channels is not a thing to do on a scope nobody confirmed.
        unless room.community_id == community.id
          return refused_delete(community, room, payload)
        end

        channel_ids = @models.room_channel.where(room_id: room.id).select_map(:channel_id)
        channels = channel_ids.empty? ? [] : @models.channel.where(id: channel_ids).all
        force_ids = Array(payload["force_channel_ids"]).map(&:to_i)

        platform_failures = []
        if payload["delete_platform_channels"]
          channels.each do |channel|
            next unless channel.provisioned_by_bot || force_ids.include?(channel.id)

            adapter = @adapters[[channel.adapter.to_s.to_sym, channel.account.to_s]]
            if adapter.nil? || !adapter.supports_channel_management?
              platform_failures << "#{channel.adapter}/#{channel.account}: cannot delete on the platform"
              next
            end

            begin
              # A falsy return means the delete failed on the platform;
              # treating it as success would destroy the row while the
              # channel stays live remotely.
              unless adapter.delete_channel(channel.route_key, community_id: community.id)
                platform_failures << "#{channel.adapter}/#{channel.account}: the platform refused the delete"
                next
              end
              channel.destroy
            rescue StandardError => e
              platform_failures << "#{channel.adapter}/#{channel.account}: #{e.message}"
            end
          end
        end

        @models.db.transaction do
          @models.room_channel.where(room_id: room.id).delete
          room.destroy
        end
        reload

        @audit.record(
          community: community.slug, source: "room_provisioning", action: "room_deleted",
          actor: payload["requested_by"], target_ref: room.room_key,
          metadata: { platform_failures: platform_failures }, now: @clock.call
        )
        Result.new(status: :deleted, room: nil, channels: [], failures: platform_failures.empty? ? nil : platform_failures)
      end

      private

      # Audited under the community that ASKED, which is the one whose request
      # was wrong, and logged at error level so a deployment sees it.
      def refused_delete(community, room, payload)
        reason = "room #{room.id} belongs to community #{room.community_id.inspect}, not #{community.id.inspect}"
        @logger&.error { "room provisioning: REFUSED a delete, #{reason}" }
        @audit.record(
          community: community.slug, source: "room_provisioning", action: "room_delete_refused",
          actor: payload["requested_by"], target_ref: room.room_key,
          metadata: { reason: reason }, now: @clock.call
        )
        Result.new(status: :failed, failures: ["that room does not belong to this community"])
      end

      def normalize_platform(entry)
        {
          "adapter" => (entry[:adapter] || entry["adapter"]).to_s,
          "account" => (entry[:account] || entry["account"]).to_s
        }
      end

      def resolve_connection!(community, entry)
        connection = @models.platform_connection.where(
          community_id: community.id, adapter: entry["adapter"], account: entry["account"]
        ).first
        return connection if connection

        raise Invalid, "#{entry["adapter"]}/#{entry["account"]} is not a connection of " \
                        "community #{community.slug.inspect}"
      end

      # A template is copied from, so it has to be a channel of the community
      # asking, the same bar resolve_connection! holds a platform to.
      def resolve_template!(community, endpoint_key)
        return nil if endpoint_key.to_s.empty?

        channel = channel_for_endpoint_key(community.id, endpoint_key)
        return channel if channel

        raise Invalid, "#{endpoint_key} is not a channel of community #{community.slug.inspect}"
      end

      # endpoint_key is globally unique (migration 001), so an unscoped lookup
      # resolves another tenant's channel just as happily as this one's.
      def channel_for_endpoint_key(community_id, endpoint_key)
        return nil if endpoint_key.to_s.empty?

        @models.channel.where(community_id: community_id, endpoint_key: endpoint_key.to_s).first
      end

      # Only handed back when the template channel is also on the platform
      # entry being provisioned right now: a route_key from one platform is
      # meaningless, and often rejected outright, when passed to another.
      def native_id_for_endpoint_key(community_id, endpoint_key, adapter:, account:)
        channel = channel_for_endpoint_key(community_id, endpoint_key)
        return nil if channel.nil?
        return nil unless channel.adapter.to_s == adapter.to_s && channel.account.to_s == account.to_s

        channel.route_key
      end

      def rollback(created, community)
        created.each do |entry|
          adapter = @adapters[[entry[:adapter].to_sym, entry[:account]]]
          adapter&.delete_channel(entry[:native_id], community_id: community.id)
        rescue StandardError => e
          @logger&.warn { "room provisioning: rollback delete failed for #{entry[:native_id]}: #{e.message}" }
        end
      end

      # Persist each created platform channel as a Channel row (marked
      # provisioned_by_bot), then hand their endpoint keys to {ChannelMapper}
      # to link them into one room.
      def persist(community, name, created)
        now = @clock.call
        channel_rows = created.map do |entry|
          connection = @models.platform_connection.where(
            community_id: community.id, adapter: entry[:adapter], account: entry[:account]
          ).first
          @models.channel.create(
            community_id: community.id, platform_connection_id: connection&.id,
            adapter: entry[:adapter], account: entry[:account], route_key: entry[:native_id],
            endpoint_key: "provisioned:#{entry[:adapter]}:#{entry[:account]}:#{entry[:native_id]}",
            label: name, settings: Models.dump_json(addressing(entry[:adapter], entry[:native_id])),
            provisioned_by_bot: true, created_at: now, updated_at: now
          )
        end
        result = @channel_mapper.map(community: community, selectors: channel_rows.map(&:endpoint_key), label: name)
        [result.room, channel_rows]
      end

      # Read from the owning adapter, the same source {ChannelDiscovery#addressing}
      # reads from, so a provisioned channel and a discovered one never
      # disagree about how their adapter addresses them.
      def addressing(adapter, native_id)
        Adapters::Registry.fetch(adapter).addressing(native_id)
      end

      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "room provisioning: snapshot reload after a write failed: #{e.message}" }
      end
    end
  end
end
