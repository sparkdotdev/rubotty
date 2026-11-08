# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Polls
    # Everything a poll shows the room: the card, the edit when a vote lands,
    # the repost, and the results message. Built like {Events::Announcer}.
    class Board
      include Features::AdapterLookup

      DEFAULT_NAME = "rubotty"

      # @param registry [ControlPlane::Registry, nil] nil makes every method a no-op
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] held by reference
      # @param activity [Polls::RoomActivity, nil] without one a repost never fires
      # @param storage [#record, nil] the shared message map, so a cross-platform
      #   /delete on a card resolves its copies on every other platform
      def initialize(registry:, models:, adapters:, polls:, ballot:, activity: nil,
                     logger: nil, name: DEFAULT_NAME, storage: nil)
        @registry = registry
        @models = models
        @adapters = adapters
        @polls = polls
        @ballot = ballot
        @activity = activity
        @logger = logger
        @name = name
        @storage = storage
        @timestamps = Rendering::CardTimestamps.new(registry: registry, logger: logger)
      end

      attr_reader :logger

      # Post the opening card to every endpoint in the poll's room.
      def announce_opened(poll)
        with_room(poll) do |room|
          deliver_card(room, poll, seed: true)
          @polls.mark_posted(poll: poll)
        end
      end

      # Re-render every tracked copy in place. A copy whose adapter cannot edit,
      # or that has left the live topology, is skipped.
      def refresh(poll)
        return if @registry.nil? || @models.nil?

        with_room(poll) do |room|
          endpoints = broadcast_endpoints(room).to_h { |endpoint| [endpoint.id, endpoint] }
          options = @polls.options(poll)
          votes = @ballot.by_option(poll)
          card_rows(poll).each { |row| refresh_one(endpoints, poll, row, options, votes) }
        end
      end

      # Put the card back in front of the room, only where it has scrolled out
      # of sight.
      #
      # @return [Integer] how many endpoints were reposted to
      def repost_if_buried(poll)
        return 0 if @activity.nil? || !poll.open?
        return 0 unless @activity.buried?(activity_key(poll), poll.last_posted_at)

        posted = 0
        with_room(poll) do |room|
          posted = deliver_card(room, poll, seed: true).size
          @polls.mark_posted(poll: poll) if posted.positive?
        end
        posted
      end

      # The follow-up a closed poll leaves behind: every option with everybody
      # who backed it, uncapped.
      def announce_results(poll)
        with_room(poll) do |room|
          options = @polls.options(poll)
          votes = @ballot.by_option(poll)
          broadcast_endpoints(room).each do |endpoint|
            adapter = adapter_for(endpoint)
            next if adapter.nil?

            post(adapter, endpoint, results_text(endpoint, poll, options, votes))
          end
        end
      end

      # @param ref [Core::MessageRef, nil] what an inbound reaction or reply carries
      # @return [Polls::Poll, nil]
      def poll_for_card(ref)
        return nil if @models.nil? || ref.nil?

        row = @models.poll_card.where(endpoint_id: ref.endpoint_id, native_id: ref.native_id).first
        return nil if row.nil?

        poll_row = @models.poll[row.poll_id]
        poll_row && Poll.new(poll_row)
      end

      # See Adapters::Base#card_lookup.
      def holds_card?(endpoint_id, native_id)
        return false if @models.nil?

        !@models.poll_card.where(endpoint_id: endpoint_id, native_id: native_id.to_s).empty?
      rescue StandardError => e
        logger&.warn { "polls: could not read the card table for #{endpoint_id}:#{native_id}: #{e.message}" }
        false
      end

      private

      def with_room(poll)
        return if @registry.nil?

        room = resolve_room(poll)
        return if room.nil?

        yield room
      rescue StandardError => e
        logger&.warn { "polls: broadcast for poll #{poll.id} failed: #{e.class}: #{e.message}" }
      end

      # A channel can temporarily belong to two rooms during a move. Resolve
      # the stored room identity, scoped to its owning community.
      def resolve_room(poll)
        room_row = @models.room[poll.room_id]
        if room_row.nil? || room_row.community_id != poll.community_id
          logger&.warn { "polls: poll #{poll.id} names a room that no longer exists, dropping the broadcast" }
          return nil
        end

        community = @registry.current.community_by_id(poll.community_id)
        return nil unless community&.active?

        room = community.rooms.find { |candidate| candidate.id == room_row.room_key.to_s }
        logger&.warn { "polls: room #{poll.room_id} has no live endpoints, dropping the broadcast" } if room.nil?
        room
      end

      def broadcast_endpoints(room)
        room.targets_for(nil).select do |endpoint|
          Core::CommunityScope.permit_or_log(endpoint, room.community_id, logger: logger,
                                            doing: "polls: broadcasting in room #{room.id}")
        end
      end

      def activity_key(poll)
        room_key = @models.room[poll.room_id]&.room_key
        room_key && RoomActivity.key(poll.community_id, room_key)
      end

      def deliver_card(room, poll, seed: false)
        options = @polls.options(poll)
        votes = @ballot.by_option(poll)
        refs = broadcast_endpoints(room).filter_map { |endpoint| post_card(endpoint, poll, options, votes, seed: seed) }
        link_broadcast(room, refs)
        refs
      end

      # @return [Core::MessageRef, nil] the copy that landed, or nil
      def post_card(endpoint, poll, options, votes, seed: false)
        adapter = adapter_for(endpoint)
        return nil if adapter.nil?

        receipt = post(adapter, endpoint, card_text(adapter, endpoint, poll, options, votes),
                       buttons: vote_buttons(adapter, endpoint, poll, options))
        return nil if receipt.nil?

        track_card(poll, endpoint, receipt.native_id)
        seed_reactions(adapter, endpoint, receipt.native_id, options.size) if seed
        receipt.ref
      end

      # A card is posted straight through the adapter, so without this it has no
      # message-map entry for {Features::Moderation} to resolve a /delete from.
      def link_broadcast(room, refs)
        return if @storage.nil? || refs.size < 2

        origin = refs.first
        refs[1..].each do |ref|
          @storage.record(source: origin, destination: ref, room_id: room.id, expires_at: nil)
        rescue StorageError => e
          logger&.warn { "polls: could not link broadcast copies in room #{room.id}: #{e.message}" }
        end
      end

      # --- the card ---

      def card_text(adapter, endpoint, poll, options, votes)
        lines = [heading_line(poll), detail_line(poll)]
        options.each { |option| lines << option_line(adapter, endpoint, poll, option, votes[option.id]) }
        lines << instruction_line(adapter, endpoint, poll)
        lines << closes_line(adapter, endpoint, poll)
        lines.compact.join("\n")
      end

      # One button per option where the platform has them, so Telegram gets a
      # tappable ballot in place of the keycaps its reaction whitelist refuses.
      def vote_buttons(adapter, endpoint, poll, options)
        return [] unless buttons?(adapter, endpoint)

        options.map do |option|
          Core::Button.new(
            token: VoteButtons.token_for(option.position),
            label: [OptionEmoji.for_position(option.position)&.label,
                    option_label(adapter, endpoint, poll, option)].compact.join(" ")
          )
        end
      end

      def buttons?(adapter, endpoint) = adapter.capabilities_for(endpoint).buttons?

      def heading_line(poll)
        poll.schedule? ? "Scheduling: #{poll.question}" : "Poll: #{poll.question}"
      end

      def detail_line(poll)
        detail = presence(poll.detail)
        detail && "Game: #{detail}"
      end

      def option_line(adapter, endpoint, poll, option, voters)
        emoji = OptionEmoji.for_position(option.position)
        roster = Core::VoteRoster.inline(voters, on_platform: endpoint.adapter_name)
        parts = [emoji&.label, option_label(adapter, endpoint, poll, option), roster]
        parts.compact.join(" ")
      end

      def option_label(adapter, endpoint, poll, option)
        starts_at = option.starts_at
        return option.label if starts_at.nil?

        rendered(starts_at, adapter, endpoint, poll, style: :full)
      end

      # Each platform is told the way of answering that actually works there:
      # Telegram cannot hold a keycap reaction at all, so a card that asked it
      # to react was asking for the impossible.
      def instruction_line(adapter, endpoint, poll)
        parts = [vote_instruction(adapter, endpoint, poll)].compact
        parts << reply_vote_hint(parts.empty?) if poll.reply_votes?
        parts << reply_option_hint(poll) if poll.reply_options?
        parts.empty? ? nil : parts.join(" ")
      end

      def vote_instruction(adapter, endpoint, poll)
        if buttons?(adapter, endpoint)
          lead = poll.multi_select? ? "Tap every option that works for you" : "Tap an option below to vote"
          "#{lead}, or tap one again to take it back."
        elsif adapter.capabilities_for(endpoint).reactions?
          poll.multi_select? ? "React with every option that works for you." : "React with a number to vote."
        end
      end

      def reply_vote_hint(alone)
        lead = alone ? "Reply" : "Or reply"
        "#{lead} to this message with the number or its exact text."
      end

      def reply_option_hint(poll)
        if poll.schedule?
          'Reply with a time of your own, like "tuesday 7pm", to add it.'
        else
          "Reply with new text to add an option."
        end
      end

      def closes_line(adapter, endpoint, poll)
        "Closes #{rendered(poll.closes_at, adapter, endpoint, poll, style: :both)}"
      end

      def rendered(time, adapter, endpoint, poll, style:)
        @timestamps.render(
          time, adapter: adapter, endpoint: endpoint,
          community_id: poll.community_id, tz: display_tz(poll), style: style
        )
      end

      # --- results ---

      def results_text(endpoint, poll, options, votes)
        lines = [poll.schedule? ? "Scheduling closed: #{poll.question}" : "Poll closed: #{poll.question}"]
        options.each { |option| lines << results_line(endpoint, poll, option, votes[option.id]) }
        lines.join("\n")
      end

      def results_line(endpoint, poll, option, voters)
        list = Array(voters)
        emoji = OptionEmoji.for_position(option.position)
        label = option.starts_at ? results_slot_label(poll, option) : option.label
        line = "#{emoji&.label} #{label} (#{list.size})"
        names = Core::VoteRoster.long(list, on_platform: endpoint.adapter_name)
        names ? "#{line}: #{names}" : line
      end

      # Spelled out, since a platform's live countdown token would keep counting
      # against an instant already past.
      def results_slot_label(poll, option)
        Util::EventTimestamps.full(option.starts_at, display_tz(poll))
      end

      # --- tracked copies ---

      # One tracked card per (poll, endpoint), so a vote never lands on a
      # superseded copy.
      def track_card(poll, endpoint, native_id)
        @models.poll_card.where(poll_id: poll.id, endpoint_id: endpoint.id).delete
        @models.poll_card.create(
          poll_id: poll.id, endpoint_id: endpoint.id, native_id: native_id.to_s, created_at: Time.now
        )
      rescue StandardError => e
        logger&.warn { "polls: could not record the card ref for poll #{poll.id} on #{endpoint.id}: #{e.message}" }
      end

      def card_rows(poll)
        @models.poll_card.where(poll_id: poll.id).all
      rescue StandardError => e
        logger&.warn { "polls: could not read the card refs for poll #{poll.id}: #{e.message}" }
        []
      end

      def refresh_one(endpoints, poll, row, options, votes)
        endpoint = endpoints[row.endpoint_id]
        return if endpoint.nil?

        adapter = adapter_for(endpoint)
        return if adapter.nil? || !adapter.capabilities_for(endpoint).edits?

        text = card_text(adapter, endpoint, poll, options, votes)
        message = build_message(endpoint, text, native_id: row.native_id,
                                                buttons: vote_buttons(adapter, endpoint, poll, options))
        adapter.edit(message, endpoint, row.native_id)
      rescue AdapterError => e
        logger&.warn { "polls: could not refresh the card on #{row.endpoint_id}: #{e.message}" }
      end

      # A platform that refuses a keycap outright (Telegram does) is left to its
      # own buttons, and a refusal anywhere else is logged and left.
      def seed_reactions(adapter, endpoint, native_id, count)
        return if buttons?(adapter, endpoint)
        return unless adapter.capabilities_for(endpoint).reactions?

        desired = OptionEmoji.for_count(count)
        return if desired.empty?

        adapter.sync_reactions(endpoint, native_id, desired: desired, previous: [])
      rescue AdapterError => e
        logger&.warn { "polls: could not seed the option reactions on #{endpoint.id}: #{e.message}" }
      end

      # --- delivery ---

      def post(adapter, endpoint, text, buttons: [])
        adapter.deliver(build_message(endpoint, text, buttons: buttons), endpoint)
      rescue AdapterError => e
        logger&.warn { "polls: could not post to #{endpoint.id}: #{e.message}" }
        nil
      end

      # @param native_id [String, nil] supplied only by {#refresh_one}; a fresh
      #   post gets a placeholder the adapter replaces on delivery
      def build_message(endpoint, text, native_id: nil, buttons: [])
        Core::Message.new(
          kind: :system,
          ref: Core::MessageRef.new(endpoint.id, native_id || "poll-#{SecureRandom.hex(4)}"),
          origin: endpoint,
          author: Core::Author.new(display_name: @name, kind: :system),
          body: Core::RichText.plain(text),
          buttons: buttons,
          sender_label: @name
        )
      end

      def display_tz(poll) = presence(poll.timezone) || "UTC"

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
