# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The queue behind the REST API's ROOM-level react/edit/delete routes,
    # modelled on {ApiWrapperEvents} except a row names a room-scoped message
    # id (minted by {ApiMessages#enqueue}) rather than a bridge channel_id,
    # since the caller does not know which platforms are bridged in. The API
    # appends through #enqueue_*; {Adapters::Api::Adapter}'s receive loop
    # resolves the id back to the source {Core::MessageRef} and emits an
    # ordinary edit/delete/reaction, so {Features::Bridge} fans it out with
    # the same per-target handling a native edit gets.
    class ApiMessageActions
      # What an edit's body may run up to, matching {ApiMessages::MAX_BODY}:
      # the same ceiling the original post it is amending was held to.
      MAX_BODY = 4_000

      # How long a queued row may sit undrained before the bot's receive loop
      # gives up on it, matching {ApiMessages::MAX_WAIT_SECONDS}.
      MAX_WAIT_SECONDS = 3600

      KIND_EDIT = "edit"
      KIND_DELETE = "delete"
      KIND_REACTION_ADD = "reaction_add"
      KIND_REACTION_REMOVE = "reaction_remove"

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, clock: -> { Time.now })
        @models = models
        @clock = clock
      end

      # Queue an edit of a message this room's own POST .../messages minted.
      # +message+ is the {Core::MessageRef} {Api::App#meta_message!} resolved,
      # never a bare id: the ref names the room it was minted for, which is
      # what lets the pair be checked here instead of trusted from upstream.
      #
      # @param key [Models::ApiKey, nil] the credential that asked, for the
      #   audit trail and the label the edit is attributed to
      def enqueue_edit(community:, room:, message:, body:, key: nil)
        row(community: community, room: room, kind: KIND_EDIT, message: message,
            body: body.to_s[0, MAX_BODY], key: key)
      end

      def enqueue_delete(community:, room:, message:, key: nil)
        row(community: community, room: room, kind: KIND_DELETE, message: message, key: key)
      end

      # @param reaction [Hash] emoji:, custom_id:, custom_name:
      def enqueue_reaction_add(community:, room:, message:, reaction:, key: nil)
        enqueue_reaction(KIND_REACTION_ADD, community: community, room: room, message: message,
                                            reaction: reaction, key: key)
      end

      def enqueue_reaction_remove(community:, room:, message:, reaction:, key: nil)
        enqueue_reaction(KIND_REACTION_REMOVE, community: community, room: room, message: message,
                                               reaction: reaction, key: key)
      end

      # The whole instance's backlog, oldest first, capped, the same shape
      # {ApiMessages#pending} offers: {Adapters::Api::Adapter} is the one
      # drain and it already resolves each row's own room.
      def pending(limit: 200)
        @models.api_pending_message_action.order(:id).limit(limit).all
      end

      # Drop a row: both how an action is claimed on its way out and how an
      # undeliverable one is given up on.
      def retire(row)
        row.delete
      end

      # Whether a queued row has waited past {MAX_WAIT_SECONDS}.
      def expired?(row, now: @clock.call)
        now - row.created_at > MAX_WAIT_SECONDS
      end

      private

      def enqueue_reaction(kind, community:, room:, message:, reaction:, key:)
        row(
          community: community, room: room, kind: kind, message: message, key: key,
          reaction_emoji: presence(reaction[:emoji]),
          reaction_custom_id: presence(reaction[:custom_id]),
          reaction_custom_name: presence(reaction[:custom_name])
        )
      end

      # Both pairs are held against each other before anything is written: the
      # room against its community, and the message against its room. Past this
      # row the drain routes on the room alone and neither can be recovered.
      def row(community:, room:, kind:, message:, key:, body: nil,
              reaction_emoji: nil, reaction_custom_id: nil, reaction_custom_name: nil)
        ApiRoomScope.assert_pair!(community, room)
        ApiRoomScope.assert_message!(room, message)
        @models.api_pending_message_action.create(
          community_id: community.id, room_id: room.id, api_key_id: key&.id,
          message_id: message.native_id.to_s, kind: kind, body: body,
          reaction_emoji: reaction_emoji, reaction_custom_id: reaction_custom_id,
          reaction_custom_name: reaction_custom_name,
          author_label: author_label(key), created_at: @clock.call
        )
      end

      # The rendered sender label a room will see, the identical construction
      # {ApiMessages#author_label} builds for the room-level POST: the key's
      # operator-set label, falling back to its public id, under the fixed
      # @api-client domain so it can never pass as a member of a real platform.
      def author_label(key)
        name = key&.label.to_s.strip
        name = key&.public_id.to_s if name.empty?
        name = "api" if name.empty?
        Core::SenderLabel.api(label: name).to_s[0, 200]
      end

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
