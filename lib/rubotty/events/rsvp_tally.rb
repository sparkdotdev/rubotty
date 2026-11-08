# frozen_string_literal: true

module Rubotty
  module Events
    # The unified RSVP tally for one event: every response recorded in
    # event_rsvps, folded together with Discord's native interested/going list
    # when the event has a Discord native mirror. Never writes to either side.
    class RsvpTally
      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared
      #   adapter map, read only to find a Discord instance for the native read
      # @param registry [ControlPlane::Registry, nil] source of the live
      #   Snapshot an event's room_id resolves through, so the native read
      #   targets the guild the room actually lives in. nil skips that
      #   resolution and falls back to the adapter's own last resort.
      # @param logger [#warn, nil]
      def initialize(models:, adapters:, registry: nil, logger: nil)
        @models = models
        @adapters = adapters
        @registry = registry
        @logger = logger
        @identities = ControlPlane::IdentityDirectory.new(models: models)
        @identity_recorder = ControlPlane::IdentityRecorder.new(directory: @identities, logger: logger)
      end

      # @param event [Events::Event]
      # @return [Hash] {in: Integer} for an affirm-mode event, {yes:, maybe:,
      #   no:} for a full-mode one, {} for "none" (RSVP is off for it)
      def for(event)
        return {} if event.rsvp_none?

        responses = merged_responses(event).values.map(&:first)
        if event.rsvp_affirm?
          { in: responses.size }
        else
          counts = responses.each_with_object(Hash.new(0)) { |value, tally| tally[value] += 1 }
          { yes: counts["yes"], maybe: counts["maybe"], no: counts["no"] }
        end
      end

      # Who answered, by response, with the handle each is shown under.
      #
      # @param event [Events::Event]
      # @return [Hash{String=>Array<Core::VoteRoster::Voter>}]
      def roster(event)
        return {} if event.rsvp_none?

        merged_responses(event).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(identity, pair), out|
          response, platform, profile = pair
          out[response] << voter_for(event, identity, platform, profile)
        end
      end

      # Everybody who said they are coming, which is who a reminder is for.
      #
      # @return [Array<Core::VoteRoster::Voter>]
      def attending(event)
        roster(event).values_at("yes", "in").compact.flatten
      end

      private

      # identity => [response, platform, profile]: ledger rows first (they
      # always win), then any native entry the ledger has not already claimed.
      def merged_responses(event)
        responses = {}
        ledger_rows(event).each { |row| responses[row.identity] = [row.response, row.platform, nil] }
        native_rows(event).each do |identity, response, profile|
          responses[identity] ||= [response, "discord", profile]
        end
        responses
      end

      # The handle and the name /find would print for this identity, both nil
      # when the directory has never seen them. A Telegram account has no
      # handle at all until its owner sets one, so the name carries most cards.
      def voter_for(event, identity, platform, profile = nil)
        row = @identities.entry(community_id: event.community_id, adapter: platform, native_id: identity)
        Core::VoteRoster::Voter.new(identity: identity, platform: platform,
                                    handle: (row && row[:username]) || profile&.dig(:username),
                                    name: (row && row[:display_name]) || profile&.dig(:display))
      rescue StandardError => e
        @logger&.warn { "events: could not resolve #{platform}:#{identity} for event #{event.id}: #{e.message}" }
        Core::VoteRoster::Voter.new(identity: identity, platform: platform, handle: nil)
      end

      def ledger_rows(event)
        @models.event_rsvp.where(event_id: event.id).all
      end

      # Discord's interested/going list, folded in as this event's own
      # affirmative response, read only when the event actually has a Discord
      # native mirror.
      def native_rows(event)
        native_id = event.native_ref("discord")
        return [] if native_id.nil?

        adapter = discord_adapter
        return [] if adapter.nil?

        endpoint = discord_endpoint(event)
        return [] if endpoint.nil?

        affirmative = event.rsvp_affirm? ? "in" : "yes"
        Array(adapter.read_native_rsvps(native_id, endpoint)).filter_map do |entry|
          identity = entry[:identity] || entry["identity"]
          next nil if identity.nil?

          profile = profile_of(entry)
          remember(event, identity.to_s, profile)
          [identity.to_s, affirmative, profile]
        end
      rescue AdapterError => e
        @logger&.warn { "events: could not read Discord's native RSVP list for event #{event.id}: #{e.message}" }
        []
      end

      # The handle and name a native entry carried, or nil when it carried
      # neither.
      def profile_of(entry)
        username = entry[:username] || entry["username"]
        display = entry[:display] || entry["display"]
        return nil if username.nil? && display.nil?

        { username: username, display: display }
      end

      # Fold a native RSVP into the directory as an ordinary sighting, so
      # somebody who has only ever clicked "interested" is still nameable
      # everywhere the directory is read. Goes through the same throttled
      # recorder the message path uses: roster() runs once per card copy per
      # refresh, so an unthrottled write here would cost a select plus an
      # update per attendee on every redraw.
      def remember(event, identity, profile)
        return if profile.nil? || event.community_id.nil?

        @identity_recorder.record_sighting(community_id: event.community_id, adapter: "discord",
                                           native_id: identity, username: profile[:username],
                                           display: profile[:display])
      rescue StandardError => e
        @logger&.warn { "events: could not record the Discord sighting for #{identity}: #{e.message}" }
      end

      def discord_adapter
        @adapters.values.find { |adapter| adapter.supports_native_events? && adapter.adapter_name.to_s == "discord" }
      end

      # +event+'s room's own Discord endpoint, which is what
      # {Adapters::Discord::Adapter#read_native_rsvps} scopes its guild by,
      # resolved the same way {Events::Announcer#resolve_room} does. nil when
      # there is no registry, the room is gone, or it bridges no Discord
      # endpoint, and the caller then reads no native list at all rather than
      # letting the adapter pick a guild for itself.
      def discord_endpoint(event)
        room = room_for(event)
        return nil if room.nil?

        room.endpoints.find { |endpoint| endpoint.adapter_name.to_s == "discord" }
      end

      def room_for(event)
        return nil if @registry.nil?

        room_row = @models.room[event.room_id]
        return nil if room_row.nil?

        community = @registry.current.community_by_id(event.community_id)
        community&.rooms&.find { |candidate| candidate.id == room_row.room_key.to_s }
      rescue StandardError => e
        @logger&.warn { "events: could not resolve the room for event #{event.id}: #{e.message}" }
        nil
      end
    end
  end
end
