# frozen_string_literal: true

require "monitor"

module Rubotty
  module Adapters
    module Fluxer
      # Posts relayed messages through a Fluxer webhook, so each sender appears
      # under their own name and avatar. `webhook: off` posts as the bot; `auto`
      # creates or reuses one, degrading to bot posting when it cannot.
      class Webhook
        Hook = Struct.new(:id, :token, keyword_init: true)

        MAX_USERNAME = 80
        MIN_USERNAME = 1

        def initialize(client:, logger:, bridge_name: "rubotty")
          @client = client
          @logger = logger
          @bridge_name = bridge_name
          @cache = {}
          # One of :active, :degraded or :off per endpoint id, alongside
          # @cache's hook-or-nil. See #puppet_snapshot.
          @status = {}
          # Every webhook id this bridge posts through, used to recognise our own
          # messages coming back off the gateway. Filled in as we post, and from
          # Fluxer itself when one older than this process shows up.
          @own_ids = {}
          # Channels whose webhook list has already been read, so recognising a
          # copy costs one listing per channel rather than one per message.
          @listed_channels = {}
          @monitor = Monitor.new
        end

        attr_reader :logger

        # Is this message one WE posted through a webhook? A webhook message is
        # not authored by the bot account, so the loop guard's author check
        # cannot see it, and this answers :ours, :not_ours or :unknown. :unknown
        # matters because @own_ids only fills in as webhooks are resolved to
        # post through, so a webhook this deployment made before the current
        # process started must never read as :not_ours. Without a channel to
        # check against Fluxer's own webhook list, or when Fluxer will not
        # answer, the result stays :unknown and the CALLER decides how to fail.
        def own_message?(webhook_id, channel: nil)
          return :not_ours if webhook_id.nil?
          return :ours if remembered?(webhook_id)
          return :unknown if channel.nil?
          return :not_ours if learn_channel_webhooks(channel) == :listed && !remembered?(webhook_id)
          return :ours if remembered?(webhook_id)

          :unknown
        end

        # The webhook to use for this endpoint, or nil to post as the bot. The
        # negative result is cached too, so a channel where webhooks are
        # unavailable is not re probed on every message.
        def for(endpoint)
          @monitor.synchronize do
            return @cache[endpoint.id] if @cache.key?(endpoint.id)

            hook = resolve(endpoint)
            @cache[endpoint.id] = hook
            @status[endpoint.id] = classify_status(endpoint, hook)
            hook
          end
        end

        def forget(endpoint)
          @monitor.synchronize do
            @cache.delete(endpoint.id)
            @status.delete(endpoint.id)
          end
        end

        # Every endpoint this process has resolved a webhook for since boot,
        # each answered :active, :degraded or :off. See
        # Adapters::Discord::Webhook#puppet_snapshot, the same contract.
        #
        # @return [Hash{String => Symbol}]
        def puppet_snapshot
          @monitor.synchronize { @status.dup }
        end

        def execute(hook, body)
          @client.execute_webhook(hook.id, hook.token, body)
        end

        def execute_files(hook, body, files)
          @client.execute_webhook_with_files(hook.id, hook.token, body, files)
        end

        def edit(hook, message_id, body)
          @client.edit_webhook_message(hook.id, hook.token, message_id, body)
        end

        def delete(hook, message_id)
          @client.delete_webhook_message(hook.id, hook.token, message_id)
        end

        # Fluxer follows the Discord username rules, so the same shortening keeps
        # most of the original name while never failing a send. It eats into the
        # display name and keeps a structured label's bracketed handle whole,
        # rather than cutting the tail off wherever the limit happens to land.
        def sanitise_username(name, fallback: @bridge_name)
          candidate = name.to_s.tr("\r\n", " ").strip
          candidate = Core::SenderLabel.shorten(candidate, MAX_USERNAME).strip
          candidate = fallback if candidate.length < MIN_USERNAME
          candidate
        end

        private

        def resolve(endpoint)
          mode = endpoint.settings[:webhook] || :auto
          return nil if mode == :off

          find_or_create(endpoint)
        end

        def classify_status(endpoint, hook)
          return :off if (endpoint.settings[:webhook] || :auto) == :off

          hook ? :active : :degraded
        end

        def find_or_create(endpoint)
          channel = endpoint.settings[:channel_id]
          existing = find_existing(channel)
          hook = existing || create(channel, endpoint)
          return nil if hook.nil?

          remember(hook.id)
          hook
        rescue AdapterError => e
          logger.info do
            "no webhook available for #{endpoint.id} (#{e.message}), posting as the bot. " \
              "Grant the manage webhooks permission to relay senders under their own names."
          end
          nil
        end

        def find_existing(channel)
          Array(@client.list_webhooks(channel)).each do |hook|
            next unless hook.is_a?(Hash)
            next unless hook["name"] == @bridge_name && hook["token"]

            return Hook.new(id: hook["id"], token: hook["token"])
          end
          nil
        rescue AdapterError
          # Listing needs the same permission as creating, so fall through to
          # create, which reports it.
          nil
        end

        def create(channel, endpoint)
          created = @client.create_webhook(channel, @bridge_name)
          return nil unless created.is_a?(Hash) && created["id"] && created["token"]

          logger.info { "created a webhook named #{@bridge_name.inspect} in #{endpoint.id}" }
          Hook.new(id: created["id"], token: created["token"])
        end

        def remember(id)
          return if id.nil?

          @monitor.synchronize { @own_ids[id.to_s] = true }
        end

        def remembered?(id) = @monitor.synchronize { @own_ids.key?(id.to_s) }

        # Record every webhook in +channel+ carrying the bridge's name, so a copy
        # written in a previous run is recognisable in this one. Listing needs
        # the same permission posting through one needs, so a refusal here is a
        # real "cannot tell" rather than a "no".
        #
        # @return [:listed, :unavailable]
        def learn_channel_webhooks(channel)
          key = channel.to_s
          return :listed if @monitor.synchronize { @listed_channels.key?(key) }

          Array(@client.list_webhooks(key)).each do |hook|
            remember(hook["id"]) if hook.is_a?(Hash) && hook["name"] == @bridge_name
          end
          @monitor.synchronize { @listed_channels[key] = true }
          :listed
        rescue StandardError => e
          logger.info { "could not list webhooks in #{key} (#{e.message}), cannot say whether a copy is ours" }
          :unavailable
        end
      end
    end
  end
end
