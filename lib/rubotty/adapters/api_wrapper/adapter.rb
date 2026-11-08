# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Adapters
    # A remote HTTP system, bridged as a first party platform: it accepts signed
    # inbound REST calls and delivers by signed outbound webhook POST, but is
    # otherwise a full Adapters::Base subclass with the same Bridge fan-out,
    # capability negotiation and loop prevention every adapter gets. Multi-instance
    # like {Fluxer::Adapter} and {Irc::Adapter}: `accounts:` in bridge.config.yaml
    # may declare any number of api_wrapper accounts, each its own webhook_url,
    # signing secret and channel mappings, unlike the single fixed accounts
    # {Guest::Adapter} and {Api::Adapter} synthesise. See {Client} for outbound signing; inbound events queue in api_wrapper_pending_events and drain via {#receive_pending}.
    module ApiWrapper
      NAME = :api_wrapper

      # The native id this adapter reports as "signed in as", for the loop
      # guard. Every inbound message is authored by a real person on the
      # remote system, never by this id, so it only has to be stable and
      # distinct from any real user id, the same reasoning {Guest::NAME} and
      # {Api::NAME}'s own OWN_ID constants document.
      OWN_ID = "rubotty-api-wrapper"

      class Adapter < Adapters::Base
        # Seconds between receive-loop passes, matching {Guest::Adapter} and
        # {Api::Adapter}'s own polling interval.
        POLL_INTERVAL = 1

        # How long #stop waits for the poll thread to notice @running went
        # false and exit on its own, before killing it. A kill can land
        # between relay's claim and its emit and drop an event for good, so a
        # graceful join is the only safe way to stop this thread.
        JOIN_TIMEOUT = 5

        class << self
          def adapter_name = NAME

          # A missing secret leaves this one account dormant rather than
          # refusing the whole deployment, the same as every other
          # credentialed adapter: one account here is exactly one connection,
          # so the flag can give a real per-connection answer.
          def dormant_on_missing_secret? = true

          def account_schema
            Config::Schema.define do
              field :webhook_url, :string, required: true,
                                           desc: "https URL every outbound event for this account (a new " \
                                                 "message, an edit, a delete, a reaction or a moderation " \
                                                 "action) is signed and POSTed to"
              field :signing_secret_env, :string, required: true, env: true,
                                                  desc: "env var holding the secret outbound POSTs are " \
                                                        "signed with, in the same whsec_ format " \
                                                        "ControlPlane::Webhooks already uses for community " \
                                                        "wide subscriptions"
              field :unsupported, :array, of: :string, default: [],
                                          desc: "capabilities this particular remote does not have, subtracted " \
                                                "from the ones this adapter otherwise claims: any of edits, " \
                                                "deletes, replies, reactions, buttons, puppets_send, " \
                                                "puppets_edit, or a moderation verb such as ban. A game server " \
                                                "bridged through here rarely edits or reacts, and holding it to " \
                                                "promises it cannot keep is worse than it saying so"
              field :identity_durability, :symbol, default: :account,
                                                   one_of: Adapters::Base::IDENTITY_DURABILITY,
                                                   desc: "whether an author id from this remote names an " \
                                                         "account for as long as it exists, or only whoever " \
                                                         "holds a slot right now. A game server handing back " \
                                                         "a session slot or a display name is session: the " \
                                                         "people directory then refuses to anchor an identity " \
                                                         "on it rather than merging two strangers"
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :channel_id, :string, required: true,
                                          desc: "the remote system's own identifier for this conversation, " \
                                                "carried in every inbound and outbound payload so it can " \
                                                "address the right conversation on its own side"
            end
          end

          def validate_account(settings, path)
            url = settings[:webhook_url].to_s
            return [] if url.start_with?("https://")

            ["#{path}.webhook_url: must be an https URL, got #{url.inspect}"]
          end

          def route_key_for(endpoint) = endpoint.settings[:channel_id].to_s
        end

        # Every capability claimed here has a real implementation behind it
        # (see #edit, #delete, #sync_reactions and #moderate below); none is
        # asserted with nothing reading it. custom_reactions is false because
        # a foreign platform's custom emoji belongs to its own registry, which
        # a generic REST integration has no way to resolve against.
        CAPABILITIES = Capabilities.new(
          edits: true, deletes: true, replies: true, threads: false,
          max_attachment_bytes: nil, reactions: true, max_reactions: nil, custom_reactions: false,
          moderation: %i[delete ban unban kick mute unmute pin unpin],
          # The signed webhook body names the real author on both a send and an
          # edit. What the remote does with that is the remote's business, but
          # nothing here forces the bot's own name onto it.
          puppets_send: true, puppets_edit: true,
          command_list: false, reserved_command_prefixes: []
        ).freeze

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil)
          super
          @client = Client.new(webhook_url: settings[:webhook_url], secret: settings[:signing_secret],
                               logger: logger)
          @index = build_index(endpoints)
          @capabilities = CAPABILITIES.without(settings[:unsupported])
          @identity_durability = (settings[:identity_durability] || :account).to_sym
          @running = false
          @thread = nil
        end

        def replace_client(client)
          @client = client
          self
        end

        # This remote's own answer rather than the platform's: an HTTP system is
        # whatever is behind it, and several of the game servers this shape is
        # for hand back a session slot rather than an account.
        def identity_durability = @identity_durability

        # The floor minus whatever this account said it does not have. Built
        # once at construction: the settings do not change under a running
        # adapter, and #capabilities is asked on nearly every relayed message.
        def capabilities = @capabilities

        def own_account_id = OWN_ID

        # Drain any events already queued once, then poll. Returns promptly,
        # like every adapter must; a no-op when built with no inbound_events
        # (no control plane), the same as {Guest::Adapter} and
        # {Api::Adapter} are real only with one.
        def start
          return self if @running

          @running = true
          receive_pending
          @thread = Thread.new do
            Thread.current.name = "api-wrapper-#{account}"
            while @running
              sleep(POLL_INTERVAL)
              receive_pending
            end
          end
          self
        end

        def stop
          @running = false
          @thread&.join(JOIN_TIMEOUT)
          @thread&.kill
          @thread = nil
          self
        end

        def running? = @running

        # Emit every pending event for THIS account once. Never raises: a bad
        # row must not take the receive loop down.
        def receive_pending
          return if inbound_events.nil?

          inbound_events.pending(account: account).each { |row| relay(row) }
        rescue StandardError => e
          logger.warn { "api_wrapper[#{account}]: receive pass failed: #{e.class}: #{e.message}" }
        end

        # ------------------------------------------------------------------
        # outbound
        # ------------------------------------------------------------------

        def deliver(message, endpoint)
          body = message.body.text.to_s
          attachments = attachment_descriptors(message)
          # Nothing to send by design, so Bridge must not record a loss. An
          # attachment with no caption still has something real to send.
          return Core::DeliveryReceipt::NOT_APPLICABLE if body.strip.empty? && attachments.empty?

          message_id = SecureRandom.hex(12)
          response = post_event(endpoint, "message.created", {
            "message_id" => message_id, "body" => body, "author" => author_data(message),
            "reply_to" => reply_to_data(message, endpoint), "attachments" => attachments
          }.compact)
          raise_for(response, "delivery") unless response.ok?

          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: message_id)
        end

        def edit(message, endpoint, native_id)
          response = post_event(endpoint, "message.edited", {
            "message_id" => native_id, "body" => message.body.text.to_s, "author" => author_data(message)
          })
          return nil if response.gone?

          raise_for(response, "edit") unless response.ok?
          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
        end

        def delete(endpoint, native_id)
          response = post_event(endpoint, "message.deleted", { "message_id" => native_id })
          return if response.gone?

          raise_for(response, "delete") unless response.ok?
        end

        # A refusal must raise: once either loop
        # below raises, the exception propagates out of #sync_reactions
        # unchanged, exactly the way {Fluxer::Adapter#sync_reactions}'s own
        # two loops behave. Already-gone is answered per REACTION rather than
        # for the whole call, since a message that vanished mid-batch should
        # not cost the reactions that already landed.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          (desired - previous).each { |reaction| react(endpoint, native_id, reaction) }
          (previous - desired).each { |reaction| unreact(endpoint, native_id, reaction) }
          nil
        end

        def moderate(command, endpoint, native_id)
          # This account's own list, not the constant: an account that said it
          # cannot ban must answer unsupported rather than posting the event.
          unless capabilities.moderates?(command.action)
            return Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end

          response = post_event(endpoint, "moderation.#{command.action}", moderation_data(command, native_id))
          moderation_result(endpoint, response)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        def describe_endpoint(endpoint)
          "#{endpoint.label} (api_wrapper channel #{endpoint.settings[:channel_id]}, account #{account})"
        end

        private

        # ------------------------------------------------------------------
        # inbound: draining ControlPlane::ApiWrapperEvents
        # ------------------------------------------------------------------

        def relay(row)
          if inbound_events.expired?(row)
            logger.warn { "api_wrapper[#{account}]: event #{row.id} waited too long and was dropped unsent" }
            inbound_events.retire(row)
            return
          end

          endpoint = endpoint_for(row.channel_id)
          if endpoint.nil?
            logger.warn do
              "api_wrapper[#{account}]: event #{row.id} is waiting: channel #{row.channel_id.inspect} has no " \
                "endpoint in the current snapshot (not yet mapped to a room, or the snapshot has not reloaded)"
            end
            return
          end

          message = message_for(row, endpoint)
          inbound_events.retire(row)
          emit(message) unless message.nil?
        rescue StandardError => e
          logger.warn { "api_wrapper[#{account}]: event #{row.id} could not be relayed: #{e.class}: #{e.message}" }
        end

        def message_for(row, endpoint)
          case row.kind
          when ControlPlane::ApiWrapperEvents::KIND_MESSAGE then chat_message(row, endpoint)
          when ControlPlane::ApiWrapperEvents::KIND_EDIT then edit_message(row, endpoint)
          when ControlPlane::ApiWrapperEvents::KIND_DELETE then delete_message(row, endpoint)
          when ControlPlane::ApiWrapperEvents::KIND_REACTION_ADD then reaction_message(row, endpoint, :reaction_add)
          when ControlPlane::ApiWrapperEvents::KIND_REACTION_REMOVE
            reaction_message(row, endpoint, :reaction_remove)
          when ControlPlane::ApiWrapperEvents::KIND_JOIN then membership_message(row, endpoint, :join)
          when ControlPlane::ApiWrapperEvents::KIND_LEAVE then membership_message(row, endpoint, :leave)
          end
        end

        def chat_message(row, endpoint)
          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, row.id.to_s),
            origin: endpoint,
            author: author_for(row),
            body: Core::RichText.plain(row.body.to_s),
            attachments: attachments_for(row),
            reply_to: row.reply_to_native_id.nil? ? nil : Core::MessageRef.new(endpoint.id, row.reply_to_native_id)
          )
        end

        def edit_message(row, endpoint)
          Core::Message.new(
            kind: :edit,
            ref: Core::MessageRef.new(endpoint.id, row.target_native_id.to_s),
            origin: endpoint,
            author: author_for(row),
            body: Core::RichText.plain(row.body.to_s)
          )
        end

        def delete_message(row, endpoint)
          Core::Message.new(
            kind: :delete,
            ref: Core::MessageRef.new(endpoint.id, row.target_native_id.to_s),
            origin: endpoint,
            author: author_for(row)
          )
        end

        def reaction_message(row, endpoint, kind)
          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, row.target_native_id.to_s),
            origin: endpoint,
            author: author_for(row),
            reaction: Core::Reaction.new(
              emoji: row.reaction_emoji, custom_id: row.reaction_custom_id, custom_name: row.reaction_custom_name
            )
          )
        end

        # A member arriving or going. The row's own id is the ref, the same as a
        # chat line's, so the event is addressable even though nothing can be
        # said back to it; the author is the member the event is about.
        def membership_message(row, endpoint, kind)
          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, row.id.to_s),
            origin: endpoint,
            author: author_for(row),
            body: Core::RichText.new
          )
        end

        def author_for(row)
          Core::Author.new(
            native_id: row.author_native_id, display_name: row.author_display_name,
            avatar_url: row.author_avatar_url, kind: :user
          )
        end

        def attachments_for(row)
          inbound_events.attachments_of(row).filter_map do |a|
            url = a["url"].to_s
            next nil if url.empty?

            Core::Attachment.new(
              kind: attachment_kind(a["kind"]), url: url, filename: a["filename"],
              mime_type: a["mime_type"], caption: a["caption"]
            )
          end
        end

        # Defaults to :document so an unexpected or absent kind still relays.
        def attachment_kind(raw)
          kind = raw.to_s.to_sym
          Core::Attachment::KINDS.include?(kind) ? kind : :document
        end

        def endpoint_for(channel_id)
          return nil if channel_id.nil?

          if @endpoint_resolver
            @endpoint_resolver.endpoint_for(self.class.adapter_name, account, channel_id.to_s)
          else
            @index[channel_id.to_s]
          end
        end

        def build_index(endpoints)
          endpoints.each_with_object({}) { |endpoint, index| index[endpoint.settings[:channel_id].to_s] = endpoint }
        end

        # ------------------------------------------------------------------
        # outbound helpers
        # ------------------------------------------------------------------

        def post_event(endpoint, type, data)
          @client.post(type: type, data: { "channel_id" => endpoint.settings[:channel_id] }.merge(data))
        end

        def raise_for(response, verb)
          raise AdapterError.new(
            "api_wrapper #{verb} failed (#{response.status}): #{response.body}",
            adapter: :api_wrapper, retryable: response.status >= 500 || response.status == 429
          )
        end

        # The bridge has already set the sender label for this target; #to_s
        # gives its plain text form, the same value a Discord webhook
        # username is built from.
        def author_data(message)
          label = message.sender_label
          name = label ? label.to_s : message.author&.any_name.to_s
          {
            "name" => name, "native_id" => message.author&.native_id,
            "avatar_url" => Util::SafeUrl.public(message.author&.avatar_url)
          }.compact
        end

        # message.reply_to has already been translated into THIS endpoint's id
        # space when the parent was relayed here; an id from elsewhere means
        # "a reply I cannot express natively" and is dropped rather than sent
        # as if it were local.
        def reply_to_data(message, endpoint)
          ref = message.reply_to
          return nil if ref.nil? || ref.endpoint_id != endpoint.id

          ref.native_id
        end

        # A link when the source URL carries no secret, otherwise dropped
        # rather than handed to an outside system, the same rule
        # {Fluxer::Adapter#attachment_reference} applies when a file cannot
        # be relayed as a link.
        def attachment_descriptors(message)
          message.attachments.filter_map do |attachment|
            next nil unless attachment.resolvable?

            url = Util::SafeUrl.public(attachment.url)
            next nil if url.nil?

            { "url" => url, "filename" => attachment.filename, "mime_type" => attachment.mime_type,
              "kind" => attachment.kind.to_s, "caption" => attachment.caption }.compact
          end
        end

        def react(endpoint, native_id, reaction)
          response = post_event(endpoint, "reaction.added", reaction_data(native_id, reaction))
          return if response.gone?

          raise_for(response, "reaction add") unless response.ok?
        end

        def unreact(endpoint, native_id, reaction)
          response = post_event(endpoint, "reaction.removed", reaction_data(native_id, reaction))
          return if response.gone?

          raise_for(response, "reaction remove") unless response.ok?
        end

        def reaction_data(native_id, reaction)
          {
            "message_id" => native_id,
            "emoji" => reaction.emoji, "custom_id" => reaction.custom_id, "custom_name" => reaction.custom_name
          }.compact
        end

        def moderation_data(command, native_id)
          {
            "message_id" => native_id,
            "user" => command.target_user_id ? { "native_id" => command.target_user_id } : nil,
            "issued_by" => command.issuer.to_s,
            "reason" => command.arguments.join(" ")
          }.compact
        end

        def moderation_result(endpoint, response)
          return Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done) if response.ok?
          return Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :not_found) if response.gone?

          status = response.status == 403 ? :forbidden : :failed
          Core::Moderation::Result.new(
            endpoint_id: endpoint.id, status: status, detail: "HTTP #{response.status}: #{response.body}"
          )
        end
      end
    end
  end
end
