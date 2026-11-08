# frozen_string_literal: true

module Rubotty
  module Adapters
    # The REST-API platform adapter: the bot side of
    # `POST /communities/:slug/rooms/:room_key/messages`, modelled on
    # {Adapters::Guest}'s inbound half so an API post gets ordinary moderation
    # like any member's message. Posts queue in api_pending_messages and drain
    # via {Adapter#receive_pending}; nothing is ever delivered outward, it is
    # synthesised with `sends: false`.
    module Api
      # The fixed adapter name and the single account every API endpoint shares.
      NAME = :api
      ACCOUNT = "api"

      # The native id this adapter reports as "signed in as", for the loop guard.
      # A post is authored by the client, so this only has to be stable and
      # distinct from any real user id.
      OWN_ID = "rubotty-api"

      # Built from the room's database id, never its room_key string, for the
      # reason {Adapters::Guest.endpoint_key_for} sets out: room_key is unique only
      # within a community, so such a key collides across communities.
      def self.endpoint_key_for(room_id)
        "api:#{room_id}"
      end

      # Whether an endpoint key names an API endpoint.
      def self.api_key?(endpoint_key)
        endpoint_key.to_s.start_with?("api:")
      end

      class Adapter < Adapters::Base
        # Seconds between receive-loop passes; each pass is one indexed range scan.
        POLL_INTERVAL = 1

        # How long #stop waits for the poll thread to notice @running went
        # false and exit on its own, before killing it. A kill can land
        # between relay's claim and its emit and drop a post for good, so a
        # graceful join is the only safe way to stop this thread.
        JOIN_TIMEOUT = 5

        class << self
          def adapter_name = NAME

          # An API endpoint carries no credentials; the schema only satisfies the
          # contract.
          def account_schema = Config::Schema.define {}

          def endpoint_schema
            Config::Schema.define do
              field :room_key, :string, desc: "the room this API endpoint fronts"
              field :room_id, :integer, desc: "the control-plane room id"
              field :channel_endpoint_key, :string,
                    desc: "a real channel bridged into the room, used to resolve moderation scope"
              field :community_id, :integer, desc: "the owning community id"
            end
          end
        end

        # Plain text in one direction and nothing else: this adapter renders
        # nothing, so a capability claimed here would only mislead.
        CAPABILITIES = Capabilities.new.freeze

        # Constructed directly by the bot, so it takes services instead of settings.
        #
        # @param registry [ControlPlane::Registry] resolves a queued post's
        #   room to its API endpoint in the current topology
        # @param actions [ControlPlane::ApiMessageActions, nil] the queue
        #   behind the room-level react/edit/delete routes, drained
        #   independently of +messages+; nil (no control plane) makes that
        #   half a no-op
        def initialize(dispatcher:, messages:, models:, registry:, logger:, actions: nil)
          super(account: ACCOUNT, settings: {}, dispatcher: dispatcher, logger: logger)
          @messages = messages
          @models = models
          @registry = registry
          @actions = actions
          @running = false
          @thread = nil
        end

        def origin_label(_endpoint = nil) = Core::SenderLabel::API_DOMAIN

        def own_account_id = OWN_ID

        def capabilities = CAPABILITIES

        # Drain anything already queued once, then poll. Returns promptly.
        def start
          return self if @running

          @running = true
          receive_pending
          @thread = Thread.new do
            Thread.current.name = "api-adapter"
            while @running
              sleep(POLL_INTERVAL)
              receive_pending
            end
          end
          self
        end

        # Emit every pending post and every pending react/edit/delete once.
        # Two independent passes, each with its own rescue, so a bad row (or a
        # bad table) in one queue never costs the other its turn.
        def receive_pending
          drain_messages
          drain_actions
        end

        def stop
          @running = false
          @thread&.join(JOIN_TIMEOUT)
          @thread&.kill
          @thread = nil
          self
        end

        def running? = @running

        # Nothing is ever delivered to an API endpoint: it is synthesised with
        # `sends: false`, so {Core::Room#targets_for} never returns it.
        # NOT_APPLICABLE is the deliberately declined answer; a bare nil is what
        # {Features::Bridge} reports and counts as a lost message.
        def deliver(_message, _endpoint) = Core::DeliveryReceipt::NOT_APPLICABLE

        private

        def drain_messages
          @messages.pending.each { |row| relay(row) }
        rescue StandardError => e
          logger.warn { "api adapter receive pass failed: #{e.class}: #{e.message}" }
        end

        # Never raises, and a no-op with no control plane: {ControlPlane::Boot}
        # only ever hands a real queue to a process running against one, the
        # same "nil disables the route" reasoning every other optional
        # dependency in this class follows.
        def drain_actions
          return if @actions.nil?

          @actions.pending.each { |row| relay_action(row) }
        rescue StandardError => e
          logger.warn { "api adapter action receive pass failed: #{e.class}: #{e.message}" }
        end

        # Emit one queued post, taking the row immediately before the emit and
        # never on the way in: a claimed row never comes back, so the post a client
        # was told was queued would be gone for good.
        #
        # Three bounded things end a post's life unsent: it waited past
        # ApiMessages::MAX_WAIT_SECONDS, its room is gone, or the pipeline screened
        # it.
        def relay(row)
          if @messages.expired?(row)
            logger.warn { "api post #{row.id} waited too long to be routed and was dropped unsent" }
            @messages.retire(row)
            return
          end

          if @models.room[row.room_id].nil?
            @messages.retire(row)
            return
          end

          endpoint = api_endpoint_for(row.room_id)
          if endpoint.nil?
            logger.warn do
              "api post #{row.id} is waiting: room #{row.room_id} has no api endpoint in the current " \
                "snapshot (the room has no channels yet, or the snapshot has not reloaded since it gained one)"
            end
            return
          end

          message = api_message(endpoint, row)
          @messages.retire(row)
          emit(message)
        rescue StandardError => e
          logger.warn { "api post #{row.id} could not be relayed: #{e.class}: #{e.message}" }
        end

        # The API endpoint for a room from the current snapshot, or nil when the
        # room has no channels or the community is suspended.
        def api_endpoint_for(room_id)
          @registry.current.topology.endpoint(Api.endpoint_key_for(room_id))
        end

        # A queued post as a canonical message, authored by the posting credential.
        # Its ref native id is the queue row id, so a screening delete has
        # something to name.
        def api_message(endpoint, row)
          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, row.id.to_s),
            origin: endpoint,
            author: Core::Author.new(
              native_id: "api-#{row.api_key_id || "unknown"}",
              display_name: row.author_label.to_s, kind: :user
            ),
            body: Core::RichText.plain(row.body.to_s),
            sender_label: Core::SenderLabel.api(label: label_of(row))
          )
        end

        # The key's own name, recovered from the "<name>@api-client" label the row
        # stores. {Core::SenderLabel.api} re-applies the domain, so it is stripped
        # here to avoid doubling it.
        def label_of(row)
          Core::SenderLabel.split(row.author_label.to_s)[1]
        end

        # Emit one queued react/edit/delete, taking the row immediately before
        # the emit, the identical claim-then-emit ordering {#relay} uses and
        # for the same reason. Its ref is built from the row's OWN message_id
        # rather than the row's own id (contrast {#api_message}): this is an
        # action ON an existing message, so the ref has to be the SAME one
        # that message's post recorded in the map, or {Features::Bridge}
        # would find no counterparts to fan out to.
        def relay_action(row)
          if @actions.expired?(row)
            logger.warn { "api message action #{row.id} waited too long to be routed and was dropped unsent" }
            @actions.retire(row)
            return
          end

          if @models.room[row.room_id].nil?
            @actions.retire(row)
            return
          end

          endpoint = api_endpoint_for(row.room_id)
          if endpoint.nil?
            logger.warn do
              "api message action #{row.id} is waiting: room #{row.room_id} has no api endpoint in the " \
                "current snapshot (the room has no channels yet, or the snapshot has not reloaded since it " \
                "gained one)"
            end
            return
          end

          message = action_message(endpoint, row)
          @actions.retire(row)
          emit(message) unless message.nil?
        rescue StandardError => e
          logger.warn { "api message action #{row.id} could not be relayed: #{e.class}: #{e.message}" }
        end

        def action_message(endpoint, row)
          case row.kind
          when ControlPlane::ApiMessageActions::KIND_EDIT then action_edit(endpoint, row)
          when ControlPlane::ApiMessageActions::KIND_DELETE then action_delete(endpoint, row)
          when ControlPlane::ApiMessageActions::KIND_REACTION_ADD
            action_reaction(endpoint, row, :reaction_add)
          when ControlPlane::ApiMessageActions::KIND_REACTION_REMOVE
            action_reaction(endpoint, row, :reaction_remove)
          end
        end

        def action_edit(endpoint, row)
          Core::Message.new(
            kind: :edit,
            ref: Core::MessageRef.new(endpoint.id, row.message_id.to_s),
            origin: endpoint,
            author: action_author(row),
            body: Core::RichText.plain(row.body.to_s),
            sender_label: Core::SenderLabel.api(label: label_of(row))
          )
        end

        def action_delete(endpoint, row)
          Core::Message.new(
            kind: :delete,
            ref: Core::MessageRef.new(endpoint.id, row.message_id.to_s),
            origin: endpoint,
            author: action_author(row)
          )
        end

        def action_reaction(endpoint, row, kind)
          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, row.message_id.to_s),
            origin: endpoint,
            author: action_author(row),
            reaction: Core::Reaction.new(
              emoji: row.reaction_emoji, custom_id: row.reaction_custom_id, custom_name: row.reaction_custom_name
            )
          )
        end

        # The same identity {#api_message} stamps a new post with: the posting
        # credential, never a foreign author, since a meta-level action is the
        # key acting on its own behalf rather than proxying somebody else's.
        def action_author(row)
          Core::Author.new(
            native_id: "api-#{row.api_key_id || "unknown"}",
            display_name: row.author_label.to_s, kind: :user
          )
        end
      end
    end
  end
end
