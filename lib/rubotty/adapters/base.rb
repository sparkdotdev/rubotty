# frozen_string_literal: true

module Rubotty
  module Adapters
    # The platform adapter contract: a new platform subclasses this and registers it, with
    # nothing under core, storage or config needing to change.
    # #start must return promptly, with any polling loop, websocket pump or HTTP listener on a
    # thread the adapter owns and joins in #stop; #deliver, #edit and #delete must be thread
    # safe since they can run concurrently across rooms.
    #
    # Required overrides: .adapter_name, .account_schema, .endpoint_schema, #start, #stop,
    # #own_account_id, #capabilities, #deliver; #edit and #delete only when declared.
    class Base
      class << self
        # Symbol used in YAML as `adapter:`. Must be unique.
        # @return [Symbol]
        def adapter_name
          raise NotImplementedByAdapterError, "#{name} must define .adapter_name"
        end

        # Schema for one credentialed connection, the `accounts:` block in YAML.
        # Secrets must be declared as `_env` fields so tokens never appear in a
        # config file.
        # @return [Rubotty::Config::Schema]
        def account_schema
          raise NotImplementedByAdapterError, "#{name} must define .account_schema"
        end

        # Schema for the adapter specific part of one endpoint: everything in an
        # `endpoints:` entry other than the keys core owns (id, adapter, account,
        # receive, send, relay, display_name, label).
        # @return [Rubotty::Config::Schema]
        def endpoint_schema
          raise NotImplementedByAdapterError, "#{name} must define .endpoint_schema"
        end

        # Cross field validation a per field schema cannot express, for example
        # "exactly one of these two keys is required".
        # @return [Array<String>] problems, empty when valid
        def validate_endpoint(_settings, _path) = []

        # @see .validate_endpoint
        def validate_account(_settings, _path) = []

        # Whether an account of this adapter may boot with its secret absent, as
        # a dormant gateway instead of a fatal config error. Only the single
        # identity platforms opt in, where one account is exactly one connection;
        # several connections per account need a per connection answer this flag
        # cannot give.
        def dormant_on_missing_secret? = false

        # Whether this adapter's own code ever calls into ChannelDiscovery
        # (#saw, #inventory). False by default; an adapter that feeds discovery
        # overrides it, so the guard spec in spec/adapters knows which
        # endpoint_schema {.addressing}'s output has to satisfy.
        def discovers_channels? = false

        # The route_key a seeded YAML +endpoint+ carries once mapped, in the
        # same shape ChannelDiscovery would give the identical channel found
        # live. {ControlPlane::Seed} calls this for every endpoint it seeds, so
        # a seeded row and a later discovery sweep resolve to the same channel
        # instead of drifting into two. Every adapter Seed can be asked to seed
        # must override this; the default raises so a new platform fails at
        # seed time rather than seeding a route_key discovery can never match.
        def route_key_for(_endpoint)
          raise NotImplementedByAdapterError, "#{name} must define .route_key_for"
        end

        # The endpoint settings a discovered channel needs so it addresses
        # correctly once mapped, the mirror of {.route_key_for}: given the
        # route_key a sweep enumerated and, where needed, the external_id
        # space it came from, the settings hash to store. Only an adapter
        # {.discovers_channels?} needs to override this; the default raises
        # so a new platform fails loudly at the discovery seam instead of
        # quietly saving unusable settings.
        def addressing(_route_key, external_id: nil)
          raise NotImplementedByAdapterError, "#{name} must define .addressing"
        end

        # The optional parts of the contract, checked at the class level so
        # `rubotty check` can report a gap before any adapter is built. Every
        # one defaults to false, and an adapter opts in by overriding the matching
        # method here; the instance method below just delegates to it.
        def supports_leave? = false
        def supports_space_notice? = false
        def supports_space_enumeration? = false
        def supports_admin_dm? = false
        def supports_admin_dm_delete? = false
        def supports_backfill? = false
        def supports_gap_ownership? = false
        def supports_reaction_backfill? = false
        def supports_native_events? = false
        def supports_channel_management? = false

        # Every optional part above, name mapped to the supports_x? that
        # answers it. The one list {.capability_status} and the adapter
        # conformance suite both read, so neither keeps its own copy.
        OPTIONAL_PARTS = {
          leave: :supports_leave?,
          space_notice: :supports_space_notice?,
          space_enumeration: :supports_space_enumeration?,
          admin_dm: :supports_admin_dm?,
          admin_dm_delete: :supports_admin_dm_delete?,
          backfill: :supports_backfill?,
          gap_ownership: :supports_gap_ownership?,
          reaction_backfill: :supports_reaction_backfill?,
          native_events: :supports_native_events?,
          channel_management: :supports_channel_management?
        }.freeze

        # Parts of {OPTIONAL_PARTS} this adapter answers false for because the
        # PLATFORM could carry them and nobody has written the code here yet, each with the
        # reason: a part missing from both this and a true supports_x? means the platform
        # itself cannot do it, since a bare false could not tell those two apart, which is
        # how five adapters got reported as unable to DM when every one of them can.
        # Override with an honest answer as each gap gets filled in or written up.
        # @return [Hash<Symbol, String>]
        def not_written_here = {}.freeze

        # One of :supported, :not_written_here or :platform_cannot for +part+
        # (a key of {OPTIONAL_PARTS}), read off the two declarations above
        # instead of a bare true/false that cannot carry a reason.
        def capability_status(part)
          method = OPTIONAL_PARTS.fetch(part) { raise ArgumentError, "unknown optional part #{part.inspect}" }
          return :supported if public_send(method)
          return :not_written_here if not_written_here.key?(part)

          :platform_cannot
        end

        # Whether this adapter's #initialize accepts a pending_spaces keyword,
        # declared explicitly rather than read off #initialize by reflection,
        # so an adapter that has not wired the pending flow and one that
        # declines it on purpose are not the same false.
        def accepts_pending_spaces? = false

        # The download ceiling +settings+ implies for {Capabilities#max_fetch_bytes},
        # or nil where the adapter draws no such distinction from a real upload.
        # Class level, on the raw account settings rather than a live instance, so
        # a caller with no running adapter (the dashboard) can still show it.
        def max_fetch_bytes_for(_settings) = nil
      end

      # @param endpoints [Array<Core::Endpoint>] every endpoint for this
      #   adapter and account, so lookup tables can be built once
      # @param endpoint_resolver [#endpoint_for, nil] reads the live
      #   control-plane snapshot instead of the boot-time index, letting one
      #   shared bot token serve many communities; nil keeps the static index
      # @param discovery [#saw, #inventory, #recognize_guild, nil] records
      #   newly seen channels; on Discord it also resolves a guild's seed
      #   sentinel, so the auto-leave guard never leaves an unresolved community
      def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                     endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil,
                     pending_spaces: nil)
        @account = account
        @settings = settings
        @dispatcher = dispatcher
        @logger = logger
        @endpoints = endpoints
        @endpoint_resolver = endpoint_resolver
        @control_lane = control_lane
        @join_guard = join_guard
        @discovery = discovery
        @pending_spaces = pending_spaces
      end

      attr_reader :account, :settings, :dispatcher, :logger, :endpoints, :endpoint_resolver,
                  :control_lane, :join_guard, :discovery, :pending_spaces

      # The durable store, injected after construction by the runtime. Telegram
      # persists its getUpdates offset in it, and both it and Discord keep learned
      # thread names there; nil without a durable backend.
      attr_accessor :storage
      # Multipart identifiers must live at least as long as their message map.
      attr_accessor :delivery_state_ttl

      # The ephemeral-message primitive and the timer that fires its self-delete,
      # injected after construction like #storage. Needed by commands that run
      # below the pipeline (the Telegram /identify-topic fallback), which would
      # otherwise leave their reply and the invocation in the channel.
      attr_accessor :ephemeral, :cleanup

      # The file rehoster, injected after construction for the same reason; nil without
      # a control plane or a usable object store, and nothing else reads it. The Telegram
      # adapter copies a sender's profile photo through it, since a Telegram file URL
      # carries the bot token and cannot be given to another platform as an avatar.
      attr_accessor :rehoster

      # The second source a reaction's endpoint recovery falls back to when the
      # message map holds no row; nil without a control plane, and only Telegram
      # reads it. A bridge-authored post (an event card) never gets a message-map
      # entry, so Events::Announcer#holds_card? answers instead.
      attr_accessor :card_lookup

      # The {ControlPlane::SpaceMigration} that moves a community onto the new id
      # a platform gives a replaced space; nil without a control plane, and only
      # Telegram calls it, for a group upgraded to a supergroup.
      attr_accessor :space_migration

      # The shared, account-scoped inbound queue an adapter with no gateway of its
      # own drains on a poll loop; nil without a control plane. A REST-driven
      # adapter ({Adapters::ApiWrapper::Adapter}) has no live connection to receive
      # on, so the separate REST API process writes events here instead.
      attr_accessor :inbound_events

      def adapter_name = self.class.adapter_name

      # This platform's identifier as an origin, used in the cross platform
      # sender label ("<b>user</b>@telegram [display name]"). A federated
      # platform overrides this to return whatever disambiguates an account, for
      # example the sender's homeserver.
      def origin_label(_endpoint = nil) = self.class.adapter_name.to_s

      # The federated protocol qualifier for the sender label, nil on a
      # centralized platform. A federated {#origin_label} is a bare domain, which
      # alone cannot tell Matrix, IRC and XMPP apart, so those adapters name
      # their protocol here and {Core::SenderLabel} prefixes it with a double
      # colon: "matrix::user@homeserver".
      def origin_protocol(_endpoint = nil) = nil

      # Connect, authenticate, and begin receiving. Must return promptly.
      def start
        raise NotImplementedByAdapterError, "#{self.class.name} must implement #start"
      end

      # Disconnect and join any threads owned by this adapter. Must be safe to
      # call when never started, and safe to call twice.
      def stop
        raise NotImplementedByAdapterError, "#{self.class.name} must implement #stop"
      end

      def running? = false

      # The native user id of the account this adapter is signed in as, populated by
      # the end of {#start} and possibly nil before. Loop prevention rests on it: an
      # inbound message authored by this id is one we sent.
      def own_account_id
        raise NotImplementedByAdapterError, "#{self.class.name} must implement #own_account_id"
      end

      # Every native id presently valid as "us" for loop prevention. Defaults
      # to the one id {#own_account_id} reports; an adapter whose identity can
      # fork per room (see {Adapters::Xmpp::Adapter}, where a MUC nick
      # collision falls back to a different nick in one room without
      # touching the others) overrides this to report all of them, so an
      # echo under any is still recognised as ours.
      def own_account_ids = [own_account_id].compact

      # How much a native id from this platform can be trusted to name one
      # person. :account is an id that names one account for as long as it
      # exists, which is what the people directory needs to anchor an identity
      # on. :session is an id that names whoever holds a slot right now, so the
      # same string can mean two people across a restart and one person can
      # come back under a different one.
      IDENTITY_DURABILITY = %i[account session].freeze

      # The platform's answer, overridden by an adapter whose ids are weaker.
      def self.identity_durability = :account

      # What this platform will accept without refusing, as sends per second
      # and how many may go at once, for {Core::OutboundPacer} to keep under.
      # +destination+ paces one channel, +account+ paces the whole connection.
      # nil for either half is unpaced: a platform whose published limit nobody
      # has read is not one to invent a number for, and the 429 handling in
      # {Core::RetryPolicy} still catches it.
      def self.outbound_limits = { destination: nil, account: nil }

      # This connection's answer, for an adapter whose limits move with what it
      # is talking to.
      def outbound_limits = self.class.outbound_limits

      # This connection's answer. An adapter whose durability depends on the
      # remote behind one account overrides this rather than the class method.
      def identity_durability = self.class.identity_durability

      # @return [Capabilities]
      def capabilities
        raise NotImplementedByAdapterError, "#{self.class.name} must implement #capabilities"
      end

      # What this adapter can do for one endpoint, which is not always the same
      # across an account: an IRC network answers per its negotiated features
      # and a Telegram chat per its own type. The router asks this rather than
      # {#capabilities} everywhere it matters. Puppeting is declared on the
      # account's own {Capabilities} rather than here, since it says what the
      # platform can do at all, not which endpoint happens to be set up for it.
      def capabilities_for(_endpoint) = capabilities

      # Send +message+ to +endpoint+; it arrives fully prepared (sender_label and
      # reply_to already resolved), so only rendering and transport are left. A
      # multi-message send (an album) returns a receipt for the FIRST message only.
      #
      # @return [Core::DeliveryReceipt, Core::DeliveryReceipt::NOT_APPLICABLE, nil]
      #   NOT_APPLICABLE when nothing was meant to be delivered; nil when a
      #   send was attempted and produced no receipt, which {Features::Bridge} logs as a loss.
      # @raise [Rubotty::AdapterError] on platform failure
      def deliver(_message, _endpoint)
        raise NotImplementedByAdapterError, "#{self.class.name} must implement #deliver"
      end

      # Update a previously delivered message in place, +native_id+ being the id
      # {#deliver} returned; only called when {Capabilities#edits?}.
      #
      # @return [Core::DeliveryReceipt] on success
      # @return [nil] the target is already gone; ask {#already_gone?} rather
      #   than matching the platform's error text directly
      # @raise [Rubotty::AdapterError] any other failure; {Features::Bridge#handle_edit}
      #   filter_maps this return, so a bug here must raise to be seen
      def edit(_message, _endpoint, _native_id)
        raise NotImplementedByAdapterError, "#{self.class.name} declares edits but does not implement #edit"
      end

      # Remove a previously delivered message, only called when {Capabilities#deletes?}
      # is true. Nothing reads the return value, so a correct #delete raises on a genuine
      # failure and otherwise returns normally, already-gone included; {#already_gone?} is
      # what a caller wanting that distinction asks instead of parsing an error message.
      # @raise [Rubotty::AdapterError] on a genuine platform failure
      def delete(_endpoint, _native_id)
        raise NotImplementedByAdapterError, "#{self.class.name} declares deletes but does not implement #delete"
      end

      # Bring the reactions on one message into the requested state, declarative
      # because platforms disagree: Telegram replaces the bot's reactions
      # wholesale while Discord takes separate add/remove calls per emoji. A
      # platform refusal has to RAISE, since storage already recorded the emoji
      # as held; {#already_gone?} is the one exception, same as {#edit} and {#delete}.
      #
      # @param desired [Array<Core::Reaction>] oldest first
      # @raise [Rubotty::AdapterError] on platform failure
      def sync_reactions(_endpoint, _native_id, desired:, previous: [])
        raise NotImplementedByAdapterError,
              "#{self.class.name} declares reactions but does not implement #sync_reactions"
      end

      # Carry out a moderation action on this endpoint, only called for actions
      # listed in {Capabilities#moderation}; it returns a {Core::Moderation::Result},
      # raising only on a genuine fault since "I could not find that message" is a
      # normal outcome. Rescue {Rubotty::AdapterError} (and {Rubotty::PermissionError})
      # into a :failed or :forbidden Result, but never rescue StandardError more
      # widely, or an ordinary bug reads as an unremarkable refusal nobody sees.
      #
      # @param native_id [String, nil] the target message, or nil for a user level action
      def moderate(_command, _endpoint, _native_id)
        raise NotImplementedByAdapterError,
              "#{self.class.name} declares moderation actions but does not implement #moderate"
      end

      # Human readable description of an endpoint, for logs and `rubotty doctor`.
      def describe_endpoint(endpoint) = endpoint.to_s

      # A browser URL for one native message when this platform has a stable
      # permalink shape. Nil is the conservative default for private or
      # platform-specific histories that cannot promise one.
      def message_permalink(_endpoint, _native_id) = nil

      # A browser URL for the endpoint itself, for naming a room somewhere a
      # reader can tap it. Nil takes the same conservative default as
      # {#message_permalink}: a platform that cannot promise a stable address
      # publishes no URL rather than one that resolves to nothing.
      def room_permalink(_endpoint) = nil

      # Whether this adapter can remove the bot from a guild, group or room on
      # its own. When false the pending-space flow falls back to
      # {#post_space_notice} with the inert notice and marks the space denied, so
      # a bot that cannot leave still stops acting.
      def supports_leave? = self.class.supports_leave?

      # Post +notice+ (nil skips the post) then remove the bot from
      # +external_id+. Truthy means a confirmed leave; falsy or
      # {Rubotty::AdapterError} means it did not happen, and the caller falls
      # back to inert.
      def leave_space(_external_id, notice: nil) = false

      # Whether this adapter can post a one-off notice into a space it has not
      # left: the "pending review" notice on join, and the inert fallback notice
      # when a leave is unsupported or fails.
      def supports_space_notice? = self.class.supports_space_notice?

      # Post +text+ into +external_id+, best effort, truthy on success.
      def post_space_notice(_external_id, _text) = false

      # Whether this adapter can list one space's channels again on demand. The
      # first enumeration of a space happens while it is still pending, so it has
      # no platform connection to record channels against and is thrown away;
      # approval asks for it a second time through this.
      def supports_space_enumeration? = self.class.supports_space_enumeration?

      # Re-run channel discovery for +external_id+, best effort, truthy when the
      # enumeration actually ran.
      def enumerate_space(_external_id) = false

      # Whether this adapter can DM a specific native user id, which is how the
      # administrator hears that something landed in Pending.
      def supports_admin_dm? = self.class.supports_admin_dm?

      # DM +text+ to +native_id+, best effort. Returns a {Core::DmReceipt}
      # identifying the sent message, so a caller wanting it removable
      # later has something to hand {#delete_admin_dm}; nil on any failure,
      # exactly what a bare false used to mean.
      def send_admin_dm(_native_id, _text) = nil

      # Whether this adapter can delete a DM {#send_admin_dm} sent. An
      # instance method for symmetry with {#supports_admin_dm?} above,
      # delegating to the class level declaration so a caller with only a
      # class in hand (no live adapter, `rubotty check`) can ask the same
      # question.
      def supports_admin_dm_delete? = self.class.supports_admin_dm_delete?

      # Remove a DM {#send_admin_dm} sent, +receipt+ being what it returned, only
      # called when {#supports_admin_dm_delete?} is true. Best effort, truthy on success.
      def delete_admin_dm(_receipt) = false

      # Whether inbound arrives over a connection this adapter holds open, rather
      # than over a poll it repeats; a poller resumes from its own offset and is left
      # alone. A held connection can go quiet while still looking authenticated and
      # healthy from this side, and nothing here notices, so {Core::GatewayCycle}
      # drops and re-establishes these nightly.
      def persistent_connection? = false

      # Whether this adapter can reconstruct recent history for the paced
      # backfill. Telegram has no history API, so its sweep is skipped.
      def supports_backfill? = self.class.supports_backfill?

      # Canonical messages posted since +since+ in +endpoint+, oldest first,
      # reconstructed from platform history. Drops a copy this bridge wrote
      # itself, silently, because a real sweep must never re relay one.
      def backfill_messages(_endpoint, since:, limit: 500) = []

      # Whether this adapter can pair a backfill candidate with the ownership
      # answer {#backfill_messages} acts on but does not expose: :ours,
      # :not_ours or :unknown. Default: no, so a report cannot ask a platform
      # this narrow and gets exactly the classification it always got.
      def supports_gap_ownership? = self.class.supports_gap_ownership?

      # Every candidate {#backfill_messages} would consider, oldest first,
      # each paired with its ownership answer. Nothing is dropped here, unlike
      # {#backfill_messages}: this exists so a read only report can see what
      # gets filtered out of a real sweep, instead of guessing from a ledger
      # that was never built to answer the question.
      def backfill_candidates(_endpoint, since:, limit: 500) = []

      # Whether this adapter can fetch the reactions currently on one history
      # message, with their reacting users. Telegram sees reactions only as live
      # push updates, so its sweep skips the reaction pass.
      def supports_reaction_backfill? = self.class.supports_reaction_backfill?

      # The reactions on history message +native_id+ in +endpoint+, shaped as
      # +reaction_add+ {Core::Message}s (one per reacting user per emoji) so a
      # replayed reaction matches what a live one produces and the same react
      # claim dedups it. +limit+ is across all emoji.
      def backfill_reactions(_endpoint, _native_id, limit: 200) = []

      # ------------------------------------------------------------------
      # native scheduled events
      # ------------------------------------------------------------------

      # Every method below defaults to "this platform has no native scheduled
      # event". Discord is the only adapter that overrides any of it.

      # Whether this adapter can mirror a Rubotty event into the platform's own
      # scheduled-event object (Discord's Guild Scheduled Events).
      def supports_native_events? = self.class.supports_native_events?

      # Create a native scheduled event from +event+, returning the native id to
      # store in events.native_refs so a later update or delete can target it.
      # +endpoint+ is the room's own endpoint on this adapter and is required
      # throughout this group: it names the community whose native space the
      # call belongs in, and without it an implementation has nothing to scope
      # by but a deployment-wide guess. The default no-ops rather than raising,
      # so a caller that forgets the {#supports_native_events?} guard gets
      # nothing rather than a crash.
      def create_scheduled_event(_event, _endpoint) = nil

      # Update a previously created native scheduled event in place, +native_id+
      # being what {#create_scheduled_event} returned, +endpoint+ the same
      # required community scope {#create_scheduled_event} takes.
      def update_scheduled_event(_native_id, _event, _endpoint) = nil

      # Remove a previously created native scheduled event.
      def delete_scheduled_event(_native_id, _endpoint) = nil

      # Who has responded to a native scheduled event, read from the platform
      # (Discord's interested/going list) and not from the event_rsvps table.
      # @return [Array<Hash>] {identity:, response:, username:, display:} pairs
      def read_native_rsvps(_native_id, _endpoint) = []

      # Register a listener for a normalized native-event change: Discord's
      # GUILD_SCHEDULED_EVENT_CREATE/UPDATE/DELETE translated to
      # {Events::NativeEventChange}, so a listener never sees discordrb's shape.
      # Nothing fires on a platform that never calls {#emit_native_event_change}.
      def on_native_event_change(&block)
        return self if block.nil?

        (@native_event_listeners ||= []) << block
        self
      end

      # ------------------------------------------------------------------
      # channel management
      # ------------------------------------------------------------------

      # Every method defaults to "this platform cannot create or remove a channel
      # from here"; Discord and Telegram each override with their own creation
      # path. {ControlPlane::RoomProvisioning} checks
      # {#supports_channel_management?} first and treats false as a skip.

      # Whether this adapter can create and delete a native channel on its
      # platform.
      def supports_channel_management? = self.class.supports_channel_management?

      # Create a native channel named +name+ for +community_id+, returning the
      # new native id. The community is required because an implementation
      # handed nothing to scope by has to guess which space to create in, and
      # both of them did. With +template+ (a native id on this adapter) the new
      # channel starts from the same category or parent where the platform
      # allows it; the caller reads a raise as "this platform failed" and nil
      # as "nothing to do", so raise {Rubotty::PermissionError} for no rights.
      def create_channel(name:, community_id:, template: nil)
        scoped_channel_call!(community_id, "creating the channel #{name.to_s.inspect}")
        nil
      end

      # Delete a native channel on behalf of +community_id+. Truthy on a
      # confirmed delete; falsy or {Rubotty::AdapterError} on failure. The
      # community is required for the same reason as on {#create_channel}, and
      # matters more here, because a mis-scoped delete destroys content.
      def delete_channel(native_id, community_id:)
        scoped_channel_call!(community_id, "deleting the channel #{native_id.to_s.inspect}")
        false
      end

      # Copy +from+'s permissions onto +to+, both native ids on this adapter,
      # where the platform has copyable permissions at all (Discord's role and
      # member overwrites). Falsy when there was nothing to copy or it failed.
      def copy_channel_permissions(from:, to:) = false

      # ------------------------------------------------------------------
      # live channel reconciliation
      # ------------------------------------------------------------------

      # How often {#start_reconcile_loop} re-runs, in seconds.
      RECONCILE_INTERVAL = 300

      # Join whatever the live snapshot maps for this account that the
      # connection has not joined yet, and log anything still joined that the
      # snapshot no longer maps. IRC and XMPP have to actively join a space
      # before they can hear it, so they are the only adapters that override
      # {#joined_route_keys} and {#join_route}; every other adapter's
      # endpoint_for already reads the live snapshot, with nothing to
      # reconcile.
      def reconcile_channels
        return if @endpoint_resolver.nil?

        joined = joined_route_keys
        return if joined.nil?

        live = @endpoint_resolver.endpoints_for(self.class.adapter_name, account).to_h
        (live.keys - joined).each { |route_key| join_route(route_key, live[route_key]) }
        log_stale_joins(joined - live.keys)
      end

      def log_stale_joins(stale)
        return if stale.empty?

        logger.info do
          "#{self.class.adapter_name}: still joined to #{stale.size} space(s) the live snapshot " \
          "no longer maps: #{stale.join(", ")}"
        end
      end

      # Route keys this connection currently believes it has joined, or nil
      # when this adapter never has to join anything first, which skips
      # {#reconcile_channels} entirely.
      def joined_route_keys = nil

      # Join a route key the live snapshot resolved that {#joined_route_keys}
      # did not have yet. Paired with the override above.
      def join_route(_route_key, _endpoint) = nil

      # Run {#reconcile_channels} once, immediately, then schedule the next
      # run against {#cleanup}, for as long as the adapter stays running; a
      # no-op with nothing to reconcile (every adapter but IRC and XMPP).
      # {#cleanup} is nil for an adapter built without one, in which case the
      # periodic re-sync never runs, but the initial join at boot still happens.
      def start_reconcile_loop
        return if joined_route_keys.nil?

        reconcile_channels
        cleanup&.after(RECONCILE_INTERVAL) { tick_reconcile }
      end

      def tick_reconcile
        return unless running?

        reconcile_channels
      ensure
        start_reconcile_loop if running?
      end

      # ------------------------------------------------------------------
      # localized timestamps
      # ------------------------------------------------------------------

      # Render +time+ for display: the default localizes to +tz+ (a fixed offset,
      # "UTC", or an IANA zone name); Discord overrides this with <t:UNIX:...>
      # markup, which the Discord client localizes per viewer with no +tz+ needed.
      #
      # @param style [Symbol] :full a calendar rendering, :relative a countdown
      #   ("in 3 days") or countup ("2 hours ago"), :both both
      # @param now [Time] the instant a countdown is measured from, so a caller
      #   that already read its own clock is not compared against a later one
      def render_timestamp(time, style: :full, tz: "UTC", now: Time.now)
        Util::EventTimestamps.format(time, style: style, tz: tz, now: now)
      end

      # Feed a message the adapter reconstructed into the same inbound path a
      # gateway event takes, so it is deduped, routed and relayed like a live
      # one. Errors are contained so one bad message never aborts a sweep.
      def ingest(message)
        return nil if message.nil?

        emit(message)
        message
      rescue StandardError => e
        logger.warn { "error ingesting a backfilled message: #{e.class}: #{e.message}" }
        nil
      end

      protected

      # Say, at warn, that one DM did not go out, and answer the nil
      # {#send_admin_dm} promises. +reason+ is the adapter's own words for it.
      # Warn rather than info: a dropped DM quietly shrinks the operator
      # audience, and nobody goes looking for it until an alert has gone missing.
      def dm_refused(native_id, reason)
        logger.warn { "#{adapter_name}: could not DM #{native_id}: #{reason}" }
        nil
      end

      # Every channel management call runs under the control plane, where a
      # community always exists, so a nil is a caller that lost it rather than
      # a deployment with no tenants. Raises for the same reason
      # {Core::Endpoint.owned_by} does.
      def scoped_channel_call!(community_id, doing)
        raise ArgumentError, "#{doing} needs the community it is being done for" if community_id.nil?

        community_id
      end

      # Hand an inbound message to the core.
      def emit(message)
        dispatcher.call(message)
      end

      # Hand a normalized change to every listener {#on_native_event_change}
      # registered. A listener error is logged and swallowed so one bad consumer
      # never takes down the gateway thread that reported the change.
      def emit_native_event_change(change)
        Array(@native_event_listeners).each do |listener|
          listener.call(change)
        rescue StandardError => e
          logger.warn { "error in a native-event-change listener: #{e.class}: #{e.message}" }
        end
      end

      # Find the endpoint this adapter serves that matches +predicate+. Adapters
      # typically build their own index instead.
      def find_endpoint(&predicate)
        endpoints.find(&predicate)
      end

      # Whether +error+ means the target of the call that raised it is already
      # gone, the one shared seam for the answer {#edit}, {#delete} and
      # {#sync_reactions} are each allowed to swallow. See {AlreadyGone}.
      def already_gone?(error) = AlreadyGone.call(error)
    end
  end
end
