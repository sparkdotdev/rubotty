# frozen_string_literal: true

require "monitor"

module Rubotty
  module Adapters
    module Discord
      # Posts relayed messages through a Discord webhook, so each sender appears
      # under their own name instead of one bot posting everything.
      #
      #   webhook: off      post as the bot, never touch webhooks
      #   webhook: auto     reuse a webhook this bridge made, else create one
      #   webhook_url_env   use exactly this webhook, create nothing
      # `auto` creates a resource, named after the bridge, deletable in the channel's
      # integration settings, degrading to bot posting without Manage Webhooks.
      class Webhook
        # Discord rejects these in a webhook username, and a rejection fails the
        # whole send. Cheaper to sanitise than to lose the message.
        FORBIDDEN_NAMES = %w[everyone here].freeze
        FORBIDDEN_SUBSTRINGS = %w[discord clyde].freeze
        MAX_USERNAME = 80
        MIN_USERNAME = 1

        # The Rubotty logo ships at the repository root, resolved relative to
        # this file so no absolute machine path is baked in.
        LOGO_PATH = File.expand_path("../../../../rubotty-logo.png", __dir__)

        # The logo as a base64 data URI, encoded once per process, in the shape
        # Discord's webhook create and modify endpoints want, used as the webhook's
        # DEFAULT avatar: it shows only when a message is posted WITHOUT a per
        # sender picture. Any failure yields nil, which restores Discord's own default.
        def self.default_avatar
          return @default_avatar if defined?(@default_avatar)

          @default_avatar = begin
            "data:image/png;base64,#{[File.binread(LOGO_PATH)].pack("m0")}"
          rescue StandardError
            nil
          end
        end

        def initialize(client:, logger:, bridge_name: "rubotty")
          @client = client
          @logger = logger
          @bridge_name = bridge_name
          @cache = {}
          # One of :active, :degraded or :off per endpoint id, alongside
          # @cache's hook-or-nil, for a caller that needs to say WHY there is
          # no hook rather than just that there is none. See #puppet_snapshot.
          @status = {}
          # Every webhook id this bridge posts through, used to recognise our own
          # messages coming back off the gateway. Filled in as we post, and from
          # Discord itself when something older than this process shows up.
          @own_ids = {}
          # Channels whose webhook list we have already read, so recognising a
          # copy costs one listing per channel rather than one per message.
          @listed_channels = {}
          @monitor = Monitor.new
        end

        # Is this message one WE posted through a webhook? A webhook message
        # is not authored by the bot account, so the loop guard cannot see
        # it, and this answers :ours, :not_ours, or :unknown. :unknown
        # matters because @own_ids is only filled in when a webhook is
        # resolved to post through it, so at boot it is empty and must
        # never be read as :not_ours; without a channel to check against
        # Discord's own webhook list, or when Discord will not answer, the
        # result stays :unknown and the CALLER decides which way to fail.
        def own_message?(webhook_id, channel: nil)
          return :not_ours if webhook_id.nil?
          return :ours if @monitor.synchronize { @own_ids.key?(webhook_id.to_s) }
          return :unknown if channel.nil?
          return :not_ours if learn_channel_webhooks(channel) == :listed &&
                              !@monitor.synchronize { @own_ids.key?(webhook_id.to_s) }
          return :ours if @monitor.synchronize { @own_ids.key?(webhook_id.to_s) }

          :unknown
        end

        attr_reader :logger

        # Resolve the webhook to use for +endpoint+, or nil to post as the bot.
        # Cached per endpoint, including the negative result, so a channel where
        # the bot cannot make webhooks is not re probed on every message.
        def for(endpoint)
          @monitor.synchronize do
            return @cache[endpoint.id] if @cache.key?(endpoint.id)

            hook = resolve(endpoint)
            @cache[endpoint.id] = hook
            @status[endpoint.id] = classify_status(endpoint, hook)
            hook
          end
        end

        # Forget a cached webhook, so the next send re resolves it. Called when
        # Discord reports the webhook is gone.
        def forget(endpoint)
          @monitor.synchronize do
            @cache.delete(endpoint.id)
            @status.delete(endpoint.id)
          end
        end

        # Every endpoint this process has resolved a webhook for since boot,
        # each answered :active (posting under the sender's own name),
        # :degraded (Manage Webhooks is missing or an explicit URL was bad, so
        # it silently fell back to the bot) or :off (webhook: off). An
        # endpoint with no traffic yet is simply absent, not :unknown: nobody
        # has asked #for it, so there is nothing to report.
        #
        # @return [Hash{String => Symbol}]
        def puppet_snapshot
          @monitor.synchronize { @status.dup }
        end

        # Send through the webhook, returning the created message; text and embeds
        # only, a file goes through {#execute_files} instead. `wait` is not
        # optional: without it Discord returns 204 with no body and the message id
        # is never learned, so no edit or delete can propagate.
        def execute(hook, content:, username:, avatar_url: nil, allowed_mentions: nil, embed: nil)
          builder = build(content: content, username: username, avatar_url: avatar_url,
                          allowed_mentions: allowed_mentions, embed: embed)
          response = hook.execute(builder, true)
          parse(response)
        end

        # Post every file in +files+ as ONE webhook execute, so Discord renders
        # them as a single message with a gallery instead of a message per
        # file. Bypasses Discordrb::Webhooks::Builder, which holds exactly one
        # @file and emits a single `file:` key: {MultipartFilesBuilder} carries
        # N files as `files[0]`.. `files[N-1]` plus a `payload_json` part,
        # which is also the only shape Discord's webhook endpoint reads
        # allowed_mentions from on a multipart upload, so the caption can ride
        # in the same request as the files.
        def execute_files(hook, content:, username:, files:, avatar_url: nil, allowed_mentions: nil)
          builder = MultipartFilesBuilder.new(
            content: content, username: self.class.sanitise_username(username, fallback: @bridge_name),
            avatar_url: avatar_url, files: files, allowed_mentions: allowed_mentions
          )
          response = hook.execute(builder, true)
          parse(response)
        end

        # +thread_id+ addresses a message posted into a thread under this
        # webhook's own channel: without it Discord looks for the message in
        # the webhook's channel itself and answers Unknown Message.
        def edit(hook, message_id, content:, allowed_mentions: nil, thread_id: nil)
          hook.edit_message(message_id.to_s, content: content, allowed_mentions: allowed_mentions,
                                             thread_id: thread_id)
        end

        # Already gone counts as success rather than failure: a message can
        # be deleted twice in a race, and this thin webhook client calls
        # RestClient directly, so a 404 surfaces as ResourceNotFound, not
        # UnknownMessage. +thread_id+ is the same thread targeting {#edit}
        # takes: discordrb-webhooks 3.8.0's #delete_message has no
        # thread_id parameter, unlike #execute and #edit_message, so a
        # thread message is reached by building the same query discordrb
        # already uses for those two.
        def delete(hook, message_id, thread_id: nil)
          require "discordrb"
          require "rest-client"
          if thread_id
            RestClient.delete(delete_url(hook, message_id, thread_id))
          else
            hook.delete_message(message_id.to_s)
          end
          nil
        rescue Discordrb::Errors::UnknownMessage, RestClient::ResourceNotFound
          nil
        end

        # Discord's rules, applied in the order that keeps the most of the
        # original name. A username that violates them fails the whole request.
        def self.sanitise_username(name, fallback: "bridge")
          candidate = name.to_s.strip
          FORBIDDEN_SUBSTRINGS.each do |word|
            # Break the word rather than delete it, so "discordian" stays legible.
            candidate = candidate.gsub(/#{word}/i) { |match| "#{match[0]}.#{match[1..]}" }
          end
          # Shortening eats into the display name and keeps the bracketed handle
          # whole, rather than cutting the tail off a structured label.
          candidate = Core::SenderLabel.shorten(candidate, MAX_USERNAME).strip
          candidate = fallback if candidate.length < MIN_USERNAME
          candidate = "#{candidate}." if FORBIDDEN_NAMES.include?(candidate.downcase)
          candidate
        end

        private

        # discordrb-webhooks keeps the webhook's own URL in a private ivar with
        # no reader; reused rather than rebuilt, so this stays correct however
        # the client was constructed (from an id/token pair or a raw url).
        def delete_url(hook, message_id, thread_id)
          base = hook.instance_variable_get(:@url)
          "#{base}/messages/#{message_id}?#{URI.encode_www_form(thread_id: thread_id)}"
        end

        def build(content:, username:, avatar_url:, allowed_mentions:, embed: nil)
          require "discordrb/webhooks"

          builder = ::Discordrb::Webhooks::Builder.new
          builder.content = content.to_s
          builder.username = self.class.sanitise_username(username, fallback: @bridge_name)
          builder.avatar_url = avatar_url if avatar_url
          builder.allowed_mentions = allowed_mentions if allowed_mentions
          # `<<` rather than add_embed: add_embed always yields, so calling it
          # without a block raises LocalJumpError.
          builder << ::Discordrb::Webhooks::Embed.new(**embed) if embed
          builder
        end

        # discordrb hands back a RestClient::Response; only the id is wanted.
        # Both failure paths log now, rather than returning a bare nil: a bad
        # Discord response and a working one otherwise look identical from the
        # caller's side, and logging here catches every path into this method.
        def parse(response)
          body = response.respond_to?(:body) ? response.body : response
          if body.nil? || body.to_s.empty?
            logger.warn { "webhook response carried no body#{response_code(response)}" }
            return nil
          end

          JSON.parse(body.to_s)
        rescue JSON::ParserError => e
          logger.warn { "webhook response was not JSON#{response_code(response)}: #{e.message}" }
          nil
        end

        def response_code(response)
          response.respond_to?(:code) ? " (code #{response.code})" : ""
        end

        def resolve(endpoint)
          mode = endpoint.settings[:webhook] || :auto
          explicit = endpoint.settings[:webhook_url]

          return nil if mode == :off && explicit.nil?
          return from_url(explicit, endpoint) if explicit

          find_or_create(endpoint)
        end

        # An operator's own "off" reads apart from a resolve that was
        # attempted and came back empty: the first is a choice, the second is
        # almost always a missing Manage Webhooks grant.
        def classify_status(endpoint, hook)
          return :off if (endpoint.settings[:webhook] || :auto) == :off && endpoint.settings[:webhook_url].nil?

          hook ? :active : :degraded
        end

        def from_url(url, endpoint)
          require "discordrb/webhooks"

          # .../webhooks/<id>/<token>
          remember(url.to_s[%r{/webhooks/(\d+)/}, 1])
          ::Discordrb::Webhooks::Client.new(url: url)
        rescue StandardError => e
          logger.warn { "webhook URL for #{endpoint.id} is unusable (#{e.message}), posting as the bot" }
          nil
        end

        # Reuse before create. Without this, every restart would add another
        # webhook to the channel until Discord's limit of ten was hit.
        def find_or_create(endpoint)
          channel = @client.channel(endpoint.settings[:channel_id])
          existing = find_existing(channel)
          hook = if existing
                   adopt_avatar(existing, endpoint)
                   existing
                 else
                   create(channel, endpoint)
                 end
          return nil if hook.nil?

          wrap(hook)
        rescue StandardError => e
          logger.info do
            "no webhook available for #{endpoint.id} (#{e.message}), posting as the bot. " \
              "Grant Manage Webhooks to relay senders under their own names."
          end
          nil
        end

        def find_existing(channel)
          Array(channel.webhooks).find { |hook| hook.name == @bridge_name && hook.token }
        rescue StandardError
          # Listing webhooks needs Manage Webhooks too, so a failure here is the
          # same permission problem as failing to create one.
          nil
        end

        def create(channel, endpoint)
          # The avatar given here is the webhook's DEFAULT, used only for
          # messages posted without a per sender picture.
          hook = channel.create_webhook(@bridge_name, self.class.default_avatar)
          logger.info { "created a webhook named #{@bridge_name.inspect} in #{endpoint.id}" }
          hook
        rescue StandardError => e
          logger.info { "could not create a webhook in #{endpoint.id}: #{e.message}" }
          nil
        end

        # Give an already existing bridge webhook the Rubotty logo when it still
        # carries Discord's default avatar, so a webhook made before the logo
        # existed picks it up on the next startup.
        #
        # The write happens only when the webhook has no avatar of its own, so a
        # steady state restart makes no needless API call.
        def adopt_avatar(hook, endpoint)
          return if self.class.default_avatar.nil?
          return unless hook.respond_to?(:avatar) && hook.respond_to?(:avatar=)
          return unless hook.avatar.nil?

          hook.avatar = self.class.default_avatar
          logger.info { "set the Rubotty avatar on the existing webhook in #{endpoint.id}" }
        rescue StandardError => e
          # A failed avatar write must never cost us the webhook: relaying under
          # the wrong icon beats not relaying at all.
          logger.info { "could not set the webhook avatar in #{endpoint.id}: #{e.message}" }
        end

        # A Discordrb::Webhook knows its id and token; the Webhooks::Client is
        # the thing that can execute, edit and delete.
        def wrap(hook)
          require "discordrb/webhooks"

          remember(hook.id)
          ::Discordrb::Webhooks::Client.new(id: hook.id, token: hook.token)
        end

        def remember(id)
          return if id.nil?

          @monitor.synchronize { @own_ids[id.to_s] = true }
        end

        # Record every webhook in +channel+ that carries the bridge's name, so a
        # copy we wrote in a previous run is recognisable in this one. Listing
        # needs Manage Webhooks, the same permission posting through one needs,
        # so a refusal here is a real "cannot tell" rather than a "no".
        #
        # @return [:listed, :unavailable]
        def learn_channel_webhooks(channel)
          key = channel.id.to_s
          return :listed if @monitor.synchronize { @listed_channels.key?(key) }

          Array(channel.webhooks).each { |hook| remember(hook.id) if hook.name == @bridge_name }
          @monitor.synchronize { @listed_channels[key] = true }
          :listed
        rescue StandardError => e
          logger.info { "could not list webhooks in #{key} (#{e.message}), cannot say whether a copy is ours" }
          :unavailable
        end
      end

      # Stands in for Discordrb::Webhooks::Builder where the real one cannot go: more
      # than one file on a message. Client#execute only asks a builder for #file (to
      # decide whether to post multipart) and #to_multipart_hash (for the wire shape);
      # this answers both, emitting `files[0]`.. `files[N-1]` and a `payload_json` part
      # carrying content, username, avatar_url, allowed_mentions and per file metadata,
      # rather than the real builder's single `file:` key. The plain readers (#content,
      # #username, #avatar_url, #allowed_mentions, #embeds) exist so this also satisfies
      # anything shaped like a real builder, such as a test double.
      class MultipartFilesBuilder
        attr_reader :content, :username, :avatar_url, :allowed_mentions, :files

        def initialize(content:, username:, avatar_url:, files:, allowed_mentions: nil)
          @content = content.to_s
          @username = username
          @avatar_url = avatar_url
          @files = Array(files)
          @allowed_mentions = allowed_mentions
        end

        # The multipart branch in Discordrb::Webhooks::Client#execute is
        # picked on this being truthy; which file does not matter beyond that.
        def file = @files.first

        # Files and embeds are mutually exclusive on a Discord message, same
        # as on the real builder, and this one never carries an embed.
        def embeds = []

        def to_multipart_hash
          payload = {
            content: @content, username: @username, avatar_url: @avatar_url,
            allowed_mentions: @allowed_mentions, attachments: attachment_meta
          }.compact
          hash = { payload_json: JSON.generate(payload) }
          @files.each_with_index { |file, index| hash["files[#{index}]"] = file }
          hash
        end

        private

        def attachment_meta
          @files.each_index.map { |index| { id: index, filename: filename_for(@files[index]) } }
        end

        def filename_for(file)
          file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.path)
        end
      end
    end
  end
end
