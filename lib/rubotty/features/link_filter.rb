# frozen_string_literal: true

require "uri"

module Rubotty
  module Features
    # Link and invite filtering, run before the bridge relays a message.
    # Checks each link against a per-scope whitelist, blacklist, and
    # posture: blacklist always wins, whitelist always exempts, and only
    # then does posture (allow_all, block_invites, block_all) decide. One
    # blocked link acts on the whole message, using the word filter's
    # actions (delete, flag, or warn/mute, degrading to the stub action
    # without a warnings service).
    class LinkFilter < Base
      IMPLEMENTED_ACTIONS = %w[delete flag].freeze
      DEFERRED_ACTIONS = %w[warn mute].freeze
      ACTIONS = (IMPLEMENTED_ACTIONS + DEFERRED_ACTIONS).freeze

      # The default posture blocks invite links while leaving ordinary links alone.
      POSTURES = %w[allow_all block_invites block_all].freeze
      DEFAULT_POSTURE = "block_invites"

      DEFAULT_ACTION = "delete"
      DEFAULT_STUB_ACTION = "delete"
      DEFAULT_MUTE_DURATION = 3600

      # The audit `source` key and the sender label the removal notice posts under.
      SOURCE = "link_filter"
      NOTICE_NAME = "link filter"

      # Shown to the author and stored in the audit trail; overridable per scope.
      DEFAULT_REMOVAL_REASON = "Sharing invitation links to other communities is not allowed."

      # Requires a real scheme or www prefix, so ordinary prose ("see figure 2.3")
      # is never mistaken for a link.
      URL_REGEX = %r{(?:https?://|www\.)[^\s<>"'`]+}i

      # Telegram spells one host three ways, and all three carry both invites
      # and permalinks.
      TELEGRAM_HOSTS = %r{t\.me|telegram\.me|telegram\.dog}i

      # The shape of an invite, without a scheme. On Telegram that is the
      # joinchat and + forms, or a bare public handle with NOTHING after it: a
      # handle followed by a path is a permalink to one message, and
      # t.me/c/<chat>/<message> resolves only for somebody already in that chat.
      # Reading those as invites deleted moderators quoting their own community
      # to each other, the bot's own alert links included (#1929).
      INVITE_BODY = %r{
        discord(?:app)?\.com/invite/[\w-]+ |
        discord\.gg/[\w-]+ |
        discord\.io/[\w-]+ |
        dsc\.gg/[\w-]+ |
        (?:#{TELEGRAM_HOSTS})/(?:joinchat/|\+)[\w+-]+ |
        (?:#{TELEGRAM_HOSTS})/(?!c/|s/)[A-Za-z]\w{2,}(?!\w)(?!/\w) |
        chat\.whatsapp\.com/[\w-]+
      }ix

      # Finds an invite inside a sentence, so it is deliberately not anchored
      # and a bare `discord.gg/x` with no scheme is caught. The lookbehind still
      # holds it to a host boundary: without one it cut "t.me/evil" out of the
      # middle of another host's path, and the anchored classifier below cannot
      # help once the fragment has been severed from the link it came from.
      INVITE_REGEX = %r{(?<![\w./])(?:https?://)?(?:www\.)?(?:#{INVITE_BODY})}ix

      # A permalink into one Telegram chat, capturing the chat it names.
      # t.me/c/<id> is the chat id with the -100 supergroup prefix dropped, so a
      # community's own rooms can be recognised exactly rather than guessed at.
      OWN_PERMALINK = %r{\A(?:https?://)?(?:www\.)?(?:#{TELEGRAM_HOSTS})/c/(\d+)(?:[/?#]|\z)}i

      # Classifies ONE link, so it is anchored where the finder cannot be.
      # Unanchored, "https://t.me/c" matched out of the front of every permalink
      # and the whole link read as an invite.
      INVITE_MATCH = %r{\A(?:https?://)?(?:www\.)?(?:#{INVITE_BODY})/?(?:[?#]\S*)?\z}ix

      def self.feature_name = "link_filter"

      def self.description = "Blocks or flags messages carrying a link or invite not on the whitelist."

      # What this filter would say about some text, for a caller outside the
      # pipeline: "clean", "blocked", or "unknown_domain" when the link carries no
      # host this can read.
      def self.verdict_for(text, config = {})
        filter = allocate
        posture = filter.send(:posture_for, config)
        whitelist = filter.send(:domain_list, config, :whitelist)
        blacklist = filter.send(:domain_list, config, :blacklist)
        invites = Array(filter.send(:list_value, config, :whitelisted_invites)).map(&:to_s)

        links = filter.send(:candidate_links_in, text.to_s)
        return "clean" if links.empty?
        return "unknown_domain" if links.all? { |url| filter.send(:host_of, url).empty? }

        blocked = links.find { |url| filter.send(:verdict, url, posture, whitelist, blacklist, invites) == :block }
        blocked ? "blocked" : "clean"
      end

      def self.default_enabled? = false

      # Edits count, since a clean message can be edited to add a link.
      def self.observes = %i[chat edit]

      def self.config_schema
        Config::Schema.define do
          field :posture, :string, default: DEFAULT_POSTURE, one_of: POSTURES,
                desc: "allow_all, block_invites, or block_all (whitelist-only)"
          field :whitelist, :array, of: :string, default: [], desc: "trusted domains, always allowed"
          field :whitelisted_invites, :array, of: :string, default: [],
                desc: "specific invite links that are allowed, matched whole rather than by domain"
          field :blacklist, :array, of: :string, default: [], desc: "banned domains, always blocked"
          field :action, :string, default: DEFAULT_ACTION, one_of: ACTIONS
          field :stub_action, :string, default: DEFAULT_STUB_ACTION, one_of: IMPLEMENTED_ACTIONS
          field :exempt_operators, :boolean, default: true
          field :removal_reason, :string, default: DEFAULT_REMOVAL_REASON,
                desc: "the reason shown to the author when a link is removed"
          field Core::RemovalNotice::TTL_FIELD, :integer, default: Core::RemovalNotice::DEFAULT_TTL_SECONDS,
                desc: "seconds the self-deleting removal notice lives before it is removed"
          field Core::RemovalNotice::NOTIFY_FIELD, :boolean, default: true,
                desc: "DM this community's operators when a message is removed here, so an " \
                      "automated removal is never something only the person removed from finds out about"
          field :mute_duration, :duration, default: DEFAULT_MUTE_DURATION
          field :ocr, :boolean, default: false,
                desc: "also OCR each photo attachment and scan the text it reads off the image; off " \
                      "by default since OCR is slower and noisier than the QR decode this filter " \
                      "always runs against a photo, and most photos carrying visible text are not " \
                      "an evasion attempt (issue #858)"
        end
      end

      # @param topology [Core::Topology] resolves a mapped ref during removal
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param storage the message map, for resolving cross-platform copies
      # @param ephemeral [Core::EphemeralMessage, nil] posts the removal notice
      # @param cleanup [Core::Scheduler, nil] fires the notice's self-delete
      # @param warnings [Core::Warnings::Service, nil] the shared warnings coordinator
      # @param audit [Core::AuditLog::Sequel, Core::AuditLog::Null, nil] the durable moderation audit sink
      def initialize(topology:, adapters:, storage:, logger:,
                     ephemeral: nil, cleanup: nil,
                     warnings: nil, audit: nil, admin_notifier: nil)
        super()
        @topology = topology
        @adapters = adapters
        @storage = storage
        @logger = logger
        @ephemeral = ephemeral
        @cleanup = cleanup
        @warnings = warnings
        # The shared removal engine: remove-everywhere plus the standard
        # after-removal audit and, on a delete, the self-deleting mention notice.
        @removal = Watchdog::Removal.new(
          topology: @topology, adapters: @adapters, storage: @storage, logger: @logger,
          source: SOURCE, name: NOTICE_NAME, ephemeral: @ephemeral, cleanup: @cleanup, audit: audit,
          admin_notifier: admin_notifier, alerts: true
        )
      end

      attr_reader :logger

      def call(context)
        posture = posture_for(context.config)
        whitelist = domain_list(context.config, :whitelist)
        blacklist = domain_list(context.config, :blacklist)
        whitelisted_invites = Array(list_value(context.config, :whitelisted_invites)).map(&:to_s)
        # No link could ever be blocked here, so skip the scan entirely.
        return Outcome.continue([]) if posture == "allow_all" && blacklist.empty?
        return Outcome.continue([]) if exempt?(context)

        blocked = first_blocked_link(context, posture, whitelist, blacklist, whitelisted_invites)
        return Outcome.continue([]) if blocked.nil?

        act(context, blocked)
      end

      private

      # The first link the policy blocks, or nil when every link is allowed. The
      # community's own chats are read at most once, and only where a link could
      # be one of them: every other message is decided without asking.
      def first_blocked_link(context, posture, whitelist, blacklist, whitelisted_invites = [])
        own = nil
        candidate_links(context).find do |url|
          own = own_chat_ids(context) if own.nil? && OWN_PERMALINK.match?(url)
          verdict(url, posture, whitelist, blacklist, whitelisted_invites, own || []) == :block
        end
      end

      # Every Telegram chat this community owns, named the way a permalink names
      # one. Read off the endpoints themselves rather than configured by hand, so
      # a room mapped later is covered without anybody remembering to say so.
      def own_chat_ids(context)
        community = context.community
        return [] unless community.respond_to?(:rooms)

        rooms = community.rooms
        Array(rooms).flat_map { |room| Array(room.endpoints) }.filter_map { |endpoint| permalink_id(endpoint) }.uniq
      rescue StandardError => e
        logger&.debug { "link filter: could not read this community's own chats: #{e.message}" }
        []
      end

      # The chat id as a permalink spells it: supergroups are negative and carry
      # a -100 prefix that t.me/c/<id> leaves off.
      def permalink_id(endpoint)
        settings = endpoint.respond_to?(:settings) ? endpoint.settings : nil
        raw = settings.is_a?(Hash) ? (settings[:chat_id] || settings["chat_id"]) : nil
        digits = raw.to_s.strip.delete_prefix("-100")
        digits.match?(/\A\d+\z/) ? digits : nil
      end

      # The links in a bare string, which is all the host function has.
      # {#candidate_links} below adds the adapter's parsed :link spans and any
      # attachment text on top.
      def candidate_links_in(raw)
        text = Matcher.bound_input(raw.to_s)
        links = text.scan(URL_REGEX).map { |url| trim(url) }
        links.concat(text.scan(INVITE_REGEX).map { |url| trim(url) })
        links.uniq
      end

      # Links in the message body, its :link spans, and, since a link needs
      # no caption to be posted, whatever a photo attachment's QR code
      # decodes to and, when `ocr` is on, whatever OCR reads off that same
      # photo. QR decoding runs unconditionally: {AttachmentText#text} only
      # pays for the OCR pass when +ocr+ asks for it.
      def candidate_links(context)
        message = context.message
        links = candidate_links_in(message.body.text)
        links.concat(candidate_links_in(context.attachment_text.text(ocr: ocr_enabled?(context.config))))
        links.concat(span_links(message.body))
        links.reject(&:empty?).uniq
      end

      def ocr_enabled?(config)
        truthy(config_value(config, :ocr), default: false)
      end

      def span_links(body)
        body.spans.filter_map do |span|
          next nil unless span.kind == :link

          url = span.attributes[:url] || span.attributes["url"]
          url.nil? ? nil : url.to_s
        end
      end

      # The policy decision for one link.
      def verdict(url, posture, whitelist, blacklist, whitelisted_invites = [], own = [])
        host = host_of(url)
        return :block if domain_listed?(host, blacklist) # blacklist always wins
        return :allow if domain_listed?(host, whitelist) # whitelist always exempts
        # Pointing at this community's own rooms, so it leads nowhere else and
        # is exempt under every posture, block_all included.
        return :allow if own_chat_link?(url, own)
        # A community's own invite cannot be expressed by domain: whitelisting
        # t.me would allow every Telegram invite there is.
        return :allow if invite_listed?(url, whitelisted_invites)

        case posture
        when "allow_all" then :allow
        when "block_all" then :block
        else # "block_invites"
          invite?(url) ? :block : :allow
        end
      end

      # The whole link is compared, normalised on both sides so an operator can
      # paste it as received: scheme, www, trailing slash and case are ignored,
      # and a bare code without the t.me in front is accepted.
      def invite_listed?(url, list)
        return false if list.nil? || list.empty?

        target = normalise_invite(url)
        return false if target.empty?

        list.any? do |entry|
          allowed = normalise_invite(entry)
          next false if allowed.empty?

          target == allowed || target.end_with?("/#{allowed}")
        end
      end

      def normalise_invite(value)
        value.to_s.strip
             .sub(%r{\Ahttps?://}i, "")
             .sub(/\Awww\./i, "")
             .sub(%r{/+\z}, "")
             .downcase
      end

      # Whether +host+ equals or is a subdomain of any entry in +list+.
      def domain_listed?(host, list)
        return false if host.empty? || list.empty?

        list.any? { |domain| host == domain || host.end_with?(".#{domain}") }
      end

      def invite?(url) = INVITE_MATCH.match?(url.to_s)

      # Whether a link names a chat this community owns. Only the t.me/c/<id>
      # form can be told exactly: an invite hash names no chat a reader can
      # resolve, and Telegram rotates those, which is what whitelisted_invites
      # is for.
      def own_chat_link?(url, own)
        return false if own.nil? || own.empty?

        named = OWN_PERMALINK.match(url.to_s)
        !named.nil? && own.include?(named[1])
      end

      # The lowercased host of a link, tolerating a missing scheme, a leading
      # `www.`, a port, and a path / query / fragment.
      def host_of(url)
        value = url.to_s.strip
        value = "https://#{value}" unless value.match?(%r{\Ahttps?://}i)
        uri = URI.parse(value)
        return "" unless uri.is_a?(URI::HTTP)

        uri.hostname.to_s.downcase.delete_prefix("www.")
      rescue URI::InvalidURIError
        ""
      end

      # Trim trailing sentence punctuation the URL regex greedily absorbs, so
      # "see example.com/x." does not carry the full stop into the path.
      def trim(url) = url.to_s.sub(/[.,;:!?)\]}'"]+\z/, "")

      def exempt?(context)
        return false unless truthy(config_value(context.config, :exempt_operators), default: true)

        # This community's own directory and nothing else. A room key is unique
        # only within one, so an unresolved community denies rather than widening
        # to the merged deployment-wide view. Empty is still not short-circuited:
        # the deployment-configured owner floor is invisible to Directory#empty?.
        directory = context.operators
        return false if directory.nil?

        author = context.message.author
        return false if author.nil? || author.native_id.nil?

        !directory.resolve(context.message.origin.adapter_name, author.native_id,
                           username: author.username).nil?
      end

      def act(context, blocked)
        requested = requested_action(context.config)
        escalate(context, requested, blocked)

        effective = effective_action(requested, context.config)
        removed = effective == "delete" ? @removal.remove_everywhere(context.message) : []
        @removal.notice(
          context: context, action: effective, reason: reason_for(context.config),
          requested: requested, metadata: { link: blocked, posture: posture_for(context.config) }
        )
        effective == "flag" ? Outcome.continue([]) : Outcome.halt(removed)
      end

      # The per-scope `removal_reason` override, or the default when unset.
      def reason_for(config)
        override = config_value(config, :removal_reason)
        override.nil? || override.to_s.strip.empty? ? DEFAULT_REMOVAL_REASON : override.to_s
      end

      def escalate(context, requested, blocked)
        return unless @warnings && DEFERRED_ACTIONS.include?(requested)

        author = context.message.author
        return if author.nil? || author.native_id.nil?

        origin = context.message.origin
        if requested == "mute"
          @warnings.sanction(
            community: context.community, subject: author, origin: origin,
            action: :mute, duration: mute_duration(context.config), reason: "link filter: #{blocked}",
            issued_by: "link filter"
          )
        else # "warn"
          @warnings.warn(
            community: context.community, subject: author, origin: origin,
            ladder: warnings_ladder(context), max: warnings_max(context),
            expire_after: warnings_expire_after(context), reason: "link filter: #{blocked}",
            issued_by: "link filter"
          )
        end
      rescue StandardError => e
        @logger.warn { "link_filter: could not escalate #{requested}: #{e.class}: #{e.message}" }
      end

      # The community's own "warnings" feature config, read once so this filter
      # and `/warn` feed one ladder, one maximum and one decay policy. Empty
      # without a control plane (no community to read it from).
      def warnings_feature_config(context)
        community = context.community
        return {} unless community.respond_to?(:feature_config)

        community.feature_config(context.channel, "warnings") || {}
      end

      def warnings_ladder(context)
        Core::Warnings::Ladder.parse(warnings_feature_config(context), logger: @logger)
      end

      def warnings_max(context)
        value = config_value(warnings_feature_config(context), :max)
        value.nil? ? nil : value.to_i
      end

      def warnings_expire_after(context)
        Core::Warnings.duration_seconds(config_value(warnings_feature_config(context), :expires_after))
      end

      def mute_duration(config)
        Core::Warnings.duration_seconds(config_value(config, :mute_duration)) || DEFAULT_MUTE_DURATION
      end

      def effective_action(action, config)
        return action if IMPLEMENTED_ACTIONS.include?(action)

        stub = normalise_stub(config_value(config, :stub_action))
        unless @warnings
          @logger.warn do
            "link_filter: #{action} escalation needs the warnings service; applying only the #{stub.inspect} containment"
          end
        end
        stub
      end

      def posture_for(config)
        candidate = config_value(config, :posture).to_s
        POSTURES.include?(candidate) ? candidate : DEFAULT_POSTURE
      end

      # These fields were once called allowlist and blocklist; the old names
      # are still accepted on read, since dropping this would silently empty
      # a community's lists on upgrade. New writes use the new names.
      LEGACY_FIELD_NAMES = { whitelist: :allowlist, blacklist: :blocklist,
                             whitelisted_invites: :allowed_invites }.freeze

      def list_value(config, key)
        current = config_value(config, key)
        return current unless current.nil? || (current.respond_to?(:empty?) && current.empty?)

        legacy = LEGACY_FIELD_NAMES[key.to_sym]
        legacy ? config_value(config, legacy) : current
      end

      # Each entry lowercased and stripped of scheme, leading www. and path, so an
      # operator can paste a full URL or a bare domain and it still matches a host.
      def domain_list(config, key)
        Array(list_value(config, key)).filter_map do |entry|
          host = host_of(entry.to_s.strip)
          host.empty? ? nil : host
        end
      end

      def requested_action(config)
        candidate = config_value(config, :action).to_s
        ACTIONS.include?(candidate) ? candidate : DEFAULT_ACTION
      end

      def normalise_stub(value)
        candidate = value.to_s
        IMPLEMENTED_ACTIONS.include?(candidate) ? candidate : DEFAULT_STUB_ACTION
      end

      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def truthy(value, default:)
        return default if value.nil?
        return value if value == true || value == false

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end
    end
  end
end
