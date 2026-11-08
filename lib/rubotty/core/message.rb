# frozen_string_literal: true

require "securerandom"
require "set"

module Rubotty
  module Core
    # A globally unique handle on one message as it exists on one endpoint. `native_id`
    # is whatever the platform calls it, as a String, since Discord snowflakes exceed
    # 2^53 and would lose precision in storage and in JSON.
    class MessageRef
      attr_reader :endpoint_id, :native_id

      def initialize(endpoint_id, native_id)
        @endpoint_id = endpoint_id.to_s
        @native_id = native_id.to_s
        freeze
      end

      def to_a = [endpoint_id, native_id]

      def to_s = "#{endpoint_id}:#{native_id}"

      def ==(other) = other.is_a?(MessageRef) && other.endpoint_id == endpoint_id && other.native_id == native_id
      alias eql? ==

      def hash = [endpoint_id, native_id].hash

      def inspect = "#<MessageRef #{self}>"
    end

    # A short excerpt of the message being replied to, carried alongside the reply so
    # a target platform can quote it when a native reply is impossible.
    #
    # Captured at parse time from the payload the platform already handed us, so there
    # is no extra request and no message content at rest. The excerpt reflects the
    # parent as it was when the reply was written.
    class ReplyPreview
      attr_reader :author, :body, :label, :ref

      # @param author [Author, nil] who wrote the parent
      # @param body [RichText] the parent's text, in full
      # @param label [String, nil] rendered sender name, filled by the router
      # @param ref [MessageRef, nil] the parent on its own endpoint
      def initialize(author: nil, body: RichText.new, label: nil, ref: nil)
        @author = author
        @body = body.is_a?(RichText) ? body : RichText.plain(body.to_s)
        @label = label
        @ref = ref
        freeze
      end

      def empty? = @body.blank? && @label.nil?

      def with_label(new_label)
        self.class.new(author: author, body: body, label: new_label, ref: ref)
      end

      def with_body(new_body)
        self.class.new(author: author, body: new_body, label: label, ref: ref)
      end
    end

    # The canonical internal message. Every adapter parses inbound platform payloads
    # into this and renders outbound payloads from it. Nothing platform specific may
    # appear in a field other than +raw+. Immutable; copies come from {#with}.
    class Message
      # What happened: :edit/:delete carry the +ref+ of a previous message,
      # :join/:leave are membership, :system is anything else worth relaying,
      # and :reaction_add/:reaction_remove set +ref+, +author+, and +reaction+
      # for one actor's own claim, so loop prevention and fan out apply
      # unchanged. :reaction_sync states the whole +reaction_set+ with no
      # author or single +reaction+; :reaction_clear is a bulk, author-less
      # removal of +reaction+ (or all reactions when nil). :button_press sets
      # +ref+, +author+ and +button+ for one actor's tap on the bridge's card.
      KINDS = %i[chat edit delete join leave system reaction_add reaction_remove
                 reaction_sync reaction_clear button_press].freeze

      attr_reader :kind, :ref, :origin, :author, :body, :attachments, :reply_to,
                  :forwarded_from, :forwarded_target, :timestamp, :trace, :raw, :correlation_id, :sender_label,
                  :reply_preview, :reaction, :reaction_set, :button, :buttons, :thread,
                  :thread_notice, :hub_target_room_id, :hub_exclude_endpoint_ids, :synthetic

      # @param reply_to [MessageRef, nil] on the ORIGIN endpoint; the router translates it per target using the map.
      # @param trace [Array<String>] endpoint ids already visited this routing operation, preventing cycles when an
      #   endpoint belongs to more than one room.
      # @param sender_label [Core::SenderLabel, String, nil] set by the router just before delivery, since it can
      #   differ per room and endpoint; adapters must never compute it themselves.
      # @param synthetic [Boolean] true only for a native Discord slash-command interaction fed into the pipeline;
      #   {Bridge} must never relay it and {CommandAck} must never schedule it for deletion alongside a reply.
      def initialize(kind:, ref:, origin:, author: nil, body: RichText.new, attachments: [],
                     reply_to: nil, forwarded_from: nil, forwarded_target: nil, timestamp: nil, trace: [],
                     raw: nil, correlation_id: nil, sender_label: nil, reply_preview: nil,
                     reaction: nil, reaction_set: [], button: nil, buttons: [], thread: nil,
                     thread_notice: nil, hub_target_room_id: nil, hub_exclude_endpoint_ids: [],
                     synthetic: false)
        @kind = kind.to_sym
        @ref = ref
        @origin = origin
        @author = author || Author.new(kind: :system)
        @body = body.is_a?(RichText) ? body : RichText.plain(body.to_s)
        @attachments = Array(attachments).freeze
        @reply_to = reply_to
        @forwarded_from = forwarded_from
        # Where the forwarded message actually lives, as a {Permalink::Target},
        # when the platform says. Usually it does not: a forward out of a
        # private group carries the words and no way to name which message they
        # came from, which makes it evidence rather than a handle.
        @forwarded_target = forwarded_target
        @timestamp = timestamp || Time.now
        @trace = Array(trace).map(&:to_s).freeze
        @raw = raw
        @correlation_id = correlation_id || SecureRandom.hex(6)
        @sender_label = sender_label
        @reply_preview = reply_preview
        @reaction = reaction
        @reaction_set = Array(reaction_set).freeze
        @button = button.nil? ? nil : button.to_s
        @buttons = Array(buttons).freeze
        @thread = thread
        @thread_notice = thread_notice
        # Hub mode short-code addressing: set by an adapter's inbound parser when the
        # text named a room by its short code, e.g. "!gs hello". Nil keeps ordinary
        # routing; when set, the bridge targets THAT room's endpoints instead.
        @hub_target_room_id = hub_target_room_id
        # Endpoint ids to skip even when {#hub_target_room_id} names a room they belong
        # to. A hub-mode adapter declares one endpoint PER BRIDGED ROOM over the SAME
        # physical channel, so without this a cross-room message comes straight back.
        @hub_exclude_endpoint_ids = Array(hub_exclude_endpoint_ids).map(&:to_s).freeze
        @synthetic = !!synthetic
        freeze
      end

      def synthetic? = @synthetic

      def chat? = kind == :chat

      def edit? = kind == :edit

      def delete? = kind == :delete

      def membership? = kind == :join || kind == :leave

      def reaction? = kind == :reaction_add || kind == :reaction_remove ||
                      kind == :reaction_sync || kind == :reaction_clear

      # A reaction update that states the whole set and attributes none of it.
      def reaction_sync? = kind == :reaction_sync

      # A bulk removal a platform reports with no author: one emoji, or the
      # whole message, gone at once.
      def reaction_clear? = kind == :reaction_clear

      # Somebody tapped a button under one of our own cards.
      def button_press? = kind == :button_press

      # A notice the BRIDGE ITSELF is saying: the startup banner, a moderation result
      # summary. It must be posted under the bot's own identity and never through a per
      # sender webhook, because loop prevention layer 2 recognises us by author id.
      def system_notice? = kind == :system && author&.system?

      def forwarded? = !forwarded_from.nil?

      # The plain "forwarded from X" sentence, or nil when this message was
      # not forwarded. The one place that wording is spelled out; every
      # outbound escapes and wraps this rather than writing it again.
      def forwarded_notice
        return nil unless forwarded?

        "forwarded from #{forwarded_from.any_name}"
      end

      def reply? = !reply_to.nil?

      # Does this message live in a sub conversation (a thread or forum topic)?
      def in_thread? = !thread.nil?

      # A reply we can show the reader even without a native reply pointer.
      def quotable_reply? = !reply_preview.nil? && !reply_preview.empty?

      def attachments? = !attachments.empty?

      # A message with neither text nor attachments carries no information and must not
      # be relayed. Only :chat, since other kinds carry their meaning in the kind.
      def empty? = body.blank? && attachments.empty? && kind == :chat

      def with(**changes)
        self.class.new(
          kind: changes.fetch(:kind, kind),
          ref: changes.fetch(:ref, ref),
          origin: changes.fetch(:origin, origin),
          author: changes.fetch(:author, author),
          body: changes.fetch(:body, body),
          attachments: changes.fetch(:attachments, attachments),
          reply_to: changes.fetch(:reply_to, reply_to),
          forwarded_from: changes.fetch(:forwarded_from, forwarded_from),
          forwarded_target: changes.fetch(:forwarded_target, forwarded_target),
          timestamp: changes.fetch(:timestamp, timestamp),
          trace: changes.fetch(:trace, trace),
          raw: changes.fetch(:raw, raw),
          correlation_id: changes.fetch(:correlation_id, correlation_id),
          sender_label: changes.fetch(:sender_label, sender_label),
          reply_preview: changes.fetch(:reply_preview, reply_preview),
          reaction: changes.fetch(:reaction, reaction),
          reaction_set: changes.fetch(:reaction_set, reaction_set),
          button: changes.fetch(:button, button),
          buttons: changes.fetch(:buttons, buttons),
          thread: changes.fetch(:thread, thread),
          thread_notice: changes.fetch(:thread_notice, thread_notice),
          hub_target_room_id: changes.fetch(:hub_target_room_id, hub_target_room_id),
          hub_exclude_endpoint_ids: changes.fetch(:hub_exclude_endpoint_ids, hub_exclude_endpoint_ids),
          synthetic: changes.fetch(:synthetic, synthetic)
        )
      end

      # Record that this message has now visited +endpoint_id+.
      def visited(endpoint_id)
        with(trace: trace + [endpoint_id.to_s])
      end

      def visited?(endpoint_id) = trace.include?(endpoint_id.to_s)

      def inspect
        "#<Message #{kind} #{ref} from=#{author.any_name.inspect} " \
          "body=#{body.text[0, 40].inspect} attachments=#{attachments.size}>"
      end
    end

    # What an adapter returns after successfully placing a message on a platform. The
    # router needs the native id for the message map entry that edit and delete read.
    class DeliveryReceipt
      attr_reader :endpoint_id, :native_id, :extra

      def initialize(endpoint_id:, native_id:, extra: {})
        @endpoint_id = endpoint_id.to_s
        @native_id = native_id.to_s
        @extra = extra.freeze
        freeze
      end

      def ref = MessageRef.new(endpoint_id, native_id)

      def to_s = "#<DeliveryReceipt #{ref}>"
      alias inspect to_s

      # Answers true, on purpose: a caller written before this existed, and
      # every one of them checks `receipt.nil?`, keeps working exactly as it
      # did when an adapter that had nothing to deliver returned a bare nil.
      # Only {Features::Bridge} tells this apart from a real nil, by identity,
      # so it can skip WITHOUT reporting a loss.
      class NotApplicable
        def nil? = true
        def to_s = "not applicable"
        alias inspect to_s
      end

      # An adapter's #deliver returns this instead of nil when there was
      # nothing to deliver BY DESIGN, such as {Adapters::Guest::Adapter}
      # finding no live guest to write to. A bare nil means something
      # different: a send was attempted and produced nothing to point an edit
      # or delete at, which {Features::Bridge} logs and reports as a loss.
      NOT_APPLICABLE = NotApplicable.new.freeze
    end

    # What Adapters::Base#send_admin_dm hands back on success: enough to
    # delete the DM later without re-resolving who it went to.
    # +channel_ref+ is whatever the platform needs besides the message id to
    # address the DM again, Telegram's chat id (which happens to equal the
    # recipient's own native id) or Discord's DM channel id (which does
    # not); nil where a platform needs nothing else. nil on failure is what
    # a bare false used to mean.
    class DmReceipt
      attr_reader :native_id, :channel_ref

      def initialize(native_id:, channel_ref: nil)
        @native_id = native_id.to_s
        @channel_ref = channel_ref.nil? ? nil : channel_ref.to_s
        freeze
      end

      def to_s = "#<DmReceipt native_id=#{native_id} channel_ref=#{channel_ref.inspect}>"
      alias inspect to_s
    end
  end
end
