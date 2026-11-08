# frozen_string_literal: true

module Rubotty
  module Core
    # A small, bounded, per-endpoint memory of the messages just seen, so a
    # `/delete` can point at one WITHOUT a reply; the message map records ids,
    # never text, so a text match needs this. A ring per endpoint, capped at
    # {#limit}, not durable: a restart forgets it. Thread-safe, because the
    # dispatcher drives several rooms concurrently.
    class RecentMessages
      # One remembered message: native id, author's native id, exact text for the
      # text match, and +endpoint_id+, the ring this entry sits in (the endpoint
      # the message was posted on, not always the one the reader is on). The
      # optional fields after +text+ (author in human terms, styled body, files)
      # exist so redirection can REPOST a message rather than merely point at one.
      Entry = Struct.new(:native_id, :author_id, :text, :author_handle, :author_name,
                         :body, :attachments, :timestamp, :endpoint_id, keyword_init: true)

      DEFAULT_LIMIT = 500

      def initialize(limit: DEFAULT_LIMIT)
        @limit = limit
        @by_endpoint = Hash.new { |hash, key| hash[key] = [] }
        @mutex = Mutex.new
      end

      attr_reader :limit

      # A message with no native id is not recorded: without it there would be
      # nothing for a later /delete to act on. Oldest entries fall off the end
      # once the endpoint's ring is full.
      def record(endpoint_id:, native_id:, author_id:, text:, author_handle: nil,
                 author_name: nil, body: nil, attachments: nil, timestamp: nil)
        return if endpoint_id.nil? || native_id.nil?

        entry = Entry.new(
          native_id: native_id.to_s, author_id: author_id&.to_s, text: text.to_s,
          author_handle: author_handle, author_name: author_name,
          body: body, attachments: attachments, timestamp: timestamp,
          endpoint_id: endpoint_id.to_s
        )
        @mutex.synchronize do
          list = @by_endpoint[endpoint_id.to_s]
          list << entry
          list.shift(list.size - @limit) if list.size > @limit
        end
        entry
      end

      # The most recent message +author_id+ wrote on +endpoint_id+, or nil. This is
      # the public "delete my own last message" target.
      def last_by(endpoint_id:, author_id:)
        return nil if author_id.nil?

        with_endpoint(endpoint_id) { |list| list.reverse_each.find { |e| e.author_id == author_id.to_s } }
      end

      # The most recent message on +endpoint_id+ whose text EXACTLY matches +text+,
      # or nil. Exact (not substring) so a moderator names one message
      # unambiguously; most-recent-wins when several are identical.
      def match_text(endpoint_id:, text:)
        needle = text.to_s
        return nil if needle.strip.empty?

        with_endpoint(endpoint_id) { |list| list.reverse_each.find { |e| e.text == needle } }
      end

      # The run of messages from +from_native_id+ to +to_native_id+ inclusive,
      # in the order they were seen, or nil when this ring cannot answer.
      #
      # nil and [] mean different things on purpose: [] means the two bracket
      # nothing; nil means at least one of the two is not in here, or the pair
      # was given in the wrong order (the ring is insertion ordered).
      def between(endpoint_id:, from_native_id:, to_native_id:)
        from = from_native_id.to_s
        to = to_native_id.to_s
        with_endpoint(endpoint_id) do |list|
          first = list.index { |entry| entry.native_id == from }
          last = list.rindex { |entry| entry.native_id == to }
          next nil if first.nil? || last.nil? || last < first

          list[first..last]
        end
      end

      private

      def with_endpoint(endpoint_id)
        @mutex.synchronize { yield(@by_endpoint[endpoint_id.to_s]) }
      end
    end
  end
end
