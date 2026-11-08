# frozen_string_literal: true

module Rubotty
  module Features
    # A room gate for announcement-style rooms. Approved platform identities can
    # post normally; every other post is removed before the bridge sees it and
    # receives a source-side acknowledgement through the shared removal flow.
    # An operator grows or shrinks the approved list in place with /whitelist
    # and /unwhitelist, so the list never has to be edited by hand off-platform.
    # A name nobody has seen post yet has no stable identity to approve, so it
    # is written down as a name and bound to one the first time its owner
    # speaks here, which is the only order an invite can happen in.
    class ModeratedRoom < Base
      SOURCE = "moderated_room"
      NOTICE_NAME = "room moderation"

      WHITELIST_COMMAND = "whitelist"
      UNWHITELIST_COMMAND = "unwhitelist"
      WHITELIST_COMMANDS = [WHITELIST_COMMAND, UNWHITELIST_COMMAND].freeze
      APPROVED_USERS_FIELD = :approved_users

      # Names an operator has approved that no stable identity is known for
      # yet, held here until their owner posts. Entries are platform:handle
      # with the handle folded to lower case, and each one is replaced by an
      # approved_users entry the moment it binds.
      PENDING_HANDLES_FIELD = :pending_handles

      # Set by /lock and cleared by /unlock (see {Features::Moderation}), not
      # edited directly. True ignores approved_users entirely and requires an
      # operator to post, with no reply exemption.
      LOCKED_FIELD = :locked

      DEFAULT_REMOVAL_REASON = "This room is moderated and only approved members may post."
      REPLY_EXEMPTION_REMOVAL_REASON = "This room is moderated. Only approved members may start a conversation, but you may reply to an approved poster."
      REMEMBERED_APPROVED_POSTS = 10_000

      def self.feature_name = "moderated_room"

      def self.description = "Restricts a room to approved users, with an optional reply-only exception, " \
                              "and lets an operator run /whitelist and /unwhitelist to grow or shrink the list."

      def self.default_enabled? = false

      # An edit can turn an old message into a new post after the room is
      # moderated, so it takes the same containment path as a fresh chat event.
      def self.observes = %i[chat edit]

      # The two list edits this feature answers, which the registry does not carry.
      def self.command_words = WHITELIST_COMMANDS

      # `approved_users` uses stable platform identities, not display names or
      # handles that an account can rename: `telegram:12345`, `discord:67890`.
      # Matrix ids retain their later colon because only the first separator is
      # structural, for example `matrix:@ada:example.org`.
      def self.config_schema
        Config::Schema.define do
          field :approved_users, :array, of: :string, default: [],
                desc: "approved platform identities as platform:native_id, for example telegram:12345"
          field PENDING_HANDLES_FIELD, :array, of: :string, default: [],
                desc: "approved names with no known identity yet, as platform:handle, " \
                      "each bound to an approved_users entry the first time its owner posts"
          field :allow_replies_to_approved_users, :boolean, default: false,
                desc: "allow unapproved users to reply to an approved poster without allowing a new post"
          field LOCKED_FIELD, :boolean, default: false,
                desc: "when true, only operators may post here and approved_users is ignored; " \
                      "set by /lock and cleared by /unlock rather than edited by hand"
          field Core::RemovalNotice::TTL_FIELD, :integer, default: Core::RemovalNotice::DEFAULT_TTL_SECONDS,
                desc: "seconds the self-deleting moderation acknowledgement lives before removal"
        end
      end

      # @param topology [Core::Topology] resolves any relayed copy while an edit removes it
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] shared adapter map
      # @param storage [Storage::Base] message map for removing previous copies
      # @param ephemeral [Core::EphemeralMessage, nil] the gate's removal notice and a /whitelist ack
      # @param cleanup [Core::Scheduler, nil] on-time acknowledgement cleanup
      # @param audit [Core::AuditLog::Sequel, Core::AuditLog::Null, nil] audit sink
      # @param feature_controls [ControlPlane::FeatureControls, nil] where /whitelist writes approved_users back
      # @param identity_directory [ControlPlane::IdentityDirectory, nil] resolves a /whitelist handle nobody has merged into a person row
      def initialize(topology:, adapters:, storage:, logger:, ephemeral: nil, cleanup: nil, audit: nil,
                     feature_controls: nil, identity_directory: nil)
        @storage = storage
        @logger = logger
        @cleanup = cleanup
        @feature_controls = feature_controls
        @identity_directory = identity_directory
        # Reused as-is, not defaulted: a nil ephemeral has always meant "stay
        # silent" for this feature's own notices, and a command ack keeps that.
        @ephemeral = ephemeral
        # The map knows where a relayed parent came from but deliberately keeps
        # no author data. Remember only accepted source posts, bounded so a busy
        # announcement room does not grow the exemption state without limit.
        @approved_posts = {}
        @approved_posts_lock = Mutex.new
        super()
        @removal = Watchdog::Removal.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          source: SOURCE, name: NOTICE_NAME, ephemeral: ephemeral, cleanup: cleanup, audit: audit
        )
      end

      attr_reader :logger

      def call(context)
        word, arguments = whitelist_command(context)
        return handle_whitelist_command(context, word, arguments) if word

        if allowed_author?(context)
          remember_approved_post(context.message)
          return Outcome.continue([])
        end
        if claim_pending_handle(context)
          remember_approved_post(context.message)
          return Outcome.continue([])
        end
        return Outcome.continue([]) if reply_exempt?(context)

        Outcome.halt(
          @removal.apply(
            context: context, reason: removal_reason(context.config),
            metadata: { reply_exemption: effective_reply_exemption?(context.config) }
          )
        )
      end

      private

      # Locked ignores approved_users entirely and requires an operator
      # instead; unlocked is the ordinary whitelist check.
      def allowed_author?(context)
        return !resolve_operator(context).nil? if locked?(context.config)

        approved_author?(context.message.author, context.message.origin, context.config)
      end

      # The /whitelist or /unwhitelist word this message opens with plus its
      # arguments, or [nil, nil]: not chat, no configured prefix, or a word this
      # feature does not answer.
      def whitelist_command(context)
        return [nil, nil] unless context.message.kind == :chat

        word, arguments = CommandWord.parse(context)
        WHITELIST_COMMANDS.include?(word) ? [word, arguments] : [nil, nil]
      end

      # /whitelist and /unwhitelist are always consumed once recognised, whether
      # they ran, were refused, or found nobody to act on, so a mistyped or
      # refused command never relays through as chat.
      def handle_whitelist_command(context, word, arguments)
        return refuse(context, "Sorry, /#{word} is not available on this bridge.") if unavailable?(context)

        operator = resolve_operator(context)
        if operator.nil?
          return refuse(context, Core::Commands::Refusal.new(reason: :not_permitted, action: word.to_sym).message)
        end

        room_key = context.community.room_key_of(context.channel)
        return refuse(context, "Sorry, /#{word} is not available on this bridge.") if room_key.nil?

        identity = target_identity(context, arguments)
        return pending_command(context, room_key, word, arguments) if identity.nil?

        write_approved_users(context, room_key, word, identity)
        drop_pending_handle(context, room_key, named_handle(arguments))
        acknowledge(context, whitelist_confirmation(word, identity))
        Outcome.halt([])
      rescue StandardError => e
        logger.warn { "moderated_room: could not handle /#{word}: #{e.class}: #{e.message}" }
        acknowledge(context, "Could not update this room's whitelist right now.")
        Outcome.halt([])
      end

      def unavailable?(context) = context.community.nil? || @feature_controls.nil?

      def refuse(context, text)
        acknowledge(context, text)
        Outcome.halt([])
      end

      # What is left once a named handle has been filed as pending instead:
      # a bare command with nothing to act on, or an /unwhitelist naming
      # somebody neither approved nor pending. The first already tried the
      # reply route, so pointing at it again would be circular.
      def not_found_message(word, arguments)
        handle = Array(arguments).first
        return "Could not find that person to /#{word}." if handle.nil? || handle.to_s.strip.empty?

        "Could not find that person to /#{word}. Reply to one of their messages with /#{word} instead."
      end

      # A name nobody has seen post yet is the ordinary case for an invite:
      # no platform lets a bot turn a username into an account id before its
      # owner has spoken. File it as a name to bind on first sight rather than
      # refusing, and say plainly that the approval is not live yet.
      def pending_command(context, room_key, word, arguments)
        handle = named_handle(arguments)
        return refuse(context, not_found_message(word, arguments)) if handle.nil?

        # The write itself says whether the name was there, read under its own
        # lock. An /unwhitelist that changed nothing found nobody, and says so
        # rather than reporting a removal that did not happen.
        changed = write_pending_handles(context, room_key, word, handle)
        return refuse(context, not_found_message(word, arguments)) if word == UNWHITELIST_COMMAND && !changed

        acknowledge(context, pending_confirmation(word, handle))
        Outcome.halt([])
      end

      # The command's own argument, normalised the one way both sides of the
      # comparison use: no leading @, folded to lower case.
      def named_handle(arguments)
        handle = Array(arguments).first.to_s.strip.delete_prefix("@").downcase
        handle.empty? ? nil : handle
      end

      def pending_confirmation(word, handle)
        return "Removed @#{handle} from this room's pending whitelist." if word == UNWHITELIST_COMMAND

        "Nobody here goes by @#{handle} yet. They will be added to this room's whitelist the first time they post."
      end

      def whitelist_confirmation(word, identity)
        entry = identity.join(":")
        word == WHITELIST_COMMAND ? "Added #{entry} to this room's whitelist." : "Removed #{entry} from this room's whitelist."
      end

      # Only an operator may whitelist or unwhitelist, the same as every
      # moderation verb but self-delete. Resolved against this message's own
      # community, so a grant never crosses a tenant.
      def resolve_operator(context)
        author = context.message.author
        return nil if author.nil?

        context.operators&.resolve(
          context.message.origin.adapter_name, author.native_id, username: author.username
        )
      end

      # The person named by /whitelist's argument, or the author of the message
      # replied to when no argument was given: an @handle or bare username
      # resolves through the community's own people directory, a reply carries
      # the target's native id directly and needs no lookup at all.
      def target_identity(context, arguments)
        handle = Array(arguments).first
        return reply_target_identity(context) if handle.nil? || handle.to_s.strip.empty?

        handle_target_identity(context, handle)
      end

      # The mentionable-people directory first, since it is instant and already
      # loaded; a miss there falls to the observed directory, which is where
      # everybody who has not been merged into a person row actually lives.
      # {IdentityDirectory#resolve_unique} answers only an UNAMBIGUOUS handle
      # and only its CURRENT owner, the same rule cross-platform mentions
      # already resolve by, so a name two accounts have both worn stays a
      # refusal rather than a guess at posting rights.
      def handle_target_identity(context, raw_handle)
        handle = raw_handle.to_s.strip.delete_prefix("@")
        return nil if handle.empty?

        adapter = context.message.origin.adapter_name
        person = context.people&.by_handle(adapter, handle)
        native_id = person&.id_on(adapter)
        native_id ||= @identity_directory&.resolve_unique(
          community_id: context.community&.id, adapter: adapter, handle: handle
        )
        return nil if native_id.nil?

        identity_for(adapter, native_id)
      end

      def reply_target_identity(context)
        return nil unless context.message.reply?

        author = context.message.reply_preview&.author
        return nil if author.nil? || author.native_id.nil?

        identity_for(context.message.origin.adapter_name, author.native_id)
      end

      def identity_for(adapter_name, native_id) = [adapter_name.to_s.downcase, native_id.to_s]

      # Read-modify-write approved_users at the room's own scope, held under one
      # lock by {ControlPlane::FeatureControls#update} so two operators saving at
      # once cannot drop each other's entry.
      def write_approved_users(context, room_key, word, identity)
        entry = identity.join(":")
        @feature_controls.update(
          community: context.community, selector: room_key,
          feature: self.class.feature_name, key: APPROVED_USERS_FIELD
        ) do |current|
          list = Array(current).map(&:to_s)
          word == WHITELIST_COMMAND ? (list.include?(entry) ? list : list + [entry]) : (list - [entry])
        end
      end

      # The other half of a /whitelist that named somebody the bot had never
      # seen. An unapproved author whose current username is on this room's
      # pending list is who the operator meant, so the post stands and the name
      # becomes a stable identity now that there is one to record. Locked
      # ignores this exactly as it ignores approved_users.
      def claim_pending_handle(context)
        return false if locked?(context.config)

        handle = context.message.author&.username.to_s.strip.delete_prefix("@").downcase
        return false if handle.empty?
        return false unless pending_handles(context.config).include?([adapter_of(context), handle])

        promote_pending_handle(context, handle)
        true
      end

      # Trade the name for the id and drop the name, so the approval survives a
      # rename from here on. A write that fails still lets the post through:
      # the operator said this person may post, and the binding is bookkeeping.
      def promote_pending_handle(context, handle)
        native_id = context.message.author&.native_id
        room_key = context.community&.room_key_of(context.channel)
        return if native_id.nil? || room_key.nil? || @feature_controls.nil?

        write_approved_users(context, room_key, WHITELIST_COMMAND, identity_for(adapter_of(context), native_id))
        write_pending_handles(context, room_key, UNWHITELIST_COMMAND, handle)
      rescue StandardError => e
        logger.warn { "moderated_room: could not bind @#{handle} to an identity: #{e.class}: #{e.message}" }
      end

      # Read-modify-write the pending list at the room's own scope, under the
      # same lock approved_users is held by, so a bind landing while an operator
      # saves cannot drop either edit. Answers whether the list actually moved,
      # decided against the stored row rather than a snapshot that may predate
      # somebody else's save.
      def write_pending_handles(context, room_key, word, handle)
        entry = "#{adapter_of(context)}:#{handle}"
        adding = word == WHITELIST_COMMAND
        changed = false
        @feature_controls.update(
          community: context.community, selector: room_key,
          feature: self.class.feature_name, key: PENDING_HANDLES_FIELD
        ) do |current|
          list = Array(current).map(&:to_s)
          held = list.include?(entry)
          changed = adding ? !held : held
          adding ? (held ? list : list + [entry]) : (list - [entry])
        end
        changed
      end

      # A name that resolved to somebody has no business staying pending: on
      # /whitelist the identity supersedes it, on /unwhitelist leaving it would
      # let the same person bind straight back on their next message.
      def drop_pending_handle(context, room_key, handle)
        return if handle.nil?

        write_pending_handles(context, room_key, UNWHITELIST_COMMAND, handle)
      end

      # The same exact-pair rule approved_identities holds entries to, except
      # that the second half is a name rather than an id, so it is compared
      # case-insensitively and with any leading @ dropped: no platform this
      # bridges treats those as part of the username.
      def pending_handles(config)
        Array(config_value(config, PENDING_HANDLES_FIELD)).filter_map do |entry|
          platform, handle = entry.to_s.strip.split(":", 2)
          next if platform.nil? || platform.empty?

          name = handle.to_s.strip.delete_prefix("@").downcase
          next if name.empty?

          [platform.downcase, name]
        end
      end

      def adapter_of(context) = context.message.origin.adapter_name.to_s.downcase

      # The same self-deleting acknowledgement shape every command feature uses,
      # reusing this feature's own removal-notice TTL rather than a new field.
      # A nil ephemeral (no notices configured at all) leaves it a silent no-op.
      def acknowledge(context, text)
        return if @ephemeral.nil?

        delay = Core::RemovalNotice.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text), name: NOTICE_NAME,
          delete_after: delay, also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
      rescue StandardError => e
        logger.warn { "moderated_room: could not acknowledge a command: #{e.message}" }
      end

      # A reply is only exempt when the parent author is known locally and is on
      # the same room's whitelist. A pointer without the parent identity fails
      # closed, since allowing it would turn a forged or incomplete reply into a
      # new-post bypass. Native threads carry their root creator's stable id for
      # the same reason.
      #
      # Locked overrides all of this unconditionally: it is meant to read as
      # an absolute stop, stricter than this carve-out ever allows.
      def reply_exempt?(context)
        return false if locked?(context.config)
        return false unless reply_exemption_enabled?(context.config)

        message = context.message
        if message.reply?
          parent = message.reply_preview&.author
          return true if approved_author?(parent, message.origin, context.config)

          return remembered_approved_parent?(message.reply_to, context.config)
        end

        thread = message.thread
        return false if thread.nil? || thread.creator_native_id.nil?

        approved_identity?(message.origin.adapter_name, thread.creator_native_id, context.config)
      end

      def approved_author?(author, origin, config)
        return false if author.nil? || author.native_id.nil? || origin.nil?

        approved_identity?(origin.adapter_name, author.native_id, config)
      end

      # A native reply to a bridged copy names the copy, whose platform payload
      # generally identifies the bridge webhook rather than the original poster.
      # The message map leads back to the source ref and this bounded cache carries
      # that source's identity for this process. A restart forgets it and blocks
      # the reply, which is safer than trusting a rendered webhook display name.
      def remembered_approved_parent?(reply_ref, config)
        return false if reply_ref.nil?

        refs = [reply_ref] + @storage.origins(reply_ref)
        refs.any? do |ref|
          identity = @approved_posts_lock.synchronize { @approved_posts[ref] }
          identity && approved_identity?(identity.first, identity.last, config)
        end
      rescue StorageError
        false
      end

      def remember_approved_post(message)
        author = message.author
        return if message.ref.nil? || author.nil? || author.native_id.nil?

        identity = [message.origin.adapter_name.to_s.downcase, author.native_id.to_s]
        @approved_posts_lock.synchronize do
          @approved_posts.delete(message.ref)
          @approved_posts[message.ref] = identity
          @approved_posts.shift while @approved_posts.size > REMEMBERED_APPROVED_POSTS
        end
      end

      def approved_identity?(adapter, native_id, config)
        approved_identities(config).include?([adapter.to_s.downcase, native_id.to_s])
      end

      # A malformed value is ignored rather than matching loosely. The only
      # accepted form is an exact platform/native-id pair, preserving the
      # platform namespace even where two networks assign the same numeric id.
      def approved_identities(config)
        Array(config_value(config, :approved_users)).filter_map do |entry|
          platform, native_id = entry.to_s.strip.split(":", 2)
          next if platform.nil? || platform.empty? || native_id.nil? || native_id.empty?

          [platform.downcase, native_id]
        end
      end

      def reply_exemption_enabled?(config)
        truthy(config_value(config, :allow_replies_to_approved_users), default: false)
      end

      def locked?(config) = truthy(config_value(config, LOCKED_FIELD), default: false)

      # Whether the reply exemption actually applies right now: configured on,
      # and not overridden off by a lock.
      def effective_reply_exemption?(config)
        reply_exemption_enabled?(config) && !locked?(config)
      end

      def removal_reason(config)
        effective_reply_exemption?(config) ? REPLY_EXEMPTION_REMOVAL_REASON : DEFAULT_REMOVAL_REASON
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
