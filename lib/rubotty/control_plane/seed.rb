# frozen_string_literal: true

require "json"
require_relative "../security/grant_identity"

module Rubotty
  module ControlPlane
    # Projects a validated Config::Model (the YAML the single-community bridge
    # runs on today) into control-plane rows, so a Snapshot built from the DB is
    # equivalent to the one the loader builds from YAML.
    #
    # Idempotent: re-running reconciles a community by slug, a channel by
    # (adapter, account, route_key), a room by (community, room_key), and a
    # person by shared identity, so seeding twice does not duplicate rows.
    class Seed
      # @param model [Config::Model]
      # @param models [ControlPlane::Models]
      # @param slug [String] the community handle to seed under
      # @param name [String, nil] display name, defaults to the Model's name
      # @param source [String, nil] bootstrap provenance, defaults to Model#source
      # @return [Integer] the seeded community id
      def self.from_model(model, models:, slug:, name: nil, source: nil)
        new(model, models: models, slug: slug, name: name, source: source).run
      end

      # Reconcile ONLY the community row's display name from the config, every
      # boot, not just the first: a name edited in bridge.config.yaml after the
      # initial seed must not be stranded on the row forever. Touches nothing else.
      #
      # @return [Models::Community, nil] the row, or nil when none exists yet
      #   under +slug+
      def self.reconcile_identity(model, models:, slug:, name: nil)
        new(model, models: models, slug: slug, name: name).reconcile_identity
      end

      def initialize(model, models:, slug:, name: nil, source: nil)
        @model = model
        @models = models
        @slug = slug.to_s
        @name = name || model.name
        @source = source || model.source
        @now = Time.now
      end

      def run
        @models.db.transaction do
          community = upsert_community
          seed_topology(community)
          seed_people_and_operators(community)
          seed_features(community)
          community.id
        end
      end

      # @return [Models::Community, nil] the row, but ONLY when its name actually
      #   changed; nil both when there is no row yet and when the name matched
      def reconcile_identity
        existing = @models.community.where(slug: @slug).first
        return nil if existing.nil?
        return nil if existing.name == @name

        existing.update(name: @name, updated_at: @now)
        existing
      end

      private

      def upsert_community
        attributes = {
          name: @name,
          status: "active",
          settings: dump(community_settings),
          bootstrap_source: @source
        }
        existing = @models.community.where(slug: @slug).first
        if existing
          existing.update(attributes.merge(updated_at: @now))
          existing
        else
          @models.community.create(attributes.merge(slug: @slug, created_at: @now, updated_at: @now))
        end
      end

      # Community-wide defaults that are not themselves rows: behaviour, the
      # announce banner, the command defaults, and the display-name template.
      def community_settings
        {
          behaviour: @model.behaviour,
          announce: @model.announce,
          commands: @model.commands,
          display_name: {
            format: @model.display_name.template,
            fallback_format: @model.display_name.fallback
          }
        }
      end

      def seed_topology(community)
        hub_groups = build_hub_groups
        @model.topology.rooms.each do |room|
          room_row = upsert_room(community, room)
          room.endpoints.each do |endpoint|
            connection = upsert_connection(community, endpoint)
            key = [endpoint.adapter_name.to_s, endpoint.account.to_s, route_key_for(endpoint)]
            channel = upsert_channel(community, connection, endpoint, hub_groups[key])
            upsert_room_channel(room_row, channel)
          end
        end
      end

      # Every endpoint keyed by (adapter, account, route_key), in room-then-endpoint
      # order matching how a live IRC adapter groups its +endpoints:+ argument. A key
      # mapping to more than one endpoint is a hub group: several rooms mirrored into
      # one physical channel, used by #receives_for to settle ties.
      def build_hub_groups
        groups = Hash.new { |h, k| h[k] = [] }
        @model.topology.rooms.each do |room|
          room.endpoints.each do |endpoint|
            key = [endpoint.adapter_name.to_s, endpoint.account.to_s, route_key_for(endpoint)]
            groups[key] << endpoint
          end
        end
        groups
      end

      def upsert_room(community, room)
        attributes = {
          label: room.label,
          display_name: dump(display_template(room.display_name_template, room.display_name_fallback))
        }
        existing = @models.room.where(community_id: community.id, room_key: room.id).first
        if existing
          existing.update(attributes.merge(updated_at: @now))
          existing
        else
          @models.room.create(
            attributes.merge(community_id: community.id, room_key: room.id,
                             created_at: @now, updated_at: @now)
          )
        end
      end

      def upsert_connection(community, endpoint)
        adapter = endpoint.adapter_name.to_s
        account = endpoint.account.to_s
        external_id = space_external_id(endpoint)
        attributes = { community_id: community.id, label: nil }
        existing = @models.platform_connection
                          .where(adapter: adapter, account: account, external_id: external_id).first
        if existing
          existing.update(community_id: community.id, updated_at: @now)
          existing
        else
          @models.platform_connection.create(
            attributes.merge(adapter: adapter, account: account, external_id: external_id,
                             created_at: @now, updated_at: @now)
          )
        end
      end

      def upsert_channel(community, connection, endpoint, group)
        route_key = route_key_for(endpoint)
        attributes = {
          community_id: community.id,
          platform_connection_id: connection.id,
          endpoint_key: endpoint.id,
          label: endpoint.label,
          receives: receives_for(endpoint, group),
          sends: endpoint.sends?,
          relay: dump(endpoint.relay),
          display_name: dump(display_template(endpoint.display_name_template, endpoint.display_name_fallback)),
          settings: dump(endpoint.settings)
        }
        # endpoint_key first: Config::Endpoint#id is this endpoint's own stable
        # YAML identity, the only lookup that survives a hub group, where
        # several endpoints legitimately share (adapter, account, route_key)
        # and a route_key match alone cannot tell them apart.
        existing = @models.channel.where(endpoint_key: endpoint.id).first
        # The triple fallback only ever runs for a SOLO endpoint (group.size == 1):
        # it adopts a row ChannelDiscovery already created under a different key,
        # or repairs a changed route_key. A hub-group member must never take this
        # path, or it would silently overwrite one room's channel with another's.
        existing ||= single_route_match(endpoint, route_key) if group.size == 1
        if existing
          existing.update(attributes.merge(route_key: route_key, updated_at: @now))
          existing
        else
          @models.channel.create(
            attributes.merge(adapter: endpoint.adapter_name.to_s, account: endpoint.account.to_s,
                             route_key: route_key, created_at: @now, updated_at: @now)
          )
        end
      end

      def single_route_match(endpoint, route_key)
        @models.channel.where(adapter: endpoint.adapter_name.to_s, account: endpoint.account.to_s,
                              route_key: route_key).first
      end

      # Which endpoint in a route-key-sharing group is actually written
      # receives: true. A solo endpoint or a hub group with at most one true
      # claimant is written exactly as authored; a real conflict (more than
      # one claiming receives: true) is resolved the same way
      # Adapter#receiving_endpoint's own boot-time "first claimant wins"
      # tolerates it, so seeded rows match live inbound resolution and never
      # collide on the channels_route_receiving_idx unique index.
      def receives_for(endpoint, group)
        return endpoint.receives? if group.size <= 1

        receiving = group.select(&:receives?)
        return endpoint.receives? if receiving.size <= 1

        receiving.first.id == endpoint.id
      end

      def upsert_room_channel(room_row, channel)
        return if @models.room_channel.where(room_id: room_row.id, channel_id: channel.id).first

        @models.room_channel.create(room_id: room_row.id, channel_id: channel.id, created_at: @now)
      end

      def seed_people_and_operators(community)
        merged_people.each { |entry| find_or_create_person(community, entry) }
        @model.operators.operators.each { |operator| upsert_operator(community, operator) }
      end

      # Collapse the loader's people (which already folds operators in as people,
      # so the same human can appear twice) into one entry per human, matched by
      # a shared identity or handle.
      def merged_people
        @model.people.people.each_with_object([]) do |person, merged|
          entry = find_merge_target(merged, person) || new_merge_entry(person, merged)
          absorb(entry, person)
        end
      end

      def new_merge_entry(person, merged)
        entry = { name: person.name, identities: Hash.new { |h, k| h[k] = [] },
                  handles: Hash.new { |h, k| h[k] = [] } }
        merged << entry
        entry
      end

      def find_merge_target(merged, person)
        merged.find do |entry|
          person.identities.any? { |adapter, ids| ids.any? { |id| entry[:identities][adapter].include?(id) } } ||
            (compatible_identities?(entry, person) &&
              person.handles.any? { |adapter, hs| hs.any? { |h| entry[:handles][adapter].include?(h) } })
        end
      end

      # A shared label cannot join two explicitly different platform accounts.
      def compatible_identities?(entry, person)
        person.identities.all? do |adapter, ids|
          known = entry[:identities][adapter]
          known.empty? || ids.empty? || !(known & ids).empty?
        end
      end

      def absorb(entry, person)
        person.identities.each do |adapter, ids|
          ids.each { |id| entry[:identities][adapter] << id unless entry[:identities][adapter].include?(id) }
        end
        person.handles.each do |adapter, hs|
          hs.each { |h| entry[:handles][adapter] << h unless entry[:handles][adapter].include?(h) }
        end
      end

      def find_or_create_person(community, entry)
        person = find_person(community, entry)
        if person
          person.update(name: entry[:name], updated_at: @now)
        else
          person = @models.person.create(community_id: community.id, name: entry[:name],
                                          created_at: @now, updated_at: @now)
        end
        rewrite_identities(person, entry)
        person
      end

      def find_person(community, entry)
        entry[:identities].each do |adapter, ids|
          ids.each do |id|
            found = person_in_community(community, adapter: adapter.to_s, native_id: config_native_id(adapter, id))
            return found if found
          end
        end
        return nil if entry[:identities].values.any? { |ids| !ids.empty? }

        entry[:handles].each do |adapter, handles|
          handles.each do |handle|
            found = person_in_community(community, adapter: adapter.to_s, username: handle)
            return found if found
          end
        end
        @models.person.where(community_id: community.id, name: entry[:name]).first
      end

      def person_in_community(community, adapter:, native_id: nil, username: nil)
        scope = @models.person_identity.where(adapter: adapter)
        scope = scope.where(username: username) unless username.nil?
        identities = native_id.nil? ? scope.all : Security::GrantIdentity.exact_rows(scope, native_id: native_id)
        identities.each do |identity|
          person = @models.person[identity.person_id]
          return person if person && person.community_id == community.id
        end
        nil
      end

      # Identities are fully derived from the config, so the cleanest idempotent
      # write is to replace this person's identity rows wholesale. They have no
      # inbound foreign keys, so this is safe.
      def rewrite_identities(person, entry)
        claimed = claimed_accounts(person)
        @models.person_identity.where(person_id: person.id).delete
        identity_rows(entry).each do |row|
          held = row[:native_id].nil? ? claimed[[row[:adapter], row[:username]]] : nil
          @models.person_identity.create(
            person_id: person.id, community_id: person.community_id, adapter: row[:adapter],
            native_id: row[:native_id] || held&.first, username: row[:username],
            claimed_at: held&.last, created_at: @now
          )
        end
      end

      # A handle already bound to an account keeps that binding
      # through a reseed, since rewriting it away would hand the handle back to
      # whoever holds it next. An id written in the config still wins, so
      # correcting a bad claim is a config edit.
      #
      # @return [Hash{Array(String, String) => Array(String, Time)}]
      def claimed_accounts(person)
        @models.person_identity.where(person_id: person.id)
               .each_with_object({}) do |row, held|
          next if row.native_id.to_s.empty?

          held[[row.adapter.to_s, row.username]] = [row.native_id, row.claimed_at]
        end
      end

      # Pair native ids with usernames per adapter into identity rows. A row can
      # carry both (a Telegram id and its handle), only an id (Discord), or only
      # a handle (a Telegram @mention with no id).
      def identity_rows(entry)
        adapters = (entry[:identities].keys + entry[:handles].keys).uniq
        adapters.flat_map do |adapter|
          ids = entry[:identities][adapter]
          names = entry[:handles][adapter]
          count = [ids.size, names.size, 1].max
          (0...count).filter_map do |i|
            next nil if ids[i].nil? && names[i].nil?

            { adapter: adapter.to_s, native_id: config_native_id(adapter, ids[i]), username: names[i] }
          end
        end
      end

      def config_native_id(adapter, id)
        return id unless adapter.to_s == "xmpp" && !id.nil?

        Security::GrantIdentity.grant_native_id(adapter: adapter, native_id: id) ||
          raise(Security::GrantIdentity::Invalid, "XMPP operator identities need a bare account JID")
      end

      def upsert_operator(community, operator)
        person = find_operator_person(community, operator)
        return if person.nil?

        attributes = {
          actions: dump(operator.actions == :all ? "all" : operator.actions.map(&:to_s)),
          scope: dump(operator.rooms == :all ? "all" : operator.rooms.map(&:to_s)),
          granted_by: "bootstrap",
          granted_at: @now
        }
        existing = @models.operator.where(community_id: community.id, person_id: person.id).first
        if existing
          existing.update(attributes)
        else
          @models.operator.create(attributes.merge(community_id: community.id, person_id: person.id))
        end
      end

      def find_operator_person(community, operator)
        operator.identities.each do |adapter, ids|
          ids.each do |id|
            found = person_in_community(community, adapter: adapter.to_s, native_id: config_native_id(adapter, id))
            return found if found
          end
        end
        nil
      end

      def seed_features(community)
        upsert_feature(community, feature: "bridge", enabled: true, config: {})
        # The operator request/approval flow is on by default: it gates the whole
        # admin surface, and a seeded community always has the seeded operator as
        # its bootstrap approver. No notify_room is set here.
        upsert_feature(community, feature: "operator_requests", enabled: true, config: {})
        # The same directory question Core::Runtime#commands_enabled? asks
        # directly: an empty static operators: block says nothing about who is
        # an operator once a control plane holds them instead, so this must not
        # gate on it the way Config::Model#moderation_enabled? does.
        upsert_feature(community, feature: "moderation", enabled: @model.commands.fetch(:enabled, true), config: {
                         Core::CommandAck::TTL_FIELD => @model.commands.fetch(:cleanup_after, 0).to_i
                       })
      end

      # room_id is left NULL: these are community-wide defaults. A SQL unique index
      # treats NULLs as distinct, so idempotency is enforced here by find-or-create
      # rather than by the index.
      #
      # config is merged onto whatever is already stored, the same read-modify-write
      # {ControlPlane::FeatureControls#set} uses, rather than replacing the column
      # outright: a key this seed never sets (an operator's own dashboard edit, say)
      # survives a reseed instead of being silently wiped back to unset.
      def upsert_feature(community, feature:, enabled:, config:)
        existing = @models.feature_setting
                          .where(community_id: community.id, room_id: nil, feature: feature).first
        if existing
          merged = existing.json_value(:config).merge(stringify_keys(config))
          existing.update(enabled: enabled, config: dump(merged), updated_at: @now)
        else
          @models.feature_setting.create(
            community_id: community.id, room_id: nil, feature: feature, enabled: enabled,
            config: dump(config), created_at: @now, updated_at: @now
          )
        end
      end

      # {#upsert_feature} merges the seeded config onto a hash read back with
      # string keys ({Models::JsonColumn#json_value}), so the seeded side needs
      # the same key type or every seeded key would duplicate under both spellings.
      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      # The route_key a seeded endpoint carries, read from the owning adapter
      # rather than special-cased here, so it always matches what a live
      # discovery sweep of the identical channel would write.
      def route_key_for(endpoint)
        Adapters::Registry.fetch(endpoint.adapter_name).route_key_for(endpoint)
      end

      # The coarse space id used by platform_connections: exactly what a live
      # discovery sweep of the same platform reports as external_id, so a
      # seeded connection and a later discovery sweep resolve to the same row
      # instead of drifting into two. Discord, Fluxer and Stoat scope by
      # guild/server, which is optional in the endpoint schema, so an
      # unresolved one gets a per-community sentinel until a resolver fills it
      # in on a later boot.
      def space_external_id(endpoint)
        case endpoint.adapter_name
        when :telegram
          endpoint.settings[:chat_id].to_s
        when :discord, :fluxer
          endpoint.settings[:guild_id]&.to_s || "unresolved:#{@slug}"
        when :stoat
          endpoint.settings[:server_id]&.to_s || "unresolved:#{@slug}"
        when :xmpp
          Adapters::Xmpp::Adapter.muc_domain(endpoint.settings[:room_jid])
        when :matrix, :api_wrapper
          endpoint.account.to_s
        when :irc
          endpoint.id
        else
          raise Rubotty::Error,
                "Seed#space_external_id: no space mapping for adapter #{endpoint.adapter_name.inspect}"
        end
      end

      def display_template(template, fallback)
        out = {}
        out["format"] = template unless template.nil?
        out["fallback_format"] = fallback unless fallback.nil?
        out
      end

      def dump(value) = Models.dump_json(value)
    end
  end
end
