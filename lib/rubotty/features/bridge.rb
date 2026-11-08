# frozen_string_literal: true

require "digest"
require "rubotty/core/relay_leases"

module Rubotty
  module Features
    # The chat-bridging relay: fans a canonical message out to every other
    # endpoint in every room the origin belongs to, and propagates edits, deletes
    # and reactions across those copies. Terminal, so every kind it handles halts.
    class Bridge < Base
      include AdapterLookup

      # Relay policy names checked against {Core::Endpoint#relay?}.
      POLICY_FOR_KIND = {
        join: :join_messages,
        leave: :leave_messages,
        system: :system_messages
      }.freeze

      # The per-scope config key for rewriting `@handle@platform` tokens into
      # native pings.
      CROSS_PLATFORM_MENTIONS_KEY = :cross_platform_mentions

      # The per-scope config key for the line added when a message from inside a
      # thread reaches a platform that has no threads to put it in.
      THREAD_REPLY_NOTICES_KEY = :thread_reply_notices

      # The per-scope config key for expanding a Discord `<t:UNIX:FORMAT>`
      # timestamp into readable, multi-timezone plain text when it reaches a
      # target that cannot resolve the markup live the way Discord's own
      # client does. See {#expand_timestamps}.
      TIMESTAMP_TIMEZONES_KEY = :timestamp_timezones

      # The per-scope config key for how a reaction is represented on a target:
      # the real emoji, a text line, or both. See {#mirror_reactions}.
      REACTION_NOTICES_KEY = :reaction_notices

      # The per-scope config key for a text line standing in for an edit a target
      # cannot apply natively (IRC, XMPP). See {#post_edit_notice}.
      EDIT_NOTICES_KEY = :edit_notices

      # The per-scope config key for a text line standing in for a delete a
      # target cannot apply natively (IRC, XMPP). See {#post_delete_notice}.
      DELETE_NOTICES_KEY = :delete_notices

      # The actor id an unattributed reaction is held under. Empty on purpose:
      # Core::Author normalises an empty native id to nil, so no platform
      # identity can collide with it and no person's count can be moved by it.
      NO_ACTOR = ""
      DELETE_RETRY_KIND = "bridge_delete_retry"

      # The three ways a reaction can reach a target. both is the default: a
      # reaction on a target that cannot hold one natively would otherwise be
      # invisible there, and targets_for already excludes an unbridged room's
      # single endpoint, so this only ever posts where there is another
      # platform to actually reach.
      REACTION_NOTICE_MODES = %i[native notice both].freeze

      # A cross-platform mention token, `@handle@platform`. The leading-@
      # requirement and the negative lookbehind keep it from matching inside a
      # `user@host`.
      CROSS_PLATFORM_MENTION = /(?<![\w@])@([\w.-]+)@([\w.-]+)/

      # A bare platform handle. The trailing guard leaves an explicit
      # `@handle@platform` token to {CROSS_PLATFORM_MENTION}, including when
      # its platform does not name this target.
      BARE_CROSS_PLATFORM_MENTION = /(?<![\w@])@([\w.-]+)(?![\w.@-])/

      # The handle half of both mention tokens above. A candidate handle that
      # does not match cannot be typed back as a tag, so the ambiguity reply
      # never offers one.
      SELECTABLE_HANDLE = /\A[\w.-]+\z/

      CROSS_PLATFORM_MENTION_NOTICE_NAME = "Rubotty"
      CROSS_PLATFORM_MENTION_NOTICE_TTL = 30

      # The directory and community cross-platform mentions resolve against; nil
      # disables the rewrite entirely.
      MentionScope = Struct.new(:directory, :community_id, keyword_init: true)

      PartialMentionAmbiguity = Struct.new(:handle, :adapter, :matches, keyword_init: true)

      # Platforms whose own mention token (`<@id>`) already replaces its display
      # text, live, client side: Discord itself, and Fluxer/Stoat, which are
      # Discord shaped and share {Rendering::DiscordMarkdown} for exactly that
      # reason. A mention resolved for any other target has its visible text
      # rewritten here instead, since nothing downstream will (see {#build_mention_label}).
      NATIVE_MENTION_TEXT_PLATFORMS = %i[discord fluxer stoat].freeze

      # The per-scope relay decisions for one message, threaded down the fan-out
      # as an argument: one Bridge serves every room worker concurrently, so
      # per-message state never sits on the instance. +pending_video+ collects,
      # per target id, what {AttachmentRehoster#place} could only link because
      # the file was a video; {#schedule_pending_video} reads it back once
      # delivery has actually happened.
      RelayScope = Struct.new(:mentions, :thread_notices, :rehosting, :rehosted, :pending_video,
                              :timestamp_zones, :mention_ambiguities, :failed_deliveries, keyword_init: true)

      # The community a rehost decision needs, as an id for the row and as a
      # Snapshot for the per-room feature lookup.
      RehostScope = Struct.new(:community_id, :community, keyword_init: true)

      def self.feature_name = "bridge"

      def self.description = "Relays messages between every platform bridged into a room."

      def self.default_enabled? = true

      # The per-scope config the dashboard and loader validate.
      def self.config_schema
        Config::Schema.define do
          field :cross_platform_mentions, :boolean, default: true,
                desc: "rewrite foreign @handle and @handle@platform tokens into native pings, resolved " \
                      "against the passively-learned identity directory; a bare @handle never resolves " \
                      "in a single-platform room, where the platform's own mention handling is the only " \
                      "source of a ping"
          field :thread_reply_notices, :boolean, default: false,
                desc: "when a message posted inside a thread or forum topic is relayed to " \
                      "a platform that cannot represent that thread, add a short line " \
                      "naming the thread and whoever started it instead of flattening it"
          field :reaction_notices, :symbol, default: :both, one_of: REACTION_NOTICE_MODES,
                desc: "how a reaction reaches a target: native places the real emoji where " \
                      "the platform supports it and stays silent where it does not, notice " \
                      "posts a short \"user@platform reacted <emoji>\" line instead, both " \
                      "(default) places the emoji where possible and always posts the line too"
          field :edit_notices, :boolean, default: false,
                desc: "when an edit cannot be applied natively on a target (IRC, XMPP), " \
                      "add a short line saying the message was edited instead of leaving " \
                      "the original standing unedited with no notice"
          field :delete_notices, :boolean, default: false,
                desc: "when a delete cannot be applied natively on a target (IRC, XMPP), " \
                      "add a short line saying the message was removed instead of leaving " \
                      "the original standing forever with no notice"
          field :timestamp_timezones, :array, of: Config::Schema.define {
            field :label, :string, required: true, desc: "the visible name of this time zone" do |value, path|
              "#{path}: cannot be blank" if value.strip.empty?
            end
            field :iana_timezone, :string, required: true, desc: "an IANA zone such as Europe/Lisbon" do |value, path|
              "#{path}: cannot be blank" if value.strip.empty?
            end
          }, default: TimestampExpansion::DEFAULT_ZONES,
                desc: "ordered {label, iana_timezone} pairs, e.g. {label: \"Pacific\", " \
                      "iana_timezone: \"America/Los_Angeles\"}; a Discord <t:UNIX:FORMAT> " \
                      "timestamp relayed to a non-Discord target, and every time a bridge " \
                      "card writes, expands into a readable time for each pair instead of " \
                      "showing as raw markup or one fixed zone. The first pair is this " \
                      "scope's home zone for the Today/Tomorrow/weekday label. Unset means " \
                      "Pacific, Eastern, Western Europe and Central Europe; set it to an " \
                      "empty list to render nothing but the fixed zone"
        end
      end

      def self.observes
        %i[chat join leave system edit delete reaction_add reaction_remove reaction_sync
           reaction_clear]
      end

      def initialize(topology:, adapters:, storage:, loop_guard:, logger:,
                     default_display_name: Core::DisplayName.new, ttl: nil, claim_ttl: nil,
                     reply_preview_chars: 100, reply_preview_lines: 2,
                     people: Core::Directory.new, suppress_notices: false,
                     retry_policy: nil, pacer: nil, identity_directory: nil, live_feed: nil,
                     redirection_window: nil, rehoster: nil, webhooks: nil,
                     relay_fingerprints: nil, relay_outcomes: nil, endpoint_health: nil, warnings: nil,
                     ephemeral: nil, cleanup: nil, durable_scheduler: nil, relay_leases: nil)
        super()
        @topology = topology
        @adapters = adapters
        @storage = storage
        @loop_guard = loop_guard
        @logger = logger
        @default_display_name = default_display_name
        @ttl = ttl
        # The relay claim outlives the message map on purpose: the map bounds edit
        # and delete propagation, the claim is what a backfill sweep checks before
        # re-feeding a message. Falls back to ttl so an old caller keeps working.
        @claim_ttl = claim_ttl || ttl
        @reply_preview_chars = reply_preview_chars
        @reply_preview_lines = reply_preview_lines
        @people = people
        @suppress_notices = suppress_notices
        @retry = retry_policy || Core::RetryPolicy.new(logger: logger)
        # Shared across every room, since a platform's per account limit is one
        # budget however many rooms are spending it.
        @pacer = pacer || Core::OutboundPacer.new(logger: logger)
        # Nil without a control plane, which keeps the mention rewrite inert there.
        @identity_directory = identity_directory
        # The seconds-long buffer the REST API's live stream reads.
        @live_feed = live_feed
        # Webhooks#emit inserts a row and returns, the sending happening later on
        # the durable scheduler, so a slow subscriber cannot reach this thread.
        @webhooks = webhooks
        # Written only for the rooms an operator switched redirection on for.
        @redirection_window = redirection_window
        # Nil wherever the object store could not be made ready; a too-big file is
        # then relayed exactly as it was before.
        @rehoster = rehoster
        # The per-endpoint content ledger (migration 053): written on arrival and
        # on every successful post, read back before each post to skip a target
        # that already has this content. Nil without a control plane, which
        # leaves the relay exactly as it was.
        @relay_fingerprints = relay_fingerprints
        # Where a paced backfill relay learns what became of each copy it fed
        # in, and what rate a destination will accept. Records nothing for a
        # message no sweep asked it to follow, so live traffic writes nothing.
        @relay_outcomes = relay_outcomes
        # Unlike relay_outcomes, which records only what a backfill sweep asked
        # it to watch, this is written for every live delivery: it is what says
        # a destination has stopped accepting posts at all.
        @endpoint_health = endpoint_health
        # The shared warnings coordinator: gates a new chat message on an
        # active mute, since the bridge is the one place every message passes
        # through regardless of what the origin platform itself could enforce.
        # Nil without a control plane, which leaves the relay exactly as it was.
        @warnings = warnings
        @ephemeral = ephemeral
        @cleanup = cleanup
        @relay_leases = relay_leases || Core::RelayLeases.new(storage: storage, logger: logger)
        @durable_scheduler = durable_scheduler
        @durable_scheduler&.register(DELETE_RETRY_KIND) { |job| retry_pending_delete(job) }
      end

      attr_reader :logger

      # Dispatch by kind. The bridge is terminal, so every branch halts.
      def call(context)
        message = context.message
        # A synthetic message (see Core::Message#synthetic) names no real platform
        # message, so its ref is an id the platform's REST API would refuse.
        return Outcome.halt([]) if message.synthetic?

        scope = relay_scope(context)
        # The community scopes the exactly-once relay claim, so both containers of
        # a deploy overlap compute the same key. Nil without a control plane.
        community = context.community&.id
        case message.kind
        when :edit then Outcome.halt(handle_edit(message, scope, community: community,
                                                                 community_scope: context.community,
                                                                 edit_notices: edit_notices_enabled?(context.config)))
        when :delete then Outcome.halt(handle_delete(message, community: community,
                                                              delete_notices: delete_notices_enabled?(context.config)))
        when :reaction_add, :reaction_remove
          Outcome.halt(handle_reaction(message, community: community,
                                                reaction_notices: reaction_notices_mode(context.config)))
        when :reaction_sync
          Outcome.halt(handle_reaction_sync(message, community: community,
                                            reaction_notices: reaction_notices_mode(context.config)))
        when :reaction_clear
          Outcome.halt(handle_reaction_clear(message, community: community,
                                             reaction_notices: reaction_notices_mode(context.config)))
        else Outcome.halt(handle_new(message, scope, community: community, community_scope: context.community))
        end
      end

      # Reactions mirror as aggregate state: relaying "Alice removed a thumbs up"
      # would take away a mirror Bob's identical reaction still holds up. Each
      # event updates per-actor state, then the whole set is pushed to reconcile.
      def handle_reaction(message, community: nil, reaction_notices: :native)
        if message.reaction.nil?
          logger.debug { "dropped a reaction on #{message.ref}, it names no emoji" }
          return []
        end

        rooms = @topology.rooms_for(message.origin.id)
        if rooms.empty?
          logger.debug { "dropped a reaction on #{message.ref}, endpoint #{message.origin.id} is in no room" }
          return []
        end

        actor = message.author&.native_id
        if actor.nil?
          # An anonymous reaction (Telegram reports these on behalf of a chat)
          # cannot be attributed, so aggregating it would corrupt everyone's count.
          logger.debug { "dropped a reaction on #{message.ref}, it names no actor to count" }
          return []
        end

        # The claim is keyed by actor and reaction: a redelivered add is a no-op,
        # while a remove releases the add's claim so a re-add later wins a fresh one.
        operation = reaction_operation(message.reaction, actor)
        if message.kind == :reaction_add
          unless claim_event(message.ref, operation, community)
            logger.debug { "dropped a reaction on #{message.ref}, already relayed by another instance" }
            return []
          end
        else
          release_event(message.ref, operation, community)
        end

        previous = @storage.reactions_on(message.ref)
        if message.kind == :reaction_add
          @storage.add_reaction(message.ref, reaction: message.reaction, actor_id: actor,
                                expires_at: reaction_expiry(message.ref))
        else
          @storage.remove_reaction(message.ref, reaction: message.reaction, actor_id: actor)
        end
        desired = @storage.reactions_on(message.ref)

        # An unchanged aggregate leaves the native mirror nothing to place, since
        # the emoji it would add is already sitting there. A notice can still be
        # due: the second person to hold an emoji somebody else already holds
        # moves nothing in the set and is still worth a line.
        if desired == previous && !reaction_notice?(reaction_notices)
          logger.debug { "placed no emoji for a reaction on #{message.ref}, the aggregate did not move" }
          return []
        end

        reaction_event = message.kind == :reaction_add ? ControlPlane::Webhooks::REACTION_ADDED :
                                                          ControlPlane::Webhooks::REACTION_REMOVED
        rooms.flat_map do |room|
          notify_webhooks_change(message, community, reaction_event, data: { "reaction" => message.reaction.label })
          mirror_reactions(room, message, desired, previous, mode: reaction_notices, community: community)
        end
      rescue StorageError => e
        logger.error { "could not update reaction state for #{message.ref}: #{e.message}" }
        []
      end

      # A count-only reaction update: the platform states the whole set of reactions on
      # the message with nobody attributed. Goes through {NO_ACTOR} instead of the
      # per-actor path, replacing that row wholesale; takes no claim, so a redelivered
      # snapshot moves nothing.
      def handle_reaction_sync(message, community: nil, reaction_notices: :native)
        rooms = @topology.rooms_for(message.origin.id)
        if rooms.empty?
          logger.debug do
            "dropped a reaction count on #{message.ref}, endpoint #{message.origin.id} is in no room"
          end
          return []
        end

        previous = @storage.reactions_on(message.ref)
        hold_anonymously(message.ref, anonymous_set(message), previous)
        desired = @storage.reactions_on(message.ref)
        if desired == previous
          logger.debug { "placed no emoji for a reaction count on #{message.ref}, the aggregate did not move" }
          return []
        end

        rooms.flat_map do |room|
          mirror_reactions(room, message, desired, previous, mode: reaction_notices, community: community)
        end
      rescue StorageError => e
        logger.error { "could not update reaction state for #{message.ref}: #{e.message}" }
        []
      end

      # A bulk clear a platform reports with no author (Revolt clearing one emoji
      # everywhere, Discord's remove-all and remove-emoji events). Skips
      # {#hold_anonymously}, since a bulk clear takes down the whole aggregate, named
      # actors included, exactly as it happened on the platform; the row set for the
      # message (or one emoji on it) is dropped in storage directly.
      def handle_reaction_clear(message, community: nil, reaction_notices: :native)
        rooms = @topology.rooms_for(message.origin.id)
        if rooms.empty?
          logger.debug { "dropped a reaction clear on #{message.ref}, endpoint #{message.origin.id} is in no room" }
          return []
        end

        previous = @storage.reactions_on(message.ref)
        @storage.clear_reactions(message.ref, reaction: message.reaction)
        desired = @storage.reactions_on(message.ref)
        if desired == previous
          logger.debug { "placed no emoji for a reaction clear on #{message.ref}, the aggregate did not move" }
          return []
        end

        rooms.flat_map do |room|
          mirror_reactions(room, message, desired, previous, mode: reaction_notices, community: community)
        end
      rescue StorageError => e
        logger.error { "could not update reaction state for #{message.ref}: #{e.message}" }
        []
      end

      # Places the native emoji, posts a text line, or both, per +mode+ (see
      # {REACTION_NOTICES_KEY}); native and both still gate the emoji on the target's own
      # declared capability, so a platform with no reaction support gets no emoji
      # regardless of mode. A custom emoji minted on a different platform gets the same
      # treatment (see {#reaction_placeable?}): its id names an asset only that platform
      # holds, so handing it to #sync_reactions unfiltered would drop it silently or
      # raise for the whole batch.
      def mirror_reactions(room, message, desired, previous, mode: :native, community: nil)
        origin_adapter_name = message.origin.adapter_name
        room.targets_for(message.origin).filter_map do |target|
          unless target.relay?(:reactions)
            logger.debug { "dropped a reaction on #{message.ref} for #{target.id}, reactions are off there" }
            next nil
          end

          adapter = adapter_for(target)
          next nil if adapter.nil?

          # The counterpart of the reacted-to message on this target, or nil once
          # the map entry has expired or the message was never relayed here. The
          # emoji needs one; the line reads well enough without one.
          native_id = related_native_id(message.ref, target.id)
          if native_id.nil? && !reaction_notice?(mode)
            logger.debug { "dropped a reaction on #{message.ref} for #{target.id}, it holds no copy of it" }
            next nil
          end

          placeable = ->(reaction) { reaction_placeable?(adapter, target, origin_adapter_name, reaction) }
          desired_here = desired.select(&placeable)
          previous_here = previous.select(&placeable)
          log_stranded_reactions((desired - previous).reject(&placeable), message, target, origin_adapter_name)

          done = false
          if reaction_native?(mode) && !native_id.nil? && desired_here != previous_here
            if adapter.capabilities_for(target).reactions?
              place_emoji(adapter, target, message, native_id, desired_here, previous_here)
              done = true
            else
              logger.debug { "placed no emoji on #{target.id} for #{message.ref}, it cannot hold a reaction" }
            end
          end
          done = true if reaction_notice?(mode) && post_notice_for(
            adapter, target, message, native_id, community, room,
            added: desired - previous, removed: previous - desired
          )

          done ? Core::Moderation::Result.new(endpoint_id: target.id, status: :done) : nil
        rescue AdapterError => e
          # Loud, because the aggregate was already written and nothing ever
          # re-drives a mirror, so this copy is now showing something the stored
          # set disagrees with and a wedged message reads like a quiet one.
          logger.warn do
            "abandoned the reaction mirror of #{message.ref} onto #{target.id}: #{e.message}. " \
              "That copy keeps whatever emoji it is showing until the set moves again"
          end
          nil
        end
      end

      # Reconcile the emoji on one copy, retried on the policy a delivery uses: a rapid
      # run of reactions earns a rate limit, which refuses a call that never took
      # effect, so waiting it out is what keeps the stored aggregate and the platform
      # in step. The policy bounds how long a room waits.
      def place_emoji(adapter, target, message, native_id, desired, previous)
        @retry.call("reaction mirror of #{message.ref} onto #{target.id}") do
          adapter.sync_reactions(target, native_id, desired: desired, previous: previous)
        end
      end

      # Whether +reaction+ can actually land on +target+ as itself: a unicode emoji
      # always can, wherever the target holds reactions at all. A custom one belongs to
      # exactly one platform's own emoji library, so it survives only a crossing that
      # starts and ends on that platform, and only where the target declares it can hold
      # a custom emoji reaction (see Capabilities#custom_reactions?).
      def reaction_placeable?(adapter, target, origin_adapter_name, reaction)
        return true unless reaction.custom?

        adapter.capabilities_for(target).custom_reactions? &&
          target.adapter_name.to_s == origin_adapter_name.to_s
      end

      # Note, once per target, that a newly added reaction has no home there:
      # under native-only mode nothing shows on the target at all, so this line
      # says why instead of nothing anywhere saying so.
      def log_stranded_reactions(stranded, message, target, origin_adapter_name)
        stranded.each do |reaction|
          logger.info do
            "#{reaction.label} on #{message.ref} cannot cross to #{target.id}, " \
              "its emoji belongs to #{origin_adapter_name}"
          end
        end
      end

      # Post whichever text line this reaction has earned on +target+, or take
      # back the one an earlier add left behind, and answer whether anything was
      # actually said.
      def post_notice_for(adapter, target, message, native_id, community, room, added: [], removed: [])
        # A clear only ever takes emoji away, and it names nobody, so there is no
        # holder to look a line up under. The native mirror reconciles it.
        return false if message.reaction_clear?

        if message.reaction_sync?
          return sync_notices(adapter, target, message, native_id, community, room,
                              added: added, removed: removed)
        end
        return retract_reaction_notice(adapter, target, message, community) if message.kind == :reaction_remove
        return false unless reaction_notice_due?(message, target, community)

        post_reaction_notice(adapter, target, message, native_id, room, community)
        true
      end

      # A count update states the whole set, so it both adds and drops emoji.
      # Each new one earns its line and each one that has left the message has
      # its line taken back.
      def sync_notices(adapter, target, message, native_id, community, room, added:, removed:)
        posted = post_anonymous_notices(adapter, target, message, native_id, added, community, room)
        retracted = retract_anonymous_notices(adapter, target, message, removed, community)
        posted || retracted
      end

      def reaction_native?(mode) = mode == :native || mode == :both

      def reaction_notice?(mode) = mode == :notice || mode == :both

      # Noise control: one line per person per message per target, so a busy channel
      # doesn't get a wall of one-line status updates from every single reaction. The
      # relay claim tracks who has already been announced, so a spray of emoji from one
      # person still costs one line; a removal earns no line of its own,
      # {#retract_reaction_notice} takes the add's line back instead, once that person
      # holds nothing else on the message.
      def reaction_notice_due?(message, target, community)
        return false unless message.kind == :reaction_add

        actor = message.author&.native_id
        return false if actor.nil?

        claim_event(message.ref, reaction_notice_operation(target, actor), community)
      end

      # Post the "user@platform reacted <emoji>" line under the bot's own identity, the
      # same shape {#report_notes} uses for a bridge-owned notice, so a reader can tell
      # it apart from a relayed message. Replies to the target's own copy of the
      # reacted-to message when +native_id+ is known; otherwise the line lands loose.
      def post_reaction_notice(adapter, target, message, native_id, room, community)
        ref = notice_ref(target, message.ref, message.author&.native_id)
        notice = reaction_notice_message(ref, target, message, native_id, [message.reaction], community)
        remember_notice(ref, adapter.deliver(notice, target), room)
      end

      # The line itself, naming every emoji +reactions+ carries, so an edit that
      # narrows it down reads exactly the way the original did.
      def reaction_notice_message(ref, target, message, native_id, reactions, community)
        label = notice_label(message, target, community)
        Core::Message.new(
          kind: :system,
          ref: ref,
          origin: message.origin,
          author: Core::Author.new(display_name: "bridge", kind: :system),
          body: Core::RichText.plain("#{label} reacted #{reactions.map(&:label).join(" ")}"),
          reply_to: native_id.nil? ? nil : Core::MessageRef.new(target.id, native_id),
          sender_label: "bridge"
        )
      end

      # Take back the line an add left behind, now that the emoji it announced
      # is off the message. The claim goes back once this person holds nothing
      # else there, so a burst of emoji still costs one line while a reaction
      # placed later earns a fresh one.
      #
      # @return [Boolean] whether the line was actually touched
      def retract_reaction_notice(adapter, target, message, community)
        actor = message.author&.native_id
        return false if actor.nil?

        remaining = actor_reactions(message.ref, actor)
        operation = reaction_notice_operation(target, actor)
        release_event(message.ref, operation, community) if remaining.empty?

        ref = notice_ref(target, message.ref, actor)
        native_id = notice_native_id(ref, target)
        return false if native_id.nil?

        outcome = amend_notice(adapter, target, message, native_id, ref, remaining, community)
        if outcome == :deleted
          forget_notice(ref)
          # A delete-only target deletes the whole line even when this person still
          # holds reactions on it: the claim has nothing left to show for it either
          # way, so it goes back the same as the remaining.empty? case above.
          release_event(message.ref, operation, community) unless remaining.empty?
        end
        outcome != :kept
      end

      # Narrow the line down to what this person still holds, or take it away
      # once they hold nothing. A target that can neither edit nor delete keeps
      # the line it has, there being nothing else to be done with it.
      def amend_notice(adapter, target, message, native_id, ref, remaining, community)
        capable = adapter.capabilities_for(target)
        if remaining.empty? || !capable.edits?
          return :kept unless capable.deletes?

          adapter.delete(target, native_id)
          return :deleted
        end

        adapter.edit(reaction_notice_message(ref, target, message, nil, remaining, community), target, native_id)
        :edited
      end

      # What +actor+ still holds on +ref+. A storage failure reads as nothing,
      # which retracts the line and hands the claim back: a line taken back too
      # eagerly costs less than one contradicting the emoji next to it.
      def actor_reactions(ref, actor)
        @storage.reactions_by(ref, actor_id: actor)
      rescue StorageError => e
        logger.warn { "could not read what #{actor} still holds on #{ref}: #{e.message}" }
        []
      end

      # Where a posted line is recorded, so a later removal can find it. Built
      # from the reaction rather than remembered, since the removal arrives as
      # its own event carrying nothing of the add's.
      def notice_ref(target, ref, holder)
        Core::MessageRef.new(target.id, "reaction-notice:#{ref.endpoint_id}:#{ref.native_id}:#{holder}")
      end

      # Put the delivered line in the message map under its own key, the way
      # every other post this relay makes is recorded.
      def remember_notice(ref, receipt, room)
        return receipt if receipt.nil? || room.nil?

        @storage.record(source: ref, destination: receipt.ref, room_id: room.id,
                        expires_at: @ttl ? Time.now + @ttl : nil)
        receipt
      rescue StorageError => e
        logger.error { "could not record a reaction notice: #{e.message}" }
        receipt
      end

      # The id of the line posted under +ref+, or nil once it has aged out of
      # the map or was never posted here.
      def notice_native_id(ref, target)
        @storage.counterparts(ref, endpoint_id: target.id).last&.native_id
      rescue StorageError => e
        logger.warn { "could not look up a reaction notice: #{e.message}" }
        nil
      end

      def forget_notice(ref)
        @storage.forget(ref)
      rescue StorageError => e
        logger.warn { "could not drop the map entry for a reaction notice: #{e.message}" }
      end

      # The line for a reaction the platform attributes to nobody: one per emoji newly on
      # the message, with no name in it, claimed per emoji per target so a redelivered
      # snapshot says nothing twice. Keyed on the only holder identity a count update
      # offers, the same rule as the attributed path.
      #
      # @return [Boolean] whether anything was said
      def post_anonymous_notices(adapter, target, message, native_id, added, community, room = nil)
        platform = origin_platform_label(message.origin)
        posted = false
        added.each do |reaction|
          next unless claim_event(message.ref, anonymous_notice_operation(target, reaction), community)

          ref = notice_ref(target, message.ref, anonymous_holder(reaction))
          notice = Core::Message.new(
            kind: :system,
            ref: ref,
            origin: message.origin,
            author: Core::Author.new(display_name: "bridge", kind: :system),
            body: Core::RichText.plain("somebody on #{platform} reacted #{reaction.label}"),
            reply_to: native_id.nil? ? nil : Core::MessageRef.new(target.id, native_id),
            sender_label: "bridge"
          )
          remember_notice(ref, adapter.deliver(notice, target), room)
          posted = true
        end
        posted
      end

      # Take back the lines for emoji a count update says have left the message,
      # and hand each claim in so the same emoji coming back is announced again.
      # There is no set to narrow one of these down to, the line being about one
      # emoji, so it goes rather than being edited.
      #
      # @return [Boolean] whether any line was actually touched
      def retract_anonymous_notices(adapter, target, message, removed, community)
        touched = false
        removed.each do |reaction|
          release_event(message.ref, anonymous_notice_operation(target, reaction), community)

          ref = notice_ref(target, message.ref, anonymous_holder(reaction))
          native_id = notice_native_id(ref, target)
          next if native_id.nil?
          next unless adapter.capabilities_for(target).deletes?

          adapter.delete(target, native_id)
          forget_notice(ref)
          touched = true
        end
        touched
      end

      def anonymous_holder(reaction) = "anonymous:#{reaction.key}"

      # Post the "user@platform edited their message" line, the same fallback
      # {#post_reaction_notice} gives a reaction on a target that cannot hold
      # one, extended to an edit a target cannot apply natively. Replies to the
      # target's own copy, so the line reads against what changed.
      def post_edit_notice(adapter, endpoint, message, native_id, community)
        label = notice_label(message, endpoint, community)
        notice = Core::Message.new(
          kind: :system,
          ref: Core::MessageRef.new(endpoint.id, "edit-notice-#{message.correlation_id}"),
          origin: message.origin,
          author: Core::Author.new(display_name: "bridge", kind: :system),
          body: Core::RichText.plain("#{label} edited their message"),
          reply_to: Core::MessageRef.new(endpoint.id, native_id),
          sender_label: "bridge"
        )
        adapter.deliver(notice, endpoint)
      end

      # The delete counterpart of {#post_edit_notice}: a target that cannot
      # remove its own copy gets told the original is gone instead of showing
      # it forever with nothing to say it was withdrawn.
      def post_delete_notice(adapter, endpoint, message, native_id, community)
        label = notice_label(message, endpoint, community)
        notice = Core::Message.new(
          kind: :system,
          ref: Core::MessageRef.new(endpoint.id, "delete-notice-#{message.correlation_id}"),
          origin: message.origin,
          author: Core::Author.new(display_name: "bridge", kind: :system),
          body: Core::RichText.plain("#{label} deleted their message"),
          reply_to: Core::MessageRef.new(endpoint.id, native_id),
          sender_label: "bridge"
        )
        adapter.deliver(notice, endpoint)
      end

      # How a bridge notice names the person it is about on +target+: their bridged
      # nickname there when they chose one, out of the same community-scoped
      # directory a relayed copy reads, else the ordinary handle@platform label.
      def notice_label(message, target, community)
        bridged_nickname_label(message.author, message.origin, target, people_for(community)) ||
          Core::SenderLabel.for(
            author: message.author, platform: origin_platform_label(message.origin),
            protocol: origin_protocol(message.origin)
          )
      end

      # The id of the message on +endpoint_id+ that corresponds to +ref+, drawn from
      # {#related_refs} so a reaction reaches every copy a delete would.
      def related_native_id(ref, endpoint_id)
        return ref.native_id if ref.endpoint_id == endpoint_id

        related_refs(ref).find { |related| related.endpoint_id == endpoint_id }&.native_id
      end

      # Every ref the map ties to +ref+: its own copies, its original, then the
      # original's other copies. An action can arrive on any copy, and from a copy
      # the others are only reachable back through the original.
      #
      # @param sources [Array<Core::MessageRef>] the originals of +ref+, if already read
      # @return [Array<Core::MessageRef>] excluding +ref+ itself
      def related_refs(ref, sources = @storage.origins(ref))
        siblings = sources.flat_map { |source| @storage.counterparts(source) }
        (@storage.counterparts(ref) + sources + siblings).uniq - [ref]
      end

      private

      def handle_new(message, scope, community:, community_scope:)
        # This endpoint held this content the moment it arrived, whatever
        # happens to it next: recorded ahead of every early return below, so an
        # unroutable message or one this instance loses the relay claim for
        # still leaves that fact behind.
        record_fingerprint(message, message.origin.id, community)

        if message.empty?
          logger.debug { "dropped #{message.ref}, no content" }
          return []
        end

        rooms = target_rooms_for(message, community_scope)
        if rooms.empty?
          logger.debug { "dropped #{message.ref}, endpoint #{message.origin.id} is in no room" }
          return []
        end

        # Whichever instance wins this atomic claim performs the whole fan-out.
        # Claimed after the drops above, so an unroutable message takes no claim.
        lease = @relay_leases.claim(message.ref, community)
        unless lease
          logger.debug { "dropped #{message.ref}, already relayed by another instance" }
          return []
        end

        # Checked only once the claim is won, since the delete and the DM it
        # triggers are real side effects that must run on one instance only.
        refresher = @relay_leases.start_refresh(lease)
        completed = false
        begin
          if @warnings&.suppress?(message: message, community: community_scope)
            logger.debug { "dropped #{message.ref}, #{message.author&.any_name} is currently muted" }
            completed = true
            return []
          end
          # The visited set spans the fan-out so overlapping rooms share copies.
          visited = message.trace.to_set
          visited << message.origin.id
          deliveries = rooms.flat_map do |room|
            deliver_to_room(room, message, visited, scope, community_id: community, community_scope: community_scope)
          end
          acknowledge_mention_ambiguities(message, scope)
          completed = scope.nil? || Array(scope.failed_deliveries).empty?
          deliveries
        ensure
          # Successful targets remain in the native-ref map, so a later replay
          # repairs only missing destinations after a partial platform outage.
          @relay_leases.finish(lease, source: message.ref, community: community,
                                     completed: completed, claim_ttl: @claim_ttl)
          @relay_leases.stop_refresh(refresher)
        end
      end

      # Ordinarily every room +message.origin+ belongs to; when an adapter resolved a hub
      # short code, +hub_target_room_id+ names the room instead (a literal
      # {Core::Room#id} or a member endpoint id). +community+ is required and the search
      # never widens past it, since Core::Room#id is unique only within one and the
      # merged topology would fan a hub-addressed message into a stranger's same-named room.
      def target_rooms_for(message, community)
        target = message.hub_target_room_id
        return @topology.rooms_for(message.origin.id) if target.nil?

        # nil is the config path, whose rooms carry no community of their own, so
        # this narrows to exactly those and still never to another tenant's.
        pool = Core::CommunityScope.within(@topology.rooms, community&.id)
        target = target.to_s
        room = pool.find { |candidate| candidate.id == target }
        return [room] if room

        containing = pool.select { |candidate| candidate.include?(target) }
        return containing unless containing.empty?

        @topology.rooms_for(message.origin.id)
      end

      def deliver_to_room(room, message, visited, scope, community_id:, community_scope:)
        policy = POLICY_FOR_KIND[message.kind]
        if policy && !message.origin.relay?(policy)
          logger.debug { "dropped #{message.ref}, #{policy} disabled on #{message.origin.id}" }
          return []
        end

        # One row per room per message for each of these three, so a subscriber
        # sees what the room saw and not one copy per platform.
        if claim_event(message.ref, "room-notify:#{room.unique_id}", community_id)
          buffer(room, message, community_id)
          notify_webhooks(room, message, community_id)
          retain(room, message, community_id, community_scope)
        end

        room.targets_for(message.origin).filter_map do |target|
          if visited.include?(target.id)
            logger.warn { "cycle avoided: #{message.ref} already reached #{target.id}" }
            next nil
          end
          # Never relay back through a different room's endpoint on the same
          # physical channel the message arrived on.
          next nil if message.hub_exclude_endpoint_ids.include?(target.id)
          next nil if policy && !target.relay?(policy)
          # The delivery point itself: refuse an endpoint outside the community
          # this message came from, loudly, and keep the rest of the fan-out.
          next nil unless Core::CommunityScope.permit_or_log(target, community_id, logger: logger,
                                                                                   doing: "relaying #{message.ref}")

          visited << target.id
          deliver_one(room, message, target, visited, scope, community_id, community_scope)
        end
      end

      # Record one message in the live-stream buffer, or do nothing. Silent without
      # a buffer or a community: the buffer is keyed by (community_id, room_key)
      # and an unscoped row could be read back against the wrong tenant's room.
      def buffer(room, message, community_id)
        return if @live_feed.nil? || community_id.nil?

        @live_feed.record(
          community_id: community_id,
          room_key: room.id,
          origin_key: message.origin.id,
          # The author before #prepare renders a per-target label.
          author_label: buffered_author(message),
          body: message.body.text.to_s,
          kind: message.kind.to_s
        )
      end

      # Queue this message for its subscribers, or do nothing, silent on the same two
      # conditions {#buffer} is. Covers :chat, :join, :leave, and :system, the kinds
      # {#deliver_to_room} is ever called for; :edit, :delete, and the reaction kinds have
      # their own webhook call sites below since they never reach {#deliver_to_room}.
      def notify_webhooks(room, message, community_id)
        return if @webhooks.nil? || community_id.nil?

        @webhooks.emit(
          community_id: community_id,
          event_type: relayed_event_type(message.kind),
          room_key: room.id,
          data: {
            "room_key" => room.id,
            "origin_key" => message.origin.id,
            "author" => buffered_author(message),
            "kind" => message.kind.to_s,
            # The message text, capped. This is the disclosure PRIVACY.md states:
            # with a subscription in place, room text leaves the deployment.
            "body" => message.body.text.to_s[0, ControlPlane::Webhooks::MAX_TEXT]
          }
        )
      end

      # The event type a message's own kind is announced under. :join and :leave get
      # their own membership event; everything else this reaches (:chat, :system) is
      # still reported as an ordinary relayed message, since only membership needs to
      # be told apart from content here.
      def relayed_event_type(kind)
        case kind
        when :join then ControlPlane::Webhooks::MEMBER_JOINED
        when :leave then ControlPlane::Webhooks::MEMBER_LEFT
        else ControlPlane::Webhooks::MESSAGE_RELAYED
        end
      end

      # Queue an edit, a delete, a reaction add or a reaction remove for this
      # community's webhook subscribers, once per room the ORIGIN belongs to.
      # Silent on the same two conditions {#notify_webhooks} is.
      def notify_webhooks_change(message, community_id, event_type, data: {})
        return if @webhooks.nil? || community_id.nil?

        @topology.rooms_for(message.origin.id).each do |room|
          @webhooks.emit(
            community_id: community_id, event_type: event_type, room_key: room.id,
            data: { "room_key" => room.id, "origin_key" => message.origin.id,
                    "author" => buffered_author(message) }.merge(data)
          )
        end
      end

      def buffered_author(message)
        label = message.sender_label
        return label.to_s if label

        message.author&.any_name.to_s
      end

      # Keep one message so a later redirect has something to repost; silent without
      # the store, without a community, or for a room that has not switched
      # redirection on. Only :chat, since a redirect never uses a join line.
      def retain(room, message, community_id, community)
        return if @redirection_window.nil? || community_id.nil? || community.nil?
        return unless message.kind == :chat
        return if message.ref&.native_id.nil?
        return unless redirection_retained?(community, room)

        @redirection_window.record(
          community_id: community_id, room_key: room.id,
          endpoint_id: message.origin.id, native_id: message.ref.native_id,
          body: message.body, attachments: message.attachments,
          author_id: message.author&.native_id,
          author_handle: message.author&.username,
          author_name: message.author&.profile_name
        )
      end

      # Asked through one of the room's own endpoints, since that is what
      # Snapshot::Community#feature_enabled? resolves a room row from. Unknown
      # reads as off, because guessing wrong retains text nobody asked us to keep.
      def redirection_retained?(community, room)
        return false unless community.respond_to?(:feature_enabled?) && community.respond_to?(:room_key_of)

        key = room.endpoints.map(&:id).find { |id| community.room_key_of(id) == room.id }
        return false if key.nil?

        community.feature_enabled?(key, Features::Redirection.feature_name)
      rescue StandardError
        false
      end

      # Deal with the files this target cannot take: the ceiling comes from the
      # adapter's own Capabilities#max_attachment_bytes, and the community's
      # file_rehosting strategy decides between shrinking the file to fit and storing
      # it whole behind a link. Asked per target rather than per message, since the
      # same file can pass on one platform and fail on another; never raises.
      def rehost_oversized(room, message, target, scope)
        rehosting = scope&.rehosting
        return message if rehosting.nil? || message.attachments.empty?

        ceiling = attachment_ceiling(target)
        return message unless message.attachments.any? { |file| needs_rehost?(file, ceiling) }
        return message unless rehosting_enabled?(rehosting.community, room)

        apply_placements(room, message, target, scope, rehosting, ceiling)
      end

      # A file that cannot cross to this target as it arrived: either it is over
      # the target's own byte ceiling, or its source URL carries a credential (a
      # Telegram file URL embeds the bot token) that must never reach a third
      # party. The credential half needs no ceiling, so it still applies to a
      # target, such as Matrix, IRC or XMPP, that declares none.
      def needs_rehost?(file, ceiling)
        Util::SafeUrl.credentialed?(file.url) || oversized?(file, ceiling)
      end

      # A file over the target's own byte ceiling, distinct from one that only
      # needs rehosting to strip a credential: the two call for different
      # answers below.
      def oversized?(file, ceiling)
        ceiling && file.size.to_i > ceiling
      end

      # Whether relaying +file+ to +target+ AS ITSELF would ask the target to
      # fetch it over a URL past its own reach for that. Telegram's outbound
      # never uploads bytes for a relayed attachment, it only ever hands the
      # Bot API a URL (see Telegram::Outbound#media_call), and that URL fetch
      # is capped tighter than a genuine upload; a platform that draws no such
      # distinction (Capabilities#url_relay_ceiling answers nil) never trips
      # this.
      def exceeds_url_relay_ceiling?(file, target)
        ceiling = url_relay_ceiling(target, file.kind)
        ceiling && file.size.to_i > ceiling
      end

      def url_relay_ceiling(target, kind)
        adapter = @adapters[[target.adapter_name, target.account]]
        return nil if adapter.nil?

        adapter.capabilities_for(target).url_relay_ceiling(kind)
      rescue StandardError
        nil
      end

      # Ask the rehoster about every oversized or credentialed file and rebuild
      # the message from the answers, in the order the files arrived in. A
      # shrunk or verbatim-relayed file replaces the original in place; a
      # linked one leaves the list, since the line in the body is standing in
      # for it.
      def apply_placements(room, message, target, scope, rehosting, ceiling)
        config = rehost_config(rehosting.community, room)
        retention = Features::FileRehosting.retention_days(config)
        notices = []

        attachments = message.attachments.filter_map do |file|
          next file unless needs_rehost?(file, ceiling)

          # A file only over here for its credential, not its size, already
          # fits the target: hand it across untouched rather than applying
          # the community's rehost policy, unless the target's own URL
          # relay reach is tighter (see #exceeds_url_relay_ceiling?).
          verbatim = Util::SafeUrl.credentialed?(file.url) && !oversized?(file, ceiling) &&
                     !exceeds_url_relay_ceiling?(file, target)

          placement = @rehoster.place(
            attachment: file, community_id: rehosting.community_id, room_key: room.id,
            ceiling: ceiling, strategy: Features::FileRehosting.strategy(config),
            retention_days: retention, max_bytes: Features::FileRehosting.max_bytes(config),
            created_by: rehost_author(message), memo: scope.rehosted, verbatim: verbatim
          )
          next placement.attachment if placement&.shrunk? || placement&.relayed?

          notice = notice_for(file, placement, message, target)
          remember_pending_video(scope, target, placement, notice)
          next file if notice.nil?

          notices << notice
          nil
        end
        return message if notices.empty? && attachments == message.attachments
        # A shrink says nothing: the picture crossed as a picture, so appending
        # an empty line would be a blank line nobody typed.
        return message.with(attachments: attachments) if notices.empty?

        message.with(attachments: attachments, body: append_lines(message.body, notices))
      end

      # The line that stands in for a file, or nil when the file is staying put
      # and nothing needs saying.
      def notice_for(file, placement, message, target)
        if placement&.linked?
          @rehoster.notice(url: placement.url)
        else
          unfetchable_notice(file, message, target)
        end
      end

      # A linked video {AttachmentRehoster} could still shrink in the
      # background, remembered against this target so {#schedule_pending_video}
      # can ask for the follow up once delivery has actually happened and there
      # is a real ref to improve on. Stored as plain text: the durable
      # scheduler payload this ends up in is JSON, and the plain text is all
      # {VideoRehostRelay#without_notice_line} ever compares against anyway.
      def remember_pending_video(scope, target, placement, notice)
        return if placement.nil? || placement.video.nil? || notice.nil?

        (scope.pending_video[target.id] ||= []) << placement.video.merge(notice_line: notice.to_s)
      end

      # A file the origin platform will not hand a bot never had bytes to work
      # with, so the sender is told that rather than left to wonder. Telegram's
      # getFile is the case this exists for: it stops at 20 MB while the same
      # bot may upload 50, so a big Telegram video cannot be shrunk or rehosted.
      def unfetchable_notice(file, message, target)
        return nil if file.resolvable?

        ceiling = fetch_ceiling(message.origin)
        return nil if ceiling.nil? || file.size.to_i <= ceiling

        @rehoster.unfetchable_notice(
          attachment: file, target_label: target_label(target),
          origin_label: target_label(message.origin), ceiling: ceiling
        )
      end

      # What this target will accept, or nil for a platform that declares no
      # ceiling. Nil means "do not second-guess it", never "unlimited".
      def attachment_ceiling(target)
        adapter = @adapters[[target.adapter_name, target.account]]
        return nil if adapter.nil?

        limit = adapter.capabilities_for(target).max_attachment_bytes
        limit&.positive? ? limit : nil
      rescue StandardError
        nil
      end

      # The largest file we can pull back OFF the platform a message came from.
      # Nil where the platform sets no such limit, which is most of them.
      def fetch_ceiling(origin)
        adapter = @adapters[[origin.adapter_name, origin.account]]
        return nil if adapter.nil?

        limit = adapter.capabilities_for(origin).max_fetch_bytes
        limit&.positive? ? limit : nil
      rescue StandardError
        nil
      end

      # Asked the same way {#redirection_retained?} asks its own question, and
      # failing to off for the same reason. Also checks the dashboard's own
      # File Rehosting toggle (rehost_inbound), independent of File Uploads'.
      def rehosting_enabled?(community, room)
        key = rehost_room_key(community, room)
        return false if key.nil?
        return false unless community.feature_enabled?(key, Features::FileRehosting.feature_name)

        Features::FileRehosting.rehost_inbound?(rehost_config(community, room))
      rescue StandardError
        false
      end

      def rehost_config(community, room)
        key = rehost_room_key(community, room)
        return {} if key.nil?

        community.feature_config(key, Features::FileRehosting.feature_name) || {}
      rescue StandardError
        {}
      end

      def rehost_room_key(community, room)
        return nil unless community.respond_to?(:feature_enabled?) && community.respond_to?(:room_key_of)

        room.endpoints.map(&:id).find { |id| community.room_key_of(id) == room.id }
      end

      # A provenance label for the stored row. Never used to authorise anything,
      # so an unresolvable author degrades to the platform name.
      def rehost_author(message)
        author = message.author
        handle = author&.username.to_s
        handle = author&.native_id.to_s if handle.empty?
        "#{message.origin.adapter_name}:#{handle}"
      end

      def monotonic_since(started) = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      def target_label(target)
        label = target.label.to_s
        label.empty? ? target.adapter_name.to_s : label
      end

      # Each notice on its own line after the body, so a captioned message keeps
      # its caption. A notice may carry its own formatting, an italicised
      # aside rather than a plain sentence, so each one joins as rich text
      # rather than being flattened to a string first.
      def append_lines(body, lines)
        joined = lines.map { |line| line.is_a?(Core::RichText) ? line : Core::RichText.plain(line.to_s) }
                      .reduce { |left, right| left.concat(Core::RichText.plain("\n")).concat(right) }
        return joined if body.nil? || body.blank?

        body.concat(Core::RichText.plain("\n")).concat(joined)
      end

      def deliver_one(room, message, target, visited = nil, scope = nil, community_id = nil, community_scope = nil)
        adapter = adapter_for(target)
        if already_delivered?(message, target)
          logger.debug { "dropped #{message.ref} for #{target.id}, its native source already has a copy" }
          return nil
        end
        if adapter.nil? || breaker_open?(target, message)
          scope&.failed_deliveries&.push(target.id)
          return nil
        end

        outbound = prepare(room, message, target, visited, scope: scope, community_scope: community_scope)
        # Timed across every attempt, since what this room's worker spent on
        # the target is the whole retried delivery rather than one try of it.
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # Retrying here holds up this room only, since each room has its own worker.
        receipt = @retry.call("delivery of #{message.ref} to #{target.id}") do
          paced(adapter, target) { adapter.deliver(outbound, target) }
        rescue RateLimitedError => e
          # Said on the FIRST refusal, before the retry waits it out, so a sweep feeding this room slows now.
          @relay_outcomes&.rate_limited(target.id, e.retry_after)
          raise
        end
        return nil if receipt.equal?(Core::DeliveryReceipt::NOT_APPLICABLE)

        if receipt.nil?
          scope&.failed_deliveries&.push(target.id)
          # An adapter that was attempted and came back with nothing to point
          # an edit or delete at: distinct from NOT_APPLICABLE above, this copy
          # is not on the target and nothing else will notice.
          @relay_outcomes&.abandoned(message.ref, target.id, "delivery produced no receipt")
          logger.error { "delivery to #{target.id} produced no receipt" }
          return nil
        end

        @endpoint_health&.delivered(target.id, seconds: monotonic_since(started))
        @relay_outcomes&.delivered(message.ref, target.id)
        @loop_guard.note_delivery(target.id, receipt.native_id)
        record(message, receipt, room, community_scope)
        # The SOURCE message, not +outbound+: a copy carries an author prefix
        # and may have rewritten mentions or a translation, so only the
        # original's own content corresponds to what a native arrival on
        # +target+ would have fingerprinted.
        record_fingerprint(message, target.id, community_id)
        report_notes(message, receipt)
        schedule_pending_video(scope, target, message, outbound, receipt)
        logger.info do
          "relayed #{message.ref} to #{receipt.ref} " \
            "(room=#{room.id} corr=#{message.correlation_id})"
        end
        receipt
      rescue AdapterError => e
        scope&.failed_deliveries&.push(target.id)
        # Every attempt is spent by now, so a paced relay has to drop this copy from its count.
        # `started` is nil when prepare itself raised, so the timing is dropped
        # rather than turning a handled failure into a TypeError in here.
        @endpoint_health&.failed(target.id, error: e, seconds: started && monotonic_since(started))
        @relay_outcomes&.abandoned(message.ref, target.id, e.message)
        logger.error { "delivery to #{target.id} failed: #{e.message}" }
        nil
      end

      def already_delivered?(message, target)
        !@storage.counterparts(message.ref, endpoint_id: target.id).empty?
      rescue StorageError => e
        logger.warn { "could not read delivery progress for #{message.ref}: #{e.message}" }
        false
      end

      # Ask {AttachmentRehoster} to follow up on a video it could only link,
      # now that delivery has actually happened and there is a real ref to
      # improve on. Silent with nothing pending for this target, which is
      # every ordinary delivery.
      def schedule_pending_video(scope, target, message, outbound, receipt)
        pending = scope&.pending_video&.delete(target.id)
        return if pending.nil?

        pending.each do |video|
          @rehoster.schedule_video_followup(
            video, source_ref: message.ref, target_endpoint_id: target.id,
            notice_native_id: receipt.native_id, body_text: outbound.body.text.to_s
          )
        end
      end

      # Adapt the canonical message for one target: resolve the reply pointer into
      # that endpoint's id space and attach the sender label it should show.
      def prepare(room, message, target, visited = nil, scope: nil, community_scope: nil)
        naming = Core::DisplayName.resolve(
          endpoint: message.origin, room: room, default: display_name_default(community_scope)
        )
        # Files this target will not take are replaced by a link here first, so
        # everything below sees the message as this target receives it.
        message = rehost_oversized(room, message, target, scope)
        # Resolved once for every reader below, so everything that names a person on
        # this copy answers out of the same community's directory.
        people = people_for(community_scope)
        body = render_mentions(message.body, target, message.origin, scope, people, community_scope)
        message.with(
          body: expand_timestamps(body, target, scope&.timestamp_zones),
          reply_preview: prepare_reply_preview(message, target, naming, people),
          thread_notice: thread_notice_for(message, target, scope, people),
          # The trace travels with the copy so an adapter that re-enters the bridge
          # carries the history forward instead of starting a fresh fan-out.
          trace: (visited || (message.trace + [target.id])).to_a,
          reply_to: translate_reply(message, target),
          sender_label: fixed_sender_label(message) ||
                        bridged_nickname_label(message.author, message.origin, target, people) ||
                        sender_label_for(message.author, message.origin, naming)
        )
      end

      # A guest send and an API post carry their own fixed-domain sender label,
      # preserved so a display-name template cannot override it. Nil otherwise.
      def fixed_sender_label(message)
        label = message.sender_label
        label if label.is_a?(Core::SenderLabel) && (label.guest? || label.api?)
      end

      # The thread degradation line for this target, or nil: an ordinary message typed
      # into a thread loses just as much context as a threaded reply does, so both get
      # the line. Name and starter come from the {Core::ThreadRef} the origin adapter
      # built; a platform that says neither reads "a thread".
      def thread_notice_for(message, target, scope, people)
        return nil unless scope&.thread_notices
        return nil unless message.in_thread?
        return nil if target_threads?(target)

        thread = message.thread
        name = thread.name
        creator = thread_creator_handle(thread, message.origin, target, people)
        return %[(Reply inside thread "#{name}" created by #{creator}.)] if name && creator

        name ? %(replied inside the thread "#{name}") : "replied inside a thread"
      end

      # Whoever started the thread, tagged with the origin platform the way every
      # other label on a relayed copy is, so it reads "owner_handle@discord", with
      # their bridged nickname on +target+ leading where they chose one. Nil on a
      # platform that never says who started a thread.
      def thread_creator_handle(thread, origin, target, people)
        if thread.creator_native_id
          starter = Core::Author.new(native_id: thread.creator_native_id, username: thread.creator)
          nickname = bridged_nickname_label(starter, origin, target, people)
          return nickname.to_s if nickname
        end
        return nil if thread.creator.nil?

        Core::SenderLabel.new(
          username: thread.creator,
          platform: origin_platform_label(origin),
          protocol: origin_protocol(origin)
        ).to_s
      end

      # Asked per endpoint, since Telegram threads only in forum topics. Unknown
      # counts as "cannot", so the thread context degrades instead of vanishing.
      def target_threads?(target)
        adapter = adapter_for(target)
        return false if adapter.nil?

        adapter.capabilities_for(target).threads?
      rescue StandardError
        false
      end

      # The name this author asked to be bridged as on the target platform, still
      # tagged with the origin so the reader can tell where they are speaking
      # from. Nil when they are not a known person or set nothing for this target.
      def bridged_nickname_label(author, origin, target, directory)
        return nil if author.nil? || directory.nil? || directory.empty?

        person = directory.by_identity(origin.adapter_name, author.native_id)
        nickname = person&.nickname_on(target.adapter_name)
        if nickname.nil?
          log_nickname_miss(person, author, origin, target)
          return nil
        end

        Core::SenderLabel.nickname(
          nickname: nickname,
          username: author.username,
          platform: origin_platform_label(origin),
          protocol: origin_protocol(origin)
        )
      end

      # The people this message may resolve against: its own community's, never the
      # deployment-wide union, since a person is unique only within a community and a
      # wider lookup could point a mention or nickname at another community's row for
      # the same platform account. Falls back to the deployment-wide directory only when
      # no community was resolved (no control plane).
      def people_for(community_scope)
        return @people unless @people.respond_to?(:for_community)

        @people.for_community(community_scope)
      end

      # The global fallback {Core::DisplayName.resolve} falls back to once a
      # room or endpoint names no template of its own: the issuing community's
      # own display_name block, seeded verbatim from static config at creation
      # time, wins field by field over the deployment-wide default. Nothing to
      # read an override from wherever community_scope carries no settings of
      # its own (no control plane, or a bare id rather than a Snapshot object).
      def display_name_default(community_scope)
        Core::DisplayName.new(
          template: display_name_setting(community_scope, "format", @default_display_name.template),
          fallback: display_name_setting(community_scope, "fallback_format", @default_display_name.fallback)
        )
      end

      def display_name_setting(community_scope, key, default)
        return default unless community_scope.respond_to?(:settings)

        value = community_scope.settings.dig("display_name", key)
        value.nil? ? default : value
      end

      # Why a nickname was not applied, since a miss otherwise looks exactly like
      # having chosen none. Debug, because this runs on every relayed message.
      def log_nickname_miss(person, author, origin, target)
        logger.debug do
          if person.nil?
            "no bridged nickname: #{origin.adapter_name} #{author.native_id} matches no person"
          else
            held = person.nicknames.keys.join(", ")
            "no bridged nickname: #{person.name} holds none on #{target.adapter_name} " \
              "(held: #{held.empty? ? 'none' : held})"
          end
        end
      end

      # An override template renders to a plain string; with none, the structured
      # label is tagged with the origin platform's identifier, so a Discord user
      # reads as "<b>handle</b>@discord" on Telegram.
      def sender_label_for(author, origin, naming)
        return naming.render(author) if naming.configured?

        Core::SenderLabel.for(
          author: author,
          platform: origin_platform_label(origin),
          protocol: origin_protocol(origin)
        )
      end

      # Asked of the origin adapter, so a federated platform such as Matrix can
      # return its homeserver. Falls back to the endpoint's own adapter name.
      def origin_platform_label(origin)
        adapter = @adapters[[origin.adapter_name, origin.account]]
        label = adapter.origin_label(origin) if adapter.respond_to?(:origin_label)
        label || origin.adapter_name.to_s
      rescue StandardError
        origin.adapter_name.to_s
      end

      # The federated protocol qualifier, asked like {#origin_platform_label}. nil
      # for a centralized platform, which Core::SenderLabel reads as no qualifier.
      def origin_protocol(origin)
        adapter = @adapters[[origin.adapter_name, origin.account]]
        return nil unless adapter.respond_to?(:origin_protocol)

        adapter.origin_protocol(origin)
      rescue StandardError
        nil
      end

      # Translate a reply pointer from the origin's id space into the target's. An
      # unrelayed parent returns the original pointer unchanged, which keeps "not
      # a reply" (nil) distinct from "a reply we cannot express natively here".
      def translate_reply(message, target)
        return nil if message.reply_to.nil?

        mapped = @storage.counterparts(message.reply_to, endpoint_id: target.id).first
        return mapped if mapped

        # The parent may have originated on the target endpoint, mapped the other way.
        @storage.origins(message.reply_to).find { |ref| ref.endpoint_id == target.id } || message.reply_to
      end

      # Trim the quoted parent to the configured budget, so every target shows the
      # same quote. reply_preview_chars of 0 disables quoting entirely.
      def prepare_reply_preview(message, target, naming, people)
        preview = message.reply_preview
        return nil if preview.nil?
        return nil if @reply_preview_chars.to_i <= 0

        body = preview.body.first_lines(@reply_preview_lines).truncate(@reply_preview_chars)
        preview.with_body(body).with_label(quoted_label(preview, message.origin, target, naming, people))
      end

      # The quoted author's bridged nickname on +target+ as plain text, else their
      # rendered name. A reply and its parent share one chat, so the author is
      # looked up as an account on the reply's own origin platform.
      def quoted_label(preview, origin, target, naming, people)
        author = preview.author
        return preview.label if author.nil?

        bridged_nickname_label(author, origin, target, people)&.to_s || naming.render(author)
      end

      # Annotate mention spans with the target's id for the mentioned person, so a handle
      # typed on Telegram can ping on Discord; a mention nobody in the directory matches
      # is left alone. +people+ must be the message's own community's directory, since a
      # wider lookup could ping the wrong person and leak that the handle exists
      # elsewhere; the span's text is rewritten to the target's own format only where
      # the platform's native mention token doesn't already replace it live (see
      # {NATIVE_MENTION_TEXT_PLATFORMS}).
      def resolve_mentions(body, target, people)
        return body if people.nil? || people.empty?

        mentions = body.spans.select { |span| span.kind == :mention }
        return body if mentions.empty?

        key = :"#{target.adapter_name}_id_for_target"
        tagged_ids = {}
        edits = []
        mentions.each do |span|
          person = people.resolve_mention(span.attributes)
          id = person&.id_on(target.adapter_name)
          next if id.nil?

          tagged_ids[span] = id
          label = person_mention_label(target, person)
          edits << [(span.begin_index...span.end_index), label, id] if label
        end
        return body if tagged_ids.empty?

        tagged = body.spans.map do |span|
          next span unless tagged_ids.key?(span)

          Core::Span.new(
            kind: span.kind, begin_index: span.begin_index, end_index: span.end_index,
            attributes: span.attributes.merge(key => tagged_ids[span].to_s)
          )
        end
        splice_mention_labels(Core::RichText.new(body.text, tagged), edits, key)
      end

      # Both kinds of mention: the native spans an author typed and, when enabled,
      # directory-backed tags. Both feed the same renderer and whitelist.
      def render_mentions(body, target, origin, scope, people, community_scope)
        body = resolve_mentions(body, target, people)
        mentions = scope&.mentions
        return body if mentions.nil?
        return body unless target_accepts_cross_platform_mentions?(target, community_scope)

        resolve_cross_platform_mentions(body, target, origin, mentions, scope)
      end

      # The label a resolved mention should read as on +target+, or nil for a
      # platform (see {NATIVE_MENTION_TEXT_PLATFORMS}) whose own mention token
      # already replaces its display text client side, and so is never rewritten
      # here, or for a person with nothing at all to build a label out of.
      def build_mention_label(target, nickname:, username:, display_name:, name:)
        return nil if NATIVE_MENTION_TEXT_PLATFORMS.include?(target.adapter_name)

        label = Core::SenderLabel.new(
          username: username, display_name: nickname || display_name,
          platform: target.adapter_name.to_s, name: name || nickname || username || display_name
        )
        label.empty? ? nil : label.to_s
      end

      # The label for a mention resolved through the configured people directory:
      # a bridged nickname on the target platform, else that platform's own
      # configured handle, else the person's log name.
      def person_mention_label(target, person)
        build_mention_label(
          target,
          nickname: person.nickname_on(target.adapter_name),
          username: person.handles[target.adapter_name.to_sym]&.first,
          display_name: nil,
          name: person.name
        )
      end

      # The label for a mention resolved through the passively learned identity
      # directory: a bridged nickname on the target platform, else the observed
      # display name there, else the observed handle.
      def directory_mention_label(target, id, mentions)
        nickname = mentions.directory.nickname_for(
          community_id: mentions.community_id, adapter: target.adapter_name, native_id: id
        )
        entry = mentions.directory.entry(
          community_id: mentions.community_id, adapter: target.adapter_name, native_id: id
        )
        build_mention_label(
          target, nickname: nickname, username: entry&.username, display_name: entry&.display_name, name: nil
        )
      rescue StandardError => e
        logger.warn { "cross-platform mention label lookup failed on #{target.adapter_name} for id #{id}: #{e.message}" }
        nil
      end

      # Splice each resolved mention's label text into +body+, keeping a fresh
      # :mention span (tagged with the target's id) over the new text.
      # RichText#splice drops any span lying inside an edited range, which would
      # otherwise erase the very tag {#resolve_mentions} and
      # {#resolve_cross_platform_mentions} just added.
      #
      # @param edits [Array<Array(Range, String, String)>] (original range,
      #   label text, target native id), ranges disjoint
      def splice_mention_labels(body, edits, key)
        return body if edits.empty?

        ordered = edits.sort_by { |(range, *)| range.first }
        shift = 0
        new_spans = ordered.map do |(range, label, id)|
          begin_index = range.first + shift
          shift += label.length - range.size
          Core::Span.new(
            kind: :mention, begin_index: begin_index, end_index: begin_index + label.length,
            attributes: { key => id.to_s }
          )
        end
        spliced = body.splice(ordered.map { |(range, label, _id)| [range, label] })
        Core::RichText.new(spliced.text, spliced.spans + new_spans)
      end

      # Rewrite every Discord `<t:UNIX:FORMAT>` token in +body+ into readable,
      # multi-timezone plain text (see {Features::TimestampExpansion}); a Discord
      # target keeps the native markup untouched, since only Discord's own client
      # resolves it live, per viewer. Empty +zones+, which is a scope that set
      # {TIMESTAMP_TIMEZONES_KEY} to an empty list, is a no-op.
      def expand_timestamps(body, target, zones)
        return body if target.adapter_name == :discord
        return body if zones.nil? || zones.empty?
        return body if body.nil? || !body.text.include?("<t:")

        edits = []
        body.text.scan(Features::TimestampExpansion::TOKEN) do
          match = Regexp.last_match
          replacement = Features::TimestampExpansion.render_token(match[1], zones)
          edits << [(match.begin(0)...match.end(0)), replacement] unless replacement.nil?
        end
        return body if edits.empty?

        body.splice(edits)
      end

      # Rewrites tokens addressed to this target's platform into native pings; an
      # unknown or ambiguous handle stays the plain text the author typed. Off the
      # {NATIVE_MENTION_TEXT_PLATFORMS} list, a resolved token's visible text is
      # rewritten too, matching what {#resolve_mentions} does for a native span.
      #
      # SAFETY: only ever adds spans for an id {IdentityDirectory#resolve_unique_fragment}
      # returned, never one read out of the token, so a spoofed `@everyone@discord`
      # cannot inject a ping.
      def resolve_cross_platform_mentions(body, target, origin, mentions, scope)
        platform = target.adapter_name.to_s
        domain = origin_platform_label(target)
        key = :"#{target.adapter_name}_id_for_target"

        added = []
        edits = []
        scan_cross_platform_mentions(body.text) do |handle, token_platform, from, to|
          next unless token_platform.casecmp?(platform) || token_platform.casecmp?(domain)

          resolve_cross_platform_mention(
            handle, token_platform, from, to, target, mentions, key, added, edits, scope
          )
        end
        scan_bare_cross_platform_mentions(body.text) do |handle, from, to|
          next unless target.adapter_name != origin.adapter_name

          resolve_cross_platform_mention(handle, nil, from, to, target, mentions, key, added, edits, scope)
        end
        return body if added.empty? && edits.empty?

        base = added.empty? ? body : Core::RichText.new(body.text, body.spans + added)
        splice_mention_labels(base, edits, key)
      end

      def resolve_cross_platform_mention(handle, token_platform, from, to, target, mentions, key, added, edits, scope)
        resolution = mentions.directory.resolve_unique_fragment(
          community_id: mentions.community_id, adapter: target.adapter_name, handle: handle
        )
        id = resolution.native_id
        if id.nil?
          if resolution.matches.empty?
            log_cross_platform_mention_miss(handle, token_platform, target) unless token_platform.nil?
          else
            scope&.mention_ambiguities&.concat(
              [PartialMentionAmbiguity.new(handle: handle, adapter: target.adapter_name, matches: resolution.matches)]
            )
          end
          return
        end

        label = directory_mention_label(target, id, mentions)
        if label
          edits << [(from...to), label, id]
        else
          added << Core::Span.new(
            kind: :mention, begin_index: from, end_index: to, attributes: { key => id.to_s }
          )
        end
      end

      # Why a typed @handle@platform token did not resolve, since a miss
      # otherwise looks identical to the token never having been scanned at
      # all. Debug, since an unknown, ambiguous, or not-yet-observed handle is
      # ordinary traffic rather than a fault, given this rewards passive
      # learning rather than treating an unmatched handle as an error.
      def log_cross_platform_mention_miss(handle, token_platform, target)
        logger.debug do
          "cross-platform mention miss: @#{handle}@#{token_platform} resolves to nobody on " \
            "#{target.adapter_name} (unknown handle, ambiguous, or not yet observed there)"
        end
      end

      # Yield each `@handle@platform` token with its handle, platform and half-open
      # character range, so offsets line up with {Core::Span}.
      def scan_cross_platform_mentions(text)
        position = 0
        while (match = CROSS_PLATFORM_MENTION.match(text, position))
          position = match.end(0)
          yield match[1], match[2], match.begin(0), match.end(0)
        end
      end

      # Yield each bare `@handle` token. The token may only resolve on a foreign
      # target platform, which keeps one-platform communities on their native
      # mention behaviour.
      def scan_bare_cross_platform_mentions(text)
        position = 0
        while (match = BARE_CROSS_PLATFORM_MENTION.match(text, position))
          position = match.end(0)
          yield match[1], match.begin(0), match.end(0)
        end
      end

      # A fragment that names several foreign accounts needs a reply, since the
      # forwarded copy otherwise looks the same as an ordinary unknown tag.
      # One reply per distinct fragment keeps a fan-out from repeating itself.
      def acknowledge_mention_ambiguities(message, scope)
        return if @ephemeral.nil? || scope.nil? || scope.mention_ambiguities.empty?

        scope.mention_ambiguities.uniq { |item| [item.handle.downcase, item.adapter.to_s] }.each do |ambiguity|
          group = @ephemeral.post(
            endpoints: [message.origin], body: Core::RichText.plain(partial_mention_ambiguity_message(ambiguity)),
            name: CROSS_PLATFORM_MENTION_NOTICE_NAME, delete_after: CROSS_PLATFORM_MENTION_NOTICE_TTL,
            reply_to: message.ref
          )
          @cleanup&.after(CROSS_PLATFORM_MENTION_NOTICE_TTL) { group.delete_now } if group.any?
        end
      rescue StandardError => e
        logger.warn { "cross-platform mention acknowledgement failed: #{e.message}" }
      end

      # The candidate handles the author can actually type back: ones the
      # mention scanners still see as a token, and ones that reach a single
      # account, so nothing offered here resolves to the same standstill.
      def selectable_ambiguity_handles(ambiguity)
        ambiguity.matches
                 .group_by { |match| match.username.to_s }
                 .select { |handle, rows| handle.match?(SELECTABLE_HANDLE) && rows.map(&:native_id).uniq.size == 1 }
                 .keys
      end

      def partial_mention_ambiguity_message(ambiguity)
        accounts = ambiguity.matches.map(&:native_id).uniq.size
        opening = "@#{ambiguity.handle} matches #{accounts} #{ambiguity.adapter} accounts"
        handles = selectable_ambiguity_handles(ambiguity)
        if handles.size < 2
          return "#{opening} and no tag tells them apart, so I left it as the text you typed."
        end

        tags = handles.map { |handle| "@#{handle}@#{ambiguity.adapter}" }.join(", ")
        # No closing full stop: it would fuse onto the last tag, which reads the
        # dot as part of the platform.
        "#{opening}. Tag one of these exactly to reach it: #{tags}"
      end

      # The cross-platform mention scope for this message, or nil, which disables
      # the rewrite structurally: no identity directory to resolve against, or no
      # community to scope the lookup to. Whether a given TARGET actually accepts a
      # resolved mention is a separate, PER-TARGET decision made in
      # {#target_accepts_cross_platform_mentions?} against that target's own config,
      # not checked here since the origin room's {CROSS_PLATFORM_MENTIONS_KEY} only
      # ever governs itself.
      def mention_scope(context)
        return nil if @identity_directory.nil?

        community_id = context.community&.id
        return nil if community_id.nil?

        MentionScope.new(directory: @identity_directory, community_id: community_id)
      end

      # Whether TARGET's own resolved bridge config accepts a cross-platform
      # mention resolving into a native ping here (see {#mention_scope}). A
      # community without per-room feature config to ask (no control plane, or a
      # hand-built scope in a spec) fails open, the same "changes nothing until
      # asked" default {#cross_platform_mentions_enabled?} applies everywhere
      # else.
      def target_accepts_cross_platform_mentions?(target, community_scope)
        return true unless community_scope.respond_to?(:feature_config)

        config = community_scope.feature_config(target.id, self.class.feature_name)
        cross_platform_mentions_enabled?(config)
      rescue StandardError => e
        logger.warn { "cross-platform mentions: could not read #{target.id}'s config, resolving anyway: #{e.message}" }
        true
      end

      # The per-scope relay decisions for this message, resolved once.
      def relay_scope(context)
        RelayScope.new(
          mentions: mention_scope(context),
          thread_notices: thread_reply_notices_enabled?(context.config),
          rehosting: rehost_scope(context),
          rehosted: {},
          pending_video: {},
          timestamp_zones: timestamp_zones_for(context.config),
          mention_ambiguities: [], failed_deliveries: []
        )
      end

      # The file-rehosting scope for one message, or nil when there is no rehoster
      # or no community. Nil makes {#rehost_oversized} a no-op.
      def rehost_scope(context)
        return nil if @rehoster.nil? || context.community.nil?

        RehostScope.new(community_id: context.community.id, community: context.community)
      end

      # Defaults on, matching config_schema; a community or room row overrides it.
      def cross_platform_mentions_enabled?(config)
        boolean_config(config, CROSS_PLATFORM_MENTIONS_KEY, default: true)
      end

      def thread_reply_notices_enabled?(config)
        boolean_config(config, THREAD_REPLY_NOTICES_KEY, default: false)
      end

      def edit_notices_enabled?(config)
        boolean_config(config, EDIT_NOTICES_KEY, default: false)
      end

      def delete_notices_enabled?(config)
        boolean_config(config, DELETE_NOTICES_KEY, default: false)
      end

      # The community's {label, iana_timezone} pairs (see
      # {TIMESTAMP_TIMEZONES_KEY}), parsed once per message so #prepare does
      # the same work for every target it fans out to rather than reparsing
      # per delivery. A scope that never set the key gets
      # {TimestampExpansion::DEFAULT_ZONES}; an explicitly empty list makes
      # {#expand_timestamps} a no-op.
      def timestamp_zones_for(config)
        Features::TimestampExpansion.zones_for_config(config, TIMESTAMP_TIMEZONES_KEY, logger: logger)
      end

      # Reads {REACTION_NOTICES_KEY}, tolerating a string the way {#boolean_config}
      # tolerates one. Anything absent or unrecognised reads as native, the same
      # "changes nothing until asked" default the schema declares.
      def reaction_notices_mode(config)
        value = config_value(config, REACTION_NOTICES_KEY)
        candidate = value.nil? ? nil : value.to_s.strip.downcase.to_sym
        REACTION_NOTICE_MODES.include?(candidate) ? candidate : :both
      end

      # Read a boolean per-scope setting, tolerating the string forms an operator
      # or a YAML file may hand us. +default+ applies only to an absent key.
      def boolean_config(config, key, default: false)
        value = config_value(config, key)
        return default if value.nil?
        return value if value == true || value == false

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def handle_edit(message, scope = nil, community: nil, community_scope: nil, edit_notices: false)
        targets = @storage.counterparts(message.ref)
        if targets.empty?
          logger.debug { "edit for #{message.ref} has no mapping, ignored" }
          return []
        end

        # The body digest is part of the claim key, so each distinct edit wins its
        # own claim and propagates while the same edit arriving twice no-ops.
        digest = edit_digest(message)
        unless claim_event(message.ref, edit_operation(digest), community)
          logger.debug { "dropped a duplicate edit of #{message.ref}" }
          return []
        end
        # The PREVIOUS edit's own claim is released now that this one has won: a
        # later revert back to that earlier text must claim cleanly rather than
        # find a 7 day old claim still sitting on its digest.
        release_previous_edit_claim(message.ref, digest, community)

        # Checked only once the claim is won, same as a fresh message: an author
        # muted after posting cannot smuggle the same content through by editing it.
        if @warnings&.suppress?(message: message, community: community_scope)
          logger.debug { "dropped an edit of #{message.ref}, #{message.author&.any_name} is currently muted" }
          return []
        end

        notify_webhooks_change(message, community, ControlPlane::Webhooks::MESSAGE_EDITED,
                               data: { "body" => message.body.text.to_s[0, ControlPlane::Webhooks::MAX_TEXT] })

        targets.filter_map do |ref|
          endpoint = @topology.endpoint(ref.endpoint_id)
          next nil if endpoint.nil?

          adapter = adapter_for(endpoint)
          next nil if adapter.nil?

          unless adapter.capabilities_for(endpoint).edits?
            next post_edit_notice(adapter, endpoint, message, ref.native_id, community_scope) if edit_notices

            logger.debug { "dropped an edit of #{ref}, #{endpoint.id} cannot edit natively" }
            next nil
          end

          room = @topology.rooms_for(message.origin.id).find { |r| r.include?(endpoint.id) }
          # A destination the ORIGIN's own rooms cannot place is not one this
          # relay put in the map: it is a {Translation} cross-room copy, and
          # pushing the raw, untranslated edit there would corrupt it. Every
          # destination this feature itself records DOES resolve here.
          next nil if room.nil?
          next nil unless Core::CommunityScope.permit_or_log(endpoint, community, logger: logger,
                                                                                  doing: "editing #{message.ref}")

          adapter.edit(prepare(room, message, endpoint, scope: scope, community_scope: community_scope),
                       endpoint, ref.native_id)
        rescue AdapterError => e
          logger.error { "edit of #{ref} failed: #{e.message}" }
          nil
        end
      end

      def handle_delete(message, community: nil, delete_notices: false)
        # Before the drop and the claim below: a message somebody took back stops
        # being retained whether or not it was ever relayed.
        forget_retained(message, community)
        # A delete arrives on a relayed copy as often as on the original, so it
        # reaches every copy, siblings included, the way a reaction does.
        sources = @storage.origins(message.ref)
        targets = related_refs(message.ref, sources)
        return [] if targets.empty?

        # A message is deleted once, keyed on the ORIGINAL wherever one is known,
        # so the delete arriving on a copy and the origin's own echo of it agree
        # on one claim. The claim closes the concurrent window before the forget
        # below lands.
        return [] unless claim_event(sources.first || message.ref, "delete", community)

        notify_webhooks_change(message, community, ControlPlane::Webhooks::MESSAGE_DELETED)

        failed = []
        targets.each do |ref|
          endpoint = @topology.endpoint(ref.endpoint_id)
          next if endpoint.nil?

          adapter = adapter_for(endpoint)
          next if adapter.nil?

          unless adapter.capabilities_for(endpoint).deletes?
            if delete_notices
              post_delete_notice(adapter, endpoint, message, ref.native_id, community)
            else
              logger.debug { "dropped a delete of #{ref}, #{endpoint.id} cannot delete natively" }
            end
            next
          end

          @retry.call("delete of #{ref}") { adapter.delete(endpoint, ref.native_id) }
        rescue AdapterError => e
          failed << ref
          logger.error { "delete of #{ref} failed: #{e.message}" }
        end
        unless failed.empty?
          @durable_scheduler&.schedule(
            kind: DELETE_RETRY_KIND, run_at: Time.now + 10, community: community, discard_payload: true,
            payload: { "community_id" => community, "targets" => failed.map(&:to_a),
                       "forget" => [message.ref, *targets].uniq.map(&:to_a) }
          )
          release_event(sources.first || message.ref, "delete", community)
          return []
        end
        # A reaction is stored keyed on whichever ref it actually arrived on, so a
        # reaction left on a copy is only reachable through that copy's own ref;
        # forgetting only message.ref would strand its reaction_state row once the
        # message_map rows that could still find it are gone.
        [message.ref, *targets].each { |ref| @storage.forget(ref) }
        []
      end

      # Native identifiers only: no text or attachment URLs are retained.
      def retry_pending_delete(job)
        job.payload.fetch("targets").each do |endpoint_id, native_id|
          endpoint = @topology.endpoint(endpoint_id)
          next if endpoint.nil?
          next unless Core::CommunityScope.permit_or_log(endpoint, job.payload["community_id"], logger: logger,
                                                                                 doing: "retrying deletion")

          adapter = adapter_for(endpoint)
          raise AdapterError.new("delete target has no available adapter", retryable: true) if adapter.nil?

          @retry.call("delete of #{endpoint_id}:#{native_id}") { adapter.delete(endpoint, native_id) }
        end
        job.payload.fetch("forget").each do |endpoint_id, native_id|
          @storage.forget(Core::MessageRef.new(endpoint_id, native_id))
        end
      end

      # Drop what redirection's window kept for a message being deleted; the delete
      # may point at the original or at a relayed copy, so every ref it touches is
      # offered. Runs before the map is forgotten.
      def forget_retained(message, community)
        return if @redirection_window.nil? || community.nil?

        refs = [message.ref] + @storage.counterparts(message.ref) + @storage.origins(message.ref)
        refs.uniq.each do |ref|
          @redirection_window.forget(
            community_id: community, endpoint_id: ref.endpoint_id, native_id: ref.native_id
          )
        end
      rescue StandardError => e
        logger.warn { "could not drop the retained copy of #{message.ref}: #{e.class}: #{e.message}" }
      end

      # Tell the sender when part of their message could not be relayed.
      # behaviour.suppress_delivery_notices turns it off.
      def report_notes(message, receipt)
        return if @suppress_notices

        notes = receipt.extra[:notes]
        return if notes.nil? || notes.empty?

        adapter = adapter_for(message.origin)
        return if adapter.nil?

        notice = Core::Message.new(
          kind: :system,
          ref: Core::MessageRef.new(message.origin.id, "notice-#{message.correlation_id}"),
          origin: message.origin,
          author: Core::Author.new(display_name: "bridge", kind: :system),
          body: Core::RichText.plain(notes.join("\n")),
          reply_to: message.ref,
          sender_label: "bridge"
        )
        adapter.deliver(notice, message.origin)
      rescue StandardError => e
        logger.warn { "could not report a delivery notice: #{e.message}" }
      end

      def record(message, receipt, room, community)
        @storage.record(
          source: message.ref,
          destination: receipt.ref,
          room_id: room.id,
          expires_at: map_expiry(room, community)
        )
      rescue StorageError => e
        # Losing a map entry costs edit and delete propagation for one message; it
        # must never cost the message itself.
        logger.error { "could not record message map entry: #{e.message}" }
      end

      # A cross-platform redirection needs the map to translate the operator's
      # local reply back to the retained source row. Keep identifiers, never
      # message content, for the same lifetime as the retained text in rooms
      # that opted into redirection. Other rooms keep the ordinary map TTL.
      def map_expiry(room, community)
        return nil if @ttl.nil?

        ttl = @ttl
        if @redirection_window && redirection_retained?(community, room)
          ttl = [ttl, ControlPlane::RedirectionWindow::TTL_SECONDS].max
        end
        Time.now + ttl
      end

      # When a reaction row on +ref+ should expire. Reaction state belongs to the
      # message map row it hangs off, so it inherits that row's expiry instead of
      # taking a fresh TTL of its own from the moment somebody happened to react:
      # a late reaction would otherwise outlive the map row and keep answering
      # for a message the map no longer knows about. Falls back to a fresh TTL
      # only when the map holds nothing for +ref+ to inherit from.
      def reaction_expiry(ref)
        return nil if @ttl.nil?

        @storage.map_expiry(ref) || Time.now + @ttl
      end

      # Note that +endpoint_id+ now holds this message's content (migration 053);
      # silent without the ledger or a community, since the ledger is scoped by
      # community_id and an unscoped row could be read back against the wrong
      # tenant's endpoint. {ControlPlane::RelayFingerprints#record} already
      # swallows its own failure, so nothing here needs its own rescue.
      def record_fingerprint(message, endpoint_id, community_id)
        return if @relay_fingerprints.nil? || community_id.nil?

        @relay_fingerprints.record(
          community_id: community_id, endpoint_id: endpoint_id,
          text: message.body.text, author: ControlPlane::RelayFingerprints.author_key(message),
          timestamp: message.timestamp
        )
      end

      # Whether +endpoint_id+ already holds this SOURCE message's content: a
      # redelivered arrival that reaches {#deliver_one} again under a new native
      # ref, or a target two overlapping rooms both fan out to, would otherwise
      # post a second copy the relay-claim ledger never sees since it is keyed
      # on the ORIGINAL ref, not this one. False without the ledger or a
      # community, same as {#record_fingerprint}.
      def fingerprint_present?(message, endpoint_id, community_id)
        return false if @relay_fingerprints.nil? || community_id.nil?

        @relay_fingerprints.present?(
          community_id: community_id, endpoint_id: endpoint_id,
          text: message.body.text, author: ControlPlane::RelayFingerprints.author_key(message),
          timestamp: message.timestamp
        )
      end

      # Wait out whatever this adapter says the platform accepts, on both the
      # destination and the account, before handing it the message. Two keys
      # because the two limits are separate budgets: one busy room must not
      # spend the whole connection's.
      def paced(adapter, target, &send)
        limits = adapter.respond_to?(:outbound_limits) ? adapter.outbound_limits : nil
        return send.call if limits.nil?

        pace_under(limits[:account], [:account, target.adapter_name, target.account]) do
          pace_under(limits[:destination], [:destination, target.id], &send)
        end
      end

      def pace_under(limit, key, &block)
        return block.call if limit.nil?

        @pacer.pace(key, rate: limit[:rate], burst: limit[:burst] || 1, &block)
      end

      # The backstop behind every adapter-level echo defence: those all try to
      # recognise the bridge's own copy coming back in before it is relayed
      # again, and this instead just counts how often the bridge itself posts
      # to one endpoint, so a loop still trips it even if every one of them
      # misses at once. See {Core::LoopGuard#check_post_rate}.
      def breaker_open?(target, message)
        # Aggregate human traffic is not evidence of a relay loop. Keep the
        # backstop for automated authors, behind the source-ref progress check.
        return false unless message.author.bot? || message.author.system?

        verdict = @loop_guard.check_post_rate(target.id)
        return false if verdict.nil?
        return true if verdict == :open

        logger.error do
          "post rate breaker tripped for #{target.id}: more than #{Core::LoopGuard::POST_RATE_LIMIT} posts " \
            "in #{Core::LoopGuard::POST_RATE_WINDOW}s, which looks like a relay loop rather than real " \
              "traffic. Automated posts pause for #{Core::LoopGuard::POST_RATE_COOLDOWN}s before trying again."
        end
        true
      end

      # Atomically claim +source+ for +operation+ so exactly one instance relays it.
      # A storage failure fails open, because a dropped relay is worse than a rare
      # duplicate.
      def claim_event(source, operation, community)
        @storage.claim_relay(
          source: source, operation: operation, community: community,
          expires_at: @claim_ttl ? Time.now + @claim_ttl : nil
        )
      rescue StorageError => e
        logger.warn { "relay claim for #{source}/#{operation} failed, relaying anyway: #{e.message}" }
        true
      end

      # Release a claim so a complementary later event can re-claim it. A lost
      # release costs a future re-add its relay, never a duplicate.
      def release_event(source, operation, community)
        @storage.release_relay(source: source, operation: operation, community: community)
      rescue StorageError => e
        logger.warn { "could not release relay claim for #{source}/#{operation}: #{e.message}" }
      end

      # A stable digest, since Object#hash is per-process salted and both
      # containers of an overlap must agree on the key.
      def edit_digest(message)
        Digest::SHA256.hexdigest(message.body.text.to_s)[0, 16]
      end

      # The claim key for an edit.
      def edit_operation(digest) = "edit:#{digest}"

      # Where the last digest claimed for a ref's edit is remembered, so the
      # NEXT edit can release it rather than leave it held for the full
      # relay_claim_ttl. Own key, distinct from the claim itself, since a claim
      # row does not say what came before it.
      def last_edit_digest_key(ref) = "bridge:edit:last:#{ref.endpoint_id}:#{ref.native_id}"

      # Release the ref's previous edit claim (if it differs from the one just
      # won) and remember this edit as the new "previous" for next time. A
      # revert to that earlier text can then claim it again immediately instead
      # of finding it still held.
      def release_previous_edit_claim(ref, digest, community)
        key = last_edit_digest_key(ref)
        previous = @storage.get_state(key)
        release_event(ref, edit_operation(previous), community) if previous && previous != digest
        @storage.put_state(key, digest, expires_at: @claim_ttl ? Time.now + @claim_ttl : nil)
      rescue StorageError => e
        logger.warn { "could not track the previous edit claim for #{ref}: #{e.message}" }
      end

      # The claim key for a reaction: actor plus the reaction's canonical key, so
      # distinct people or emoji stay independent.
      def reaction_operation(reaction, actor)
        "react:#{actor}:#{reaction.key}"
      end

      # The claim key for a reaction notice, and the rule both notice paths
      # follow: one line per holder per message per target, held while the
      # holder holds the emoji and released when they let go. Here the holder is
      # the person, with no emoji in the key, so a burst of emoji from one
      # person still costs a single line.
      def reaction_notice_operation(target, actor)
        "react-notice:#{target.id}:#{actor}"
      end

      # The same key for a count update, where the holder is the emoji: nobody
      # is named, so there is no person to charge a line to and each emoji
      # stands for whoever is behind it.
      def anonymous_notice_operation(target, reaction)
        "react-notice:#{target.id}:anonymous:#{reaction.key}"
      end

      # Make {NO_ACTOR} hold exactly +set+ on +ref+. Only the anonymous slot is
      # touched: removing an emoji a named person still holds is a no-op here,
      # so the mirror stays up for them.
      def hold_anonymously(ref, set, previous)
        set.each do |reaction|
          @storage.add_reaction(ref, reaction: reaction, actor_id: NO_ACTOR,
                                expires_at: reaction_expiry(ref))
        end
        (previous - set).each do |reaction|
          @storage.remove_reaction(ref, reaction: reaction, actor_id: NO_ACTOR)
        end
      end

      # The reactions an anonymous count is really reporting: a count includes the bot's
      # own emoji with nothing to tell it apart from anybody else's, so whatever this
      # message is already mirroring comes back off before the set is stored, or the
      # mirror feeds itself. Checked against every ref in {#related_refs}, since the
      # emoji placed here came from the aggregate on the original or on any copy of it.
      def anonymous_set(message)
        mirrored = related_refs(message.ref).flat_map { |ref| @storage.reactions_on(ref) }
        message.reaction_set - mirrored
      end
    end
  end
end
