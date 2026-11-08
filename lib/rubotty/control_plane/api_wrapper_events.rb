# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # The queue behind the api_wrapper adapter's inbound half: the table the
    # REST API process and the running bot share for what a remote
    # integration posts in. Modelled on {ApiMessages}, except several
    # credentialed accounts run side by side, so every row is stamped with
    # its account. The API process appends through the #enqueue_* methods;
    # {Adapters::ApiWrapper::Adapter}'s receive loop drains and DELETES each
    # row. A row's own id outlives the row: it becomes the message's public
    # id and later its +MessageRef+ native id in the router's message map.
    class ApiWrapperEvents
      # What a message body may run up to.
      MAX_BODY = 4_000

      # Attachments carried by one message, mirroring
      # {ControlPlane::GuestFeed}'s own ceiling for the same reason: a
      # reasonable cap with no real platform behind it to justify a larger one.
      MAX_ATTACHMENTS = 10

      # How long a queued row may sit undrained before the bot's receive loop
      # gives up on it, matching {ApiMessages::MAX_WAIT_SECONDS}.
      MAX_WAIT_SECONDS = 3600

      KIND_MESSAGE = "message"
      KIND_EDIT = "edit"
      KIND_DELETE = "delete"
      KIND_REACTION_ADD = "reaction_add"
      KIND_REACTION_REMOVE = "reaction_remove"

      # A member arriving or going. Carried here rather than as a chat line
      # because a game server's stream is mostly this, and a room that renders
      # it as somebody talking cannot tell the two apart.
      KIND_JOIN = "join"
      KIND_LEAVE = "leave"

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, clock: -> { Time.now })
        @models = models
        @clock = clock
      end

      # Queue a new message. Its own row id is the public message id the
      # caller hands back to the remote integration.
      #
      # @param author [Hash] native_id:, display_name:, avatar_url:
      # @param attachments [Array<Hash>] url:, filename:, mime_type:, kind:, caption:
      # @return [Models::ApiWrapperPendingEvent]
      def enqueue_message(account:, channel_id:, body:, author:, reply_to: nil, attachments: [])
        row(
          account: account, kind: KIND_MESSAGE, channel_id: channel_id,
          reply_to_native_id: presence(reply_to), body: body.to_s[0, MAX_BODY],
          author: author, attachments: encode_attachments(attachments)
        )
      end

      # Queue an edit of a previously created message.
      def enqueue_edit(account:, channel_id:, target_native_id:, body:, author:)
        row(
          account: account, kind: KIND_EDIT, channel_id: channel_id,
          target_native_id: target_native_id.to_s, body: body.to_s[0, MAX_BODY], author: author
        )
      end

      # Queue a delete of a previously created message.
      def enqueue_delete(account:, channel_id:, target_native_id:, author:)
        row(
          account: account, kind: KIND_DELETE, channel_id: channel_id,
          target_native_id: target_native_id.to_s, author: author
        )
      end

      # Queue a reaction placed on, or taken off, a previously created message.
      #
      # @param reaction [Hash] emoji:, custom_id:, custom_name:
      def enqueue_reaction_add(account:, channel_id:, target_native_id:, author:, reaction:)
        enqueue_reaction(KIND_REACTION_ADD, account: account, channel_id: channel_id,
                                            target_native_id: target_native_id, author: author, reaction: reaction)
      end

      def enqueue_reaction_remove(account:, channel_id:, target_native_id:, author:, reaction:)
        enqueue_reaction(KIND_REACTION_REMOVE, account: account, channel_id: channel_id,
                                               target_native_id: target_native_id, author: author,
                                               reaction: reaction)
      end

      # Queue a member arriving in a channel. The member is the row's author:
      # there is nobody else a join is about, and every other kind already
      # carries who acted in the same place.
      def enqueue_join(account:, channel_id:, author:)
        row(account: account, kind: KIND_JOIN, channel_id: channel_id, author: author)
      end

      # Queue a member leaving a channel.
      def enqueue_leave(account:, channel_id:, author:)
        row(account: account, kind: KIND_LEAVE, channel_id: channel_id, author: author)
      end

      # One account's backlog, oldest first, capped. Every row present is
      # still waiting: the drain deletes what it emits.
      def pending(account:, limit: 200)
        scope(account).order(:id).limit(limit).all
      end

      # Drop a row: both how an event is claimed on its way out and how an
      # undeliverable one is given up on.
      def retire(row)
        row.delete
      end

      # Whether a queued row has waited past {MAX_WAIT_SECONDS}.
      def expired?(row, now: @clock.call)
        now - row.created_at > MAX_WAIT_SECONDS
      end

      # The attachment descriptors a queued row carries, decoded back into
      # plain hashes, string keyed.
      def attachments_of(row)
        parsed = JSON.parse(row.attachments.to_s)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []
      end

      private

      def scope(account) = @models.api_wrapper_pending_event.where(account: account.to_s)

      def enqueue_reaction(kind, account:, channel_id:, target_native_id:, author:, reaction:)
        row(
          account: account, kind: kind, channel_id: channel_id,
          target_native_id: target_native_id.to_s, author: author,
          reaction_emoji: presence(reaction[:emoji]),
          reaction_custom_id: presence(reaction[:custom_id]),
          reaction_custom_name: presence(reaction[:custom_name])
        )
      end

      def row(account:, kind:, channel_id:, author:, target_native_id: nil, reply_to_native_id: nil,
              body: nil, attachments: nil, reaction_emoji: nil, reaction_custom_id: nil,
              reaction_custom_name: nil)
        @models.api_wrapper_pending_event.create(
          account: account.to_s, kind: kind, channel_id: channel_id.to_s,
          target_native_id: target_native_id, reply_to_native_id: reply_to_native_id,
          author_native_id: presence(author[:native_id]), author_display_name: presence(author[:display_name]),
          author_avatar_url: presence(author[:avatar_url]),
          body: body, attachments: attachments,
          reaction_emoji: reaction_emoji, reaction_custom_id: reaction_custom_id,
          reaction_custom_name: reaction_custom_name,
          created_at: @clock.call
        )
      end

      def encode_attachments(attachments)
        list = Array(attachments).first(MAX_ATTACHMENTS).map do |a|
          { "url" => a[:url].to_s, "filename" => a[:filename], "mime_type" => a[:mime_type],
            "kind" => a[:kind], "caption" => a[:caption] }.compact
        end
        list.empty? ? nil : JSON.generate(list)
      end

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
