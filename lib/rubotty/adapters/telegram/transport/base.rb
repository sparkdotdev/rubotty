# frozen_string_literal: true

module Rubotty
  module Adapters
    module Telegram
      # How updates reach us from Telegram: long polling (the bot asks for
      # updates; works anywhere, no inbound connectivity or TLS certificate
      # needed, costs one open HTTP request at all times) or webhooks
      # (Telegram POSTs to a URL we serve; lower latency, no idle
      # connection, needs a public HTTPS endpoint), both legitimate
      # production choices. Nothing else in the adapter may know which is
      # in use: a transport is a source of raw update hashes and nothing
      # more, it does not parse, filter, or know what a room is.
      module Transport
        # The transport contract.
        class Base
          # @param on_update [#call] receives one raw update Hash at a time, called
          #   on a thread the transport owns. It must not raise; the adapter wraps it.
          # @param storage [#get_state, #put_state, nil] durable KV, used by long
          #   polling to persist its getUpdates offset across restarts. Nil
          #   without a durable backend, where the offset stays in memory.
          # @param account [String, nil] the account name, so a shared store keys
          #   the persisted offset per Telegram account.
          def initialize(client:, logger:, on_update:, settings: {}, storage: nil, account: nil)
            @client = client
            @logger = logger
            @on_update = on_update
            @settings = settings
            @storage = storage
            @account = account
            @running = false
          end

          attr_reader :client, :logger, :settings

          # Begin delivering updates. Must return promptly.
          def start
            raise NotImplementedError, "#{self.class} must implement #start"
          end

          # Stop delivering updates and release resources. Must be idempotent.
          def stop
            raise NotImplementedError, "#{self.class} must implement #stop"
          end

          def running? = @running

          # Human readable, for the boot log.
          def describe = self.class.name.split("::").last

          protected

          # The durable store and account name, for a transport that persists
          # cursor state across restarts.
          attr_reader :storage, :account

          # Hand an update to the adapter, never letting a handler error kill the
          # receive loop.
          def deliver(update)
            @on_update.call(update)
          rescue StandardError => e
            logger.error { "error handling Telegram update: #{e.class}: #{e.message}" }
            logger.debug { e.backtrace&.first(8)&.join("\n") }
          end

          # Update types we ask Telegram for. The same list for both transports so
          # their behaviour matches.
          def allowed_updates
            # Naming any list here replaces Telegram's default update set
            # entirely, so every needed type must be listed: callback_query
            # (already default, but dropped here if unlisted) plus
            # message_reaction, message_reaction_count and my_chat_member.
            %w[message edited_message channel_post edited_channel_post message_reaction
               message_reaction_count my_chat_member callback_query]
          end
        end
      end
    end
  end
end
