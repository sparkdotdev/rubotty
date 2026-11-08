# frozen_string_literal: true

require "digest"

module Rubotty
  module Features
    # Links rooms as live translations of each other: a room joins a translation GROUP by
    # declaring its own language and a group name, and every other room sharing that group
    # gets what this one says translated into its own language. The LibreTranslate
    # connection itself lives in {Translation::Settings} instead, deployment-wide and
    # admin-only; this feature only resolves peers and enqueues, so {Features::Bridge}
    # still relays the original untouched even when LibreTranslate is slow or down. See
    # {Translation::Relay} for how a translated copy is kept from looping back through
    # the group.
    class Translation < Base
      include AdapterLookup

      def self.feature_name = "translation"

      def self.description =
        "Links rooms as live translations of each other through LibreTranslate: a message posted " \
        "in one room's language is translated into every other room sharing its group."

      def self.default_enabled? = false

      def self.retention_notice =
        "Message text, formatting, and attachments are kept only in the pending translation job " \
        "while a peer room's copy is being prepared, then discarded."

      def self.observes = %i[chat edit]

      def self.config_schema
        Config::Schema.define do
          field :language, :string,
                desc: "this room's own language, as a LibreTranslate code (\"en\", \"pt\"). A room " \
                      "with no language set cannot join a group, whatever group is set below."
          field :group, :string,
                desc: "the translation group this room belongs to. Every OTHER room in the same " \
                      "community carrying the same group and a language of its own gets this " \
                      "room's messages translated into that language, and this room gets theirs. " \
                      "A group of two rooms is the ordinary pairing; three or more work the same way."
        end
      end

      # How long a "this message is already queued" claim lives. Only needs
      # to outlast the moment a redelivered event can plausibly repeat, not
      # the message's whole life.
      CLAIM_TTL = 300

      # @param adapters [Hash, nil] needed only to label the original
      #   platform for attribution; nil is fine wherever +relay+ is too
      # @param storage [Storage::Base, nil] the same exactly-once claim {Bridge}
      #   uses, under its own operation key so the two features never collide. A
      #   storage outage fails open: a duplicate translation a member can ignore.
      # @param relay [Translation::Relay, nil] where a translation is asked
      #   for. nil (no durable scheduler behind it) makes the whole feature
      #   inert, the same degrade every other durable-job feature takes.
      def initialize(logger:, adapters: nil, storage: nil, relay: nil)
        @logger = logger
        @adapters = adapters
        @storage = storage
        @relay = relay
      end

      attr_reader :logger

      def call(context)
        return Outcome.continue([]) if @relay.nil?

        message = context.message
        return Outcome.continue([]) if message.synthetic?

        case message.kind
        when :chat then on_chat(context)
        when :edit then on_edit(context)
        end
        Outcome.continue([])
      end

      private

      Membership = Struct.new(:language, :group, keyword_init: true)
      Peer = Struct.new(:room, :language, keyword_init: true)

      def on_chat(context)
        message = context.message
        return if message.empty?

        room = room_of(context)
        mine = membership_for(context, room)
        return if mine.nil?

        peers = peers_for(context, room, mine)
        return if peers.empty?

        # One claim per MESSAGE, not per peer: two overlapping instances (a
        # zero-downtime deploy, a redelivered gateway event) must queue this
        # message's whole fan-out at most once, the same guarantee {Bridge}
        # gives its own relay for the same reason.
        return unless claim(message.ref, "new", context)

        label = attribution_for(message)
        peers.each do |peer|
          @relay.enqueue_new(
            source_ref: message.ref, source_language: mine.language,
            target_room: peer.room, target_language: peer.language,
            body: message.body, attachments: message.attachments,
            sender_label: label, author_id: message.author&.native_id,
            origin_adapter: message.origin.adapter_name, community: context.community&.slug
          )
        end
      rescue StandardError => e
        logger.warn { "translation: could not queue #{context.message.ref}: #{e.class}: #{e.message}" }
      end

      def on_edit(context)
        message = context.message
        mine = membership_for(context, room_of(context))
        return if mine.nil?

        # The text digest is part of the claim key, mirroring Bridge's own
        # edit_operation: each distinct edit wins its own claim and queues,
        # while the same edit redelivered a second time no-ops.
        digest = Digest::SHA256.hexdigest(message.body.text.to_s)[0, 16]
        return unless claim(message.ref, "edit:#{digest}", context)

        @relay.enqueue_edit(
          source_ref: message.ref, source_language: mine.language,
          text: message.body.text, spans: dump_spans(message.body),
          community: context.community&.slug
        )
      rescue StandardError => e
        logger.warn { "translation: could not queue an edit for #{context.message.ref}: #{e.class}: #{e.message}" }
      end

      # Own operation prefix keeps this claim on a distinct key from
      # anything {Bridge} claims for the SAME message ref, so the two
      # features' exactly-once guarantees never fight over one row.
      def claim(ref, operation, context)
        return true if @storage.nil?

        @storage.claim_relay(source: ref, operation: "translation:#{operation}",
                             community: context.community&.id, expires_at: Time.now + CLAIM_TTL)
      rescue StandardError => e
        logger.warn { "translation: claim for #{ref}/#{operation} failed, queuing anyway: #{e.class}: #{e.message}" }
        true
      end

      def room_of(context)
        context.rooms&.find { |room| room.include?(context.message.origin.id) }
      end

      # This room's own membership: the language and group it declared,
      # resolved through the same channel-to-room indirection {Bridge} and
      # {Redirection} use, since feature_enabled?/feature_config are keyed by
      # channel rather than by room. nil for a room with no language, no
      # group, or the feature off here.
      def membership_for(context, room)
        return nil if room.nil? || context.community.nil?

        key = room_key_for(context.community, room)
        return nil if key.nil?
        return nil unless context.community.feature_enabled?(key, self.class.feature_name)

        config = context.community.feature_config(key, self.class.feature_name) || {}
        language = presence(config_value(config, :language))
        group = presence(config_value(config, :group))
        return nil if language.nil? || group.nil?

        Membership.new(language: language, group: group)
      end

      # Every OTHER room in this community sharing +mine+'s group, with the
      # language each declared for itself. A group of two rooms answers one
      # peer; three answers two; the fan out and the loop defence are the
      # same either way; see {Translation::Relay}.
      def peers_for(context, room, mine)
        context.community.rooms.filter_map do |candidate|
          next nil if candidate.unique_id == room.unique_id

          theirs = membership_for(context, candidate)
          next nil if theirs.nil? || theirs.group != mine.group

          Peer.new(room: candidate, language: theirs.language)
        end
      end

      def room_key_for(community, room)
        return nil unless community.respond_to?(:room_key_of)

        room.endpoints.map(&:id).find { |id| community.room_key_of(id) == room.id }
      end

      # Who to show as having said this, on whatever platform a peer room's
      # endpoints render a sender label on at all: the ORIGINAL author,
      # tagged with the origin platform, exactly the label {Bridge} builds
      # for an ordinary cross-platform relay. A translated copy is not the
      # bot speaking, and must never read as though it were. A bridged
      # nickname depends on the target, so {Translation::Relay} adds it.
      def attribution_for(message)
        Core::SenderLabel.for(
          author: message.author, platform: origin_platform_label(message.origin),
          protocol: origin_protocol(message.origin)
        )
      end

      def origin_platform_label(origin)
        adapter = adapter_for(origin)
        label = adapter.origin_label(origin) if adapter.respond_to?(:origin_label)
        label || origin.adapter_name.to_s
      rescue StandardError
        origin.adapter_name.to_s
      end

      def origin_protocol(origin)
        adapter = adapter_for(origin)
        return nil unless adapter.respond_to?(:origin_protocol)

        adapter.origin_protocol(origin)
      rescue StandardError
        nil
      end

      def dump_spans(body)
        body.spans.map do |span|
          { "kind" => span.kind.to_s, "from" => span.begin_index, "to" => span.end_index,
            "attributes" => span.attributes }
        end
      end

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end
    end
  end
end
