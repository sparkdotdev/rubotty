# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # Bounded, short-lived record of what a room said, kept only for rooms
    # redirection is switched on for, since a redirect needs text that only
    # Discord's own history API can otherwise supply for a relayed-in
    # message. Three bounds keep it from becoming an archive: {#record} runs
    # only where redirection is enabled, {TTL_SECONDS} is enforced by
    # {#for_room}, and {#forget} clears a row on delete. A row names the
    # endpoint posted to, not a relayed copy elsewhere; every read scopes by
    # community.
    class RedirectionWindow
      # A redirection is usually noticed after the conversation has moved on. Two
      # weeks gives an operator a usable window without turning a room's history
      # into an indefinite archive.
      TTL_SECONDS = 14 * 24 * 60 * 60

      # The durable daily sweep. Reads enforce {TTL_SECONDS} immediately; this
      # job removes expired rows from disk at the next UTC midnight.
      PRUNE_KIND = "redirection_window_prune"
      PRUNE_INTERVAL = 24 * 60 * 60

      # One retained message, projected for a reader with its body and files
      # already rebuilt, so the feature reading it never has to know the column
      # layout or the JSON shape.
      Entry = Struct.new(:id, :endpoint_id, :native_id, :author_id, :author_handle,
                         :author_name, :body, :attachments, :created_at,
                         keyword_init: true)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [Logger, nil] warns about a write that did not happen: a
      #   missing row in the middle of a run is indistinguishable later from a
      #   message nobody sent
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Keep one message, on the relay's hot path: one insert and no history
      # scan. Never raises, so a feature that is off by default cannot cost a
      # room its bridging.
      #
      # @param room_key [String] the Core::Room id, which IS the room_key
      # @return [Object, nil] the row, or nil when the write failed
      def record(community_id:, room_key:, endpoint_id:, native_id:, body:,
                 attachments: [], author_id: nil, author_handle: nil, author_name: nil)
        now = @clock.call
        row = @models.redirection_window_message.create(
          community_id: community_id,
          room_key: room_key.to_s[0, 128],
          endpoint_id: endpoint_id.to_s[0, 255],
          native_id: native_id.to_s[0, 255],
          author_id: author_id&.to_s&.slice(0, 255),
          author_handle: author_handle&.to_s&.slice(0, 200),
          author_name: author_name&.to_s&.slice(0, 200),
          body: body_text(body),
          spans: Models.dump_json(dump_spans(body)),
          attachments: Models.dump_json(Array(attachments).map { |file| file.to_h }),
          created_at: now
        )
        row
      rescue StandardError => e
        # Logged rather than swallowed silently: a hole in the middle of a run
        # cannot be spotted when the run is read back, so this is the only chance
        # of noticing one.
        @logger&.warn { "redirection window: could not keep #{endpoint_id}/#{native_id}: #{e.class}: #{e.message}" }
        nil
      end

      # Everything still kept for one room, oldest first, and none past
      # {TTL_SECONDS}. The query applies the time boundary whether or not the
      # daily sweep has reached the expired rows yet.
      #
      # @return [Array<Entry>]
      def for_room(community_id:, room_key:, now: @clock.call)
        cutoff = now - TTL_SECONDS
        rows = scope(community_id, room_key)
               .where { created_at > cutoff }
               .order(:id)
               .all
        rows.map { |row| entry_for(row) }
      end

      # Drop what is kept for one message, whatever room it was in. Called on both
      # the original and each copy, since the caller cannot tell which this holds.
      #
      # @return [Integer] rows removed
      def forget(community_id:, endpoint_id:, native_id:)
        return 0 if community_id.nil? || endpoint_id.nil? || native_id.nil?

        @models.redirection_window_message
               .where(community_id: community_id, endpoint_id: endpoint_id.to_s, native_id: native_id.to_s)
               .delete.to_i
      rescue StandardError
        0
      end

      # Drop everything past the TTL, everywhere. About the bytes on disk rather
      # than about access: {#for_room} already refuses these rows.
      #
      # @return [Integer] rows removed
      def prune(now: @clock.call)
        cutoff = now - TTL_SECONDS
        @models.redirection_window_message.where { created_at <= cutoff }.delete.to_i
      end

      private

      def scope(community_id, room_key)
        @models.redirection_window_message.where(community_id: community_id, room_key: room_key.to_s)
      end

      def body_text(body)
        return "" if body.nil?

        body.respond_to?(:text) ? body.text.to_s : body.to_s
      end

      # The same wire shape Features::Redirection writes into a move's plan, so a
      # run read back from here and one read off a platform's own history
      # serialise identically.
      def dump_spans(body)
        return [] unless body.respond_to?(:spans)

        Array(body.spans).map do |span|
          { kind: span.kind.to_s, from: span.begin_index, to: span.end_index, attributes: span.attributes }
        end
      end

      def entry_for(row)
        Entry.new(
          id: row.id, endpoint_id: row.endpoint_id, native_id: row.native_id,
          author_id: row.author_id, author_handle: row.author_handle, author_name: row.author_name,
          body: Core::RichText.new(row.body.to_s, load_spans(row.spans)),
          attachments: load_attachments(row.attachments), created_at: row.created_at
        )
      end

      def load_spans(raw)
        decode(raw).filter_map do |span|
          Core::Span.new(
            kind: span[:kind].to_s, begin_index: span[:from].to_i, end_index: span[:to].to_i,
            attributes: symbolize(span[:attributes])
          )
        rescue StandardError
          nil
        end
      end

      def load_attachments(raw)
        decode(raw).filter_map do |file|
          Core::Attachment.new(**symbolize(file))
        rescue StandardError
          nil
        end
      end

      def decode(raw)
        value = JSON.parse(raw.to_s, symbolize_names: true)
        value.is_a?(Array) ? value : []
      rescue JSON::ParserError
        []
      end

      def symbolize(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end
    end
  end
end
