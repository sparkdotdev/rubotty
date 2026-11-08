# frozen_string_literal: true

require "securerandom"
require "json"
require "uri"

module Rubotty
  module Events
    # Announces an event across its room: the card on create, the reminder
    # card when a rung fires, the cancellation notice on cancel, and an
    # outbound native mirror (Discord Guild Scheduled Events) alongside all
    # three. Nothing raises out to the caller, since a lost card must not
    # derail the row that was already written. Posted copies are recorded in
    # event_cards so a card can be edited when the tally changes and an
    # inbound reaction resolves back to its event; the inbound native
    # direction lives in {Events::NativeMirror}.
    class Announcer
      include Features::AdapterLookup

      DEFAULT_NAME = "rubotty"

      # @param registry [ControlPlane::Registry, nil] source of the live
      #   snapshot the room is resolved from; nil makes every method a no-op.
      # @param storage [#record, nil] the shared message map, so a
      #   cross-platform /delete or /pin can resolve a broadcast's copies.
      # @param clock [#call] the instant a reminder measures "how far out"
      #   from, so the duration phrase and the countdown never diverge.
      # @param native_claims [Events::NativeCreateClaims] the marker an echo of
      #   a create still in flight waits on. Shared with the mirror by default.
      def initialize(registry:, models:, adapters:, logger: nil, name: DEFAULT_NAME, storage: nil,
                     clock: -> { Time.now }, native_claims: NativeCreateClaims.shared)
        @registry = registry
        @models = models
        @adapters = adapters
        @logger = logger
        @name = name
        @storage = storage
        @clock = clock
        @native_claims = native_claims
        @rsvp_tally = RsvpTally.new(models: models, adapters: adapters, registry: registry, logger: logger)
        @timestamps = Rendering::CardTimestamps.new(registry: registry, logger: logger, clock: clock)
      end

      attr_reader :logger

      # Broadcast the card to every endpoint in the room, remembering each copy
      # in event_cards, and create a native mirror on every capable adapter.
      def announce_created(event)
        with_room(event) do |room|
          deliver_card(room, event, heading: "New event", track: true)
          mirror_create(event, room)
        end
      end

      # Re-render the card and push the new content to every native mirror on
      # file, driven by {Events::Lifecycle} when an event's fingerprint
      # moves. The re-posted card is tracked like the original, so a reader
      # who RSVPs on it is counted, and the copy it supersedes is dropped
      # rather than left as a second tracked card for the same endpoint.
      def announce_updated(event)
        with_room(event) do |room|
          deliver_card(room, event, heading: "Event updated", track: true)
          mirror_update(event, room)
        end
      end

      # A short cancellation notice to the room, and delete every native mirror.
      def announce_cancelled(event)
        with_room(event) do |room|
          deliver_cancellation(room, event)
          mirror_delete(event, room)
        end
      end

      # {Events::Reminders}' `on_fire` seam: post one reminder card.
      #
      # @param event [Events::Event]
      # @param interval [Integer] seconds before starts_at this rung fired at
      def announce_reminder(event, interval)
        with_room(event) do |room|
          deliver_reminder(room, event, interval)
        end
      end

      # {Features::EventRemindCommand}'s seam: post a reminder into every
      # endpoint of the event's own room right now, on an operator's demand
      # rather than the automated ladder, reusing the exact same
      # {#reminder_text} the automated DM builds. Unlike {#announce_reminder}
      # this goes to the room itself, not privately to each attendee.
      #
      # @return [Boolean] whether it reached at least one live endpoint
      def announce_reminder_now(event)
        with_room(event) { |room| deliver_reminder_now(room, event) } || false
      end

      # Every response to +event+, by response value, with the handle each
      # is shown under. {Features::EventsCommand}'s seam for "who's signed
      # up", the same tally {#rsvp_line} folds into a card's summary line but
      # untruncated.
      #
      # @param event [Events::Event]
      # @return [Hash{String=>Array<Core::VoteRoster::Voter>}]
      def roster(event) = @rsvp_tally.roster(event)

      # The event a posted card copy belongs to, resolved from the (endpoint,
      # native id) an inbound reaction carries: {Features::EventRsvp}'s
      # reverse lookup, so it never touches event_cards directly. nil for a
      # ref that names no tracked card.
      #
      # @param ref [Core::MessageRef]
      # @return [Events::Event, nil]
      def event_for_card(ref)
        return nil if @models.nil? || ref.nil?

        row = @models.event_card.where(endpoint_id: ref.endpoint_id, native_id: ref.native_id).first
        return nil if row.nil?

        event_row = @models.event[row.event_id]
        event_row && Event.new(event_row)
      end

      # Whether a tracked card copy sits at (endpoint_id, native_id): the
      # second source a platform's reaction-endpoint recovery consults (see
      # Adapters::Base#card_lookup) once its own message map comes up empty.
      # A card posted through #deliver leaves no relay row there.
      #
      # @param endpoint_id [String]
      # @param native_id [String]
      # @return [Boolean]
      def holds_card?(endpoint_id, native_id)
        return false if @models.nil?

        !@models.event_card.where(endpoint_id: endpoint_id, native_id: native_id.to_s).empty?
      rescue StandardError => e
        logger&.warn { "events: could not read the card table for #{endpoint_id}:#{native_id}: #{e.message}" }
        false
      end

      # Re-render the rsvp_line and push it to every tracked copy of +event+'s
      # card, so posted counts stay live. Best effort: a copy whose adapter
      # cannot edit, or that has left the live topology, is skipped.
      #
      # @param event [Events::Event]
      def refresh_rsvp(event)
        return if @registry.nil? || @models.nil?

        topology = @registry.current.topology
        card_refs(event).each { |row| refresh_one(topology, event, row) }
      end

      private

      def with_room(event)
        return if @registry.nil?

        room = resolve_room(event)
        return if room.nil?

        yield room
      rescue StandardError => e
        logger&.warn { "events: broadcast for event #{event.id} failed: #{e.class}: #{e.message}" }
      end

      # The event's room_id resolved to its live Core::Room, matched by
      # identity (community_id plus room_key), not by which live room happens
      # to contain one of its channels: a channel briefly links into both its
      # old and new room while an operator moves it, so a membership search
      # can resolve to either. room_key is scoped to +event.community_id+
      # first, so it stays unique even though two communities can otherwise
      # share a name like "general". Nil, logged, when the room is gone or
      # has no live channel.
      def resolve_room(event)
        room_row = @models.room[event.room_id]
        if room_row.nil?
          logger&.warn { "events: event #{event.id} names a room that no longer exists, dropping the broadcast" }
          return nil
        end

        community = @registry.current.community_by_id(event.community_id)
        room = community&.rooms&.find { |candidate| candidate.id == room_row.room_key.to_s }
        logger&.warn { "events: room #{event.room_id} has no live endpoints, dropping the broadcast" } if room.nil?
        room
      end

      # The room's own fan-out rule, with no origin to exclude, filtered to the
      # endpoints that really belong to +event+'s community. The room came from
      # that community's own snapshot so this should never drop anything; it is
      # the latch that makes a future path which resolves a room some other way
      # refuse rather than announce one tenant's event into another's channel.
      def broadcast_endpoints(room, event)
        room.targets_for(nil).select do |endpoint|
          Core::CommunityScope.permit_or_log(
            endpoint, event.community_id, logger: logger,
            doing: "events: announcing event #{event.id}"
          )
        end
      end

      # --- the card ---

      # @param track [Boolean] remember each copy posted in event_cards, which
      #   is what lets a reaction on it resolve back to the event. False only
      #   for the reminder card, which carries no RSVP of its own.
      def deliver_card(room, event, heading:, track: false)
        refs = []
        broadcast_endpoints(room, event).each do |endpoint|
          adapter = adapter_for(endpoint)
          next if adapter.nil?

          receipt = post(adapter, endpoint, card_text(adapter, endpoint, event, heading))
          next if receipt.nil?

          refs << receipt.ref
          track_card(event, endpoint, receipt.native_id, heading) if track
          seed_rsvp_reactions(adapter, endpoint, event, receipt.native_id)
        end
        link_broadcast(room, refs)
      end

      def card_text(adapter, endpoint, event, heading)
        lines = ["#{heading}: #{event.title}", rendered_start(adapter, endpoint, event, style: :both)]
        lines << kind_line(event)
        lines << rsvp_line(event, endpoint)
        lines.compact.join("\n")
      end

      # The event's start time for +adapter+ at +endpoint+, through the shared
      # renderer every bridge-authored card uses.
      def rendered_start(adapter, endpoint, event, style:)
        @timestamps.render(
          event.starts_at, adapter: adapter, endpoint: endpoint,
          community_id: event.community_id, tz: display_tz(event), style: style
        )
      end

      def kind_line(event)
        if event.gaming?
          detail = [event.game_title, event.server_address].select { |value| presence(value) }.join(" @ ")
          return nil if detail.empty?

          "Game: #{detail}"
        else
          detail = presence(event.url)
          return nil if detail.nil?

          http_url?(detail) ? "Link: #{detail}" : "Where: #{detail}"
        end
      end

      # Whether the value is an http or https URL, the only thing a card is
      # willing to call a link.
      def http_url?(value)
        uri = URI.parse(value)
        uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end

      # The unified tally (the ledger folded with Discord's native
      # interested/going list), or nothing at all in "none" mode, where RSVP is
      # off entirely.
      def rsvp_line(event, endpoint)
        return nil if event.rsvp_none?

        roster = @rsvp_tally.roster(event)
        platform = endpoint&.adapter_name
        if event.rsvp_affirm?
          RsvpLabels.attending_line(Core::VoteRoster.inline(roster["in"], on_platform: platform))
        else
          RsvpLabels::FULL.map do |response, label|
            "#{label} #{answer_for(roster[response], platform)}"
          end.join(", ")
        end
      end

      # Up to three handles, then a bare count, the convention
      # {Core::VoteRoster} holds for every card in the bot.
      def answer_for(voters, platform)
        Core::VoteRoster.inline(voters, on_platform: platform) || "0"
      end

      # Remember one posted card copy, so a later reaction resolves back to
      # +event+ and a refreshed tally has somewhere to go; best effort,
      # since a lost row only costs that one copy its live line. One
      # tracked card per (event, endpoint): a re-post supersedes the copy it
      # replaced, so the tally never edits a stale card. +heading+ is kept
      # alongside so {#refresh_one} can re-render under the heading this
      # copy actually went out under, rather than always "New event".
      def track_card(event, endpoint, native_id, heading)
        @models.event_card.where(event_id: event.id, endpoint_id: endpoint.id).delete
        @models.event_card.create(
          event_id: event.id, endpoint_id: endpoint.id, native_id: native_id.to_s,
          heading: heading, created_at: Time.now
        )
      rescue StandardError => e
        logger&.warn { "events: could not record the card ref for event #{event.id} on #{endpoint.id}: #{e.message}" }
      end

      # Record every copy of one broadcast as counterparts of each other in
      # the shared message map, the way Features::Bridge records a relayed
      # message's copies: without this,
      # Features::Moderation#resolve_moderation_target cannot resolve a
      # /delete or /pin against one copy to any of the others, since these
      # messages persist rather than self-delete and never join
      # Core::EphemeralMessage's group tracking either.
      def link_broadcast(room, refs)
        return if @storage.nil? || refs.size < 2

        origin = refs.first
        refs[1..].each do |ref|
          @storage.record(source: origin, destination: ref, room_id: room.id, expires_at: nil)
        rescue StorageError => e
          logger&.warn { "events: could not link broadcast copies in room #{room.id}: #{e.message}" }
        end
      end

      # Pre-seed the card with the event's RSVP reactions on any endpoint that
      # can hold reactions, so responding is one tap. Nothing to seed in "none"
      # mode.
      def seed_rsvp_reactions(adapter, endpoint, event, native_id)
        return unless adapter.capabilities_for(endpoint).reactions?

        desired = RsvpReactions.for_mode(event.rsvp_mode)
        return if desired.empty?

        adapter.sync_reactions(endpoint, native_id, desired: desired, previous: [])
      rescue AdapterError => e
        logger&.warn { "events: could not seed rsvp reactions on #{endpoint.id}: #{e.message}" }
      end

      # --- cancellation ---

      def deliver_cancellation(room, event)
        refs = []
        broadcast_endpoints(room, event).each do |endpoint|
          adapter = adapter_for(endpoint)
          next if adapter.nil?

          receipt = post(adapter, endpoint, cancellation_text(adapter, endpoint, event))
          refs << receipt.ref if receipt
        end
        link_broadcast(room, refs)
      end

      def cancellation_text(adapter, endpoint, event)
        "Event cancelled: #{event.title} (was #{rendered_start(adapter, endpoint, event, style: :full)})."
      end

      # --- reminders ---

      # Privately, to each person coming: a whole room does not want eleven
      # notices for an event most of it is not going to. The phrase is timed
      # off the live clock rather than the ladder rung that triggered this
      # call, so a job the scheduler ran late (a recovered downtime, a busy
      # tick) never tells someone an hour remains when the event already
      # started.
      def deliver_reminder(room, event, _interval)
        attending = @rsvp_tally.attending(event)
        return if attending.empty?

        endpoints = reminder_endpoints(room, event)
        live = remaining_seconds(event)
        attending.each { |voter| remind(endpoints[voter.platform.to_s], event, live, voter) }
      end

      # Posts the reminder text to every broadcast endpoint of the room, the
      # same fan-out #deliver_card uses, rather than DMing attendees.
      def deliver_reminder_now(room, event)
        interval = remaining_seconds(event)
        posted = false
        broadcast_endpoints(room, event).each do |endpoint|
          adapter = adapter_for(endpoint)
          next if adapter.nil?

          receipt = post(adapter, endpoint, reminder_text(adapter, endpoint, event, interval))
          posted ||= !receipt.nil?
        end
        posted
      end

      # Seconds left until +event+ starts, floored and never negative: the one
      # live measurement every reminder phrases its "starts in" text from, so
      # the duration phrase and the countdown beside the start time can never
      # disagree, and neither can claim time is left once the event has begun.
      def remaining_seconds(event)
        [event.starts_at.to_i - @clock.call.to_i, 0].max
      end

      # One endpoint per platform in the room, so a reminder renders the way a
      # card posted there would.
      def reminder_endpoints(room, event)
        broadcast_endpoints(room, event).each_with_object({}) do |endpoint, out|
          out[endpoint.adapter_name.to_s] ||= endpoint
        end
      end

      # A DM that cannot be delivered is logged and skipped. Falling back to the
      # channel would put back exactly the noise this removes.
      def remind(endpoint, event, interval, voter)
        adapter = endpoint && adapter_for(endpoint)
        unless adapter&.supports_admin_dm?
          logger&.info { "events: no way to DM #{voter.platform}:#{voter.identity}, reminder skipped" }
          return false
        end

        sent = adapter.send_admin_dm(voter.identity, reminder_text(adapter, endpoint, event, interval))
        return true if sent

        logger&.info { "events: #{voter.platform}:#{voter.identity} took no reminder for event #{event.id}" }
        false
      rescue StandardError => e
        logger&.warn { "events: reminder DM for event #{event.id} failed: #{e.class}: #{e.message}" }
        false
      end

      def reminder_text(adapter, endpoint, event, interval)
        lines = [
          "#{event.title} starts #{duration_phrase(interval)}",
          rendered_start(adapter, endpoint, event, style: :both)
        ]
        lines << rsvp_line(event, endpoint)
        lines.compact.join("\n")
      end

      def duration_phrase(seconds)
        amount, unit = Util::EventTimestamps.largest_unit(seconds)
        "in #{amount} #{unit}#{"s" unless amount == 1}"
      end

      # --- native scheduled events, outbound only ---

      # One native mirror per adapter INSTANCE serving the room, so two channels
      # of the same account do not create two Guild Scheduled Events for one
      # event. Adapters without native event support degrade silently.
      def mirror_create(event, room)
        native_adapters(room, event).each do |adapter, endpoint|
          # Loop prevention and idempotency: a row that already names a native
          # event on this platform was either mirrored in from it or created
          # here already, so skip both.
          next if event.native_ref(adapter.adapter_name)

          claim_native_create(event, adapter, endpoint)
        rescue AdapterError => e
          logger&.warn { "events: native create on #{adapter.adapter_name} failed: #{e.message}" }
        end
      end

      # The claim has to span the platform call AND the write, not just the
      # call: Discord pushes its gateway create before the REST reply lands, so
      # an echo arriving between the two used to find no row naming the native
      # id and mirror our own event back in as a second one.
      def claim_native_create(event, adapter, endpoint)
        @native_claims.holding(adapter.adapter_name, adapter.account) do
          native_id = adapter.create_scheduled_event(event, endpoint)
          store_native_ref(event, adapter, native_id) if native_id
        end
      end

      # Only pushes to a mirror that already exists; it does not retroactively
      # create one for an adapter that came online since.
      def mirror_update(event, room)
        each_native_ref(event, room) do |adapter, native_id, endpoint|
          adapter.update_scheduled_event(native_id, event, endpoint)
        rescue AdapterError => e
          logger&.warn { "events: native update on #{adapter.adapter_name} failed: #{e.message}" }
        end
      end

      def mirror_delete(event, room)
        each_native_ref(event, room) do |adapter, native_id, endpoint|
          adapter.delete_scheduled_event(native_id, endpoint)
        rescue AdapterError => e
          logger&.warn { "events: native delete on #{adapter.adapter_name} failed: #{e.message}" }
        end
        clear_native_refs(event)
      end

      # The distinct adapter instances serving the room that can mirror an
      # event natively, each paired with the room's own endpoint on it (what
      # resolves the right guild), uniqued by adapter identity so one account
      # yields one native call.
      def native_adapters(room, event)
        broadcast_endpoints(room, event).filter_map { |endpoint| adapter_pair(endpoint) }
                                  .select { |(adapter, _endpoint)| adapter.supports_native_events? }
                                  .uniq { |(adapter, _endpoint)| adapter }
      end

      def adapter_pair(endpoint)
        adapter = adapter_for(endpoint)
        adapter && [adapter, endpoint]
      end

      # Yields [adapter, native_id, endpoint] for every stored native ref. The
      # adapter comes from the shared map rather than the room's current
      # endpoints, so a cancellation still reaches a mirror after the channels
      # changed. A room that no longer bridges the platform is SKIPPED rather
      # than yielded with a nil endpoint: the endpoint is what says which
      # community's space to act in, and the adapter used to answer a nil with
      # the first space it knew of, which on a shared account meant updating or
      # deleting another tenant's object.
      def each_native_ref(event, room)
        event.native_refs.each do |platform, native_id|
          adapter = adapter_for_platform(platform)
          next if adapter.nil? || native_id.nil?

          endpoint = endpoint_for_platform(room, event, platform)
          if endpoint.nil?
            logger&.info do
              "events: room #{room.id} no longer bridges #{platform}, leaving the native mirror " \
                "for event #{event.id} alone"
            end
            next
          end
          yield adapter, native_id, endpoint
        end
      end

      def endpoint_for_platform(room, event, platform)
        broadcast_endpoints(room, event).find { |endpoint| endpoint.adapter_name.to_s == platform.to_s }
      end

      def adapter_for_platform(platform)
        @adapters.values.find { |adapter| adapter.supports_native_events? && adapter.adapter_name.to_s == platform.to_s }
      end

      def store_native_ref(event, adapter, native_id)
        refs = event.native_refs.merge(adapter.adapter_name.to_s => native_id.to_s)
        event.row.update(native_refs: JSON.generate(refs))
      rescue StandardError => e
        logger&.warn { "events: could not persist the native ref for event #{event.id}: #{e.message}" }
      end

      def clear_native_refs(event)
        return if event.native_refs.empty?

        event.row.update(native_refs: "{}")
      rescue StandardError => e
        logger&.warn { "events: could not clear the native refs for event #{event.id}: #{e.message}" }
      end

      # --- rsvp refresh ---

      def card_refs(event)
        @models.event_card.where(event_id: event.id).all
      rescue StandardError => e
        logger&.warn { "events: could not read the card refs for event #{event.id}: #{e.message}" }
        []
      end

      # Re-render and edit one tracked copy, under the heading it was actually
      # posted with: an update-driven re-post must not read back as "New
      # event" once an RSVP after it edits the tally in. The endpoint comes out
      # of the merged topology by id, so its community is checked before an
      # edit goes anywhere near it.
      def refresh_one(topology, event, row)
        endpoint = topology.endpoint(row.endpoint_id)
        return if endpoint.nil?
        return unless Core::CommunityScope.permit_or_log(
          endpoint, event.community_id, logger: logger,
          doing: "events: refreshing the card for event #{event.id}"
        )

        adapter = adapter_for(endpoint)
        return if adapter.nil? || !adapter.capabilities_for(endpoint).edits?

        text = card_text(adapter, endpoint, event, row.heading)
        adapter.edit(build_message(endpoint, text, native_id: row.native_id), endpoint, row.native_id)
      rescue AdapterError => e
        logger&.warn { "events: could not refresh the rsvp line on #{row.endpoint_id}: #{e.message}" }
      end

      # --- delivery ---

      def post(adapter, endpoint, text)
        adapter.deliver(build_message(endpoint, text), endpoint)
      rescue AdapterError => e
        logger&.warn { "events: could not post to #{endpoint.id}: #{e.message}" }
        nil
      end

      # @param native_id [String, nil] supplied only by {#refresh_one}, naming
      #   the message being edited. A fresh post gets a throwaway placeholder;
      #   the adapter assigns the real id on delivery.
      def build_message(endpoint, text, native_id: nil)
        Core::Message.new(
          kind: :system,
          ref: Core::MessageRef.new(endpoint.id, native_id || "event-#{SecureRandom.hex(4)}"),
          origin: endpoint,
          author: Core::Author.new(display_name: @name, kind: :system),
          body: Core::RichText.plain(text),
          sender_label: @name
        )
      end

      def display_tz(event) = presence(event.timezone) || "UTC"

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
