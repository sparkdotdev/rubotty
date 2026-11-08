# frozen_string_literal: true

require "sequel"
require "json"

module Rubotty
  module ControlPlane
    # The Sequel::Model classes for the control plane, bound to one database.
    # Built per database rather than as process-global constants, so a test
    # can stand up an isolated in-memory control plane without a global
    # Sequel::Model.db, and associations below reference sibling classes
    # through the reader methods this defines. The database must already be
    # migrated (ControlPlane::Migrator) before this runs, since set_dataset
    # introspects the table's columns.
    class Models
      # Included in every model so a JSON TEXT column reads back as a Ruby value.
      # The columns themselves stay portable TEXT, and this is the seam a future
      # move to Postgres jsonb would change.
      module JsonColumn
        def json_value(column)
          raw = self[column]
          return {} if raw.nil? || raw == ""

          JSON.parse(raw)
        rescue JSON::ParserError
          {}
        end
      end

      # logical name => table
      TABLES = {
        community: :communities,
        platform_connection: :platform_connections,
        channel: :channels,
        room: :rooms,
        room_channel: :room_channels,
        person: :people,
        person_identity: :person_identities,
        operator: :operators,
        operator_request: :operator_requests,
        feature_setting: :feature_settings,
        observed_identity: :observed_identities,
        observed_identity_name: :observed_identity_names,
        content_policy_action: :content_policy_actions,
        content_policy_misfire: :content_policy_misfires,
        content_policy_repost: :content_policy_reposts,
        topic_move_proposal: :topic_move_proposals,
        undelivered_dm: :undelivered_dms,
        warning_announcement: :warning_announcements,
        member_report: :member_reports,
        bridged_nickname: :bridged_nicknames,
        bridged_nickname_history: :bridged_nickname_history,
        guest_invite: :guest_invites,
        guest_message: :guest_messages,
        guest_upload: :guest_uploads,
        # Multi-connection platform config. irc_network feeds Core::Runtime's
        # account construction (ControlPlane::IrcNetworks#live); fluxer_instance
        # is data and config scaffolding only, not wired to an adapter yet.
        irc_network: :irc_networks,
        fluxer_instance: :fluxer_instances,
        # A room-scoped event and its RSVPs. Data model only so far.
        event: :events,
        event_rsvp: :event_rsvps,
        # Which posted copies of an event's card exist, on which endpoint, under
        # which native id: the reverse lookup RSVP-by-reaction needs, and the
        # forward one Events::Announcer#refresh_rsvp needs to edit each in place.
        event_card: :event_cards,
        # A room-scoped vote. /poll and /schedule share these, told apart by kind.
        poll: :polls,
        poll_option: :poll_options,
        poll_vote: :poll_votes,
        poll_card: :poll_cards,
        # A space the bot was added to that is not yet mapped to a community:
        # pending administrator review, approved (mapped), or denied (a soft,
        # clearable blacklist entry).
        pending_space: :pending_spaces,
        # What a backfill sweep intends to relay into one channel, held until an
        # operator accepts it. A large restore is a decision somebody should make
        # rather than something a boot does on its own.
        backfill_proposal: :backfill_proposals,
        backfill_proposal_item: :backfill_proposal_items,
        dashboard_action_permission: :dashboard_action_permissions,
        dashboard_appearance: :dashboard_appearances,
        # A credentialed gateway connection: the database's own copy of what a
        # bridge.config.yaml `accounts:` entry describes. No community_id, because
        # an account is a deployment-level shared credential.
        account: :accounts,
        # A REST API bearer credential: developer keys belong to one community
        # below, administrator keys carry a NULL community_id and are reached only
        # through the bare TABLES accessor.
        api_key: :api_keys,
        # One row per REST API request, counted (never otherwise read) by
        # ControlPlane::ApiRateLimiter. Reached only through its api_key.
        api_request_log: :api_request_log,
        # Operator authored scripts. They live here rather than on disk: a
        # container is deleted on every redeploy and an operator's rule is not.
        community_script: :community_scripts,
        # Named outbound endpoints a script may call. A script names one of these;
        # it never sees the URL or the key.
        script_endpoint: :script_endpoints,
        # The small amount a script may remember between invocations.
        script_memo: :script_memos,
        # The other half of that memory: whole numbers with no expiry,
        # community scoped, for the totals a memo's thirty day ceiling could
        # never hold. See Scripting::Memory.
        script_ledger: :script_ledgers,
        script_stat: :script_stats,
        # How long the model-backed features took and how often they failed,
        # counted per community, feature, metric and day. Measurements only;
        # see ControlPlane::ModelCallStats.
        model_call_stat: :model_call_stats,
        # How often one script actually ran, a row per script per day per
        # source. Written coalesced by ControlPlane::Scripts rather than once
        # per message.
        script_run: :script_runs,
        # A session and its rounds, reached by community and room rather than
        # by script, since a game is usually three scripts sharing one run.
        # The score lives in script_ledgers like any other total a script
        # keeps, not a game-specific column here.
        script_session: :script_sessions,
        script_round: :script_rounds,
        # A message posted through the REST API, waiting for the bot to emit it.
        # The API process has no connected adapters, so it queues here and the
        # bot's relay drains it through the moderation pipeline.
        api_pending_message: :api_pending_messages,
        # The seconds-long buffer the API's live stream reads. See
        # ControlPlane::LiveRoomFeed for the TTL that keeps it from being an
        # archive.
        live_room_message: :live_room_messages,
        # Pending text for an opted-in room summary and the boundary left after
        # a successful post. Both are keyed by community and room key.
        room_summary_message: :room_summary_messages,
        room_summary_watermark: :room_summary_watermarks,
        # Every message rubotty posted in a room and left standing, so /clean
        # has something to delete: on Telegram a bot can read no history, so a
        # message absent from here can never be found again. See
        # ControlPlane::BotMessages.
        bot_message: :bot_messages,
        # The last summary rubotty itself pinned per community, room and
        # endpoint, so a new summary can unpin the old one first. Never a read
        # of what is currently pinned: no adapter exposes that.
        room_summary_pin: :room_summary_pins,
        # Runs of messages an operator has moved from one room into another, plus
        # the working state of a move still in flight.
        redirection: :redirections,
        # The bounded record of what was said in the rooms redirection is switched
        # on for, which is where a move gets its text on a platform that cannot
        # hand back its own history. See ControlPlane::RedirectionWindow.
        redirection_window_message: :redirection_window_messages,
        # What a script raised for the operators, and whether anybody has looked
        # at it. See ControlPlane::Alerts.
        alert: :alerts,
        # What one endpoint has actually held, arrival or post: a digest only,
        # never a body. See ControlPlane::RelayFingerprints.
        relay_fingerprint: :relay_fingerprints,
        # A file rubotty is holding because the platform it was headed for would
        # not take it. METADATA only: the bytes are in Storage::ObjectStore, and
        # the key that unseals them is in the download URL rather than in this row.
        rehosted_file: :rehosted_files,
        # One-time permission to put a file into a room from a browser, which is
        # what /upload DMs somebody a link to. See ControlPlane::UploadTickets.
        rehosted_upload_ticket: :rehosted_upload_tickets,
        # Where a community wants its events sent. The one row in this schema
        # holding a secret in the clear, because the HMAC has to be computed
        # from it.
        webhook_subscription: :webhook_subscriptions,
        # One row per event per subscription, with the bytes that were signed and
        # what came back. See ControlPlane::Webhooks.
        webhook_delivery: :webhook_deliveries,
        # A named connection to an outside service rubotty plugs into, e.g.
        # libretranslate. Deployment-wide, no community_id: see
        # ControlPlane::Integrations.
        integration: :integrations,
        # What a remote system posted into the api_wrapper platform adapter,
        # waiting for the bot to emit it, the multi-account sibling of
        # api_pending_message. See ControlPlane::ApiWrapperEvents.
        api_wrapper_pending_event: :api_wrapper_pending_events,
        # A react, edit or delete addressed at a room-level message id rather
        # than a bridge channel_id, waiting for the bot to fan it out across
        # every channel that message actually landed in. See
        # ControlPlane::ApiMessageActions.
        api_pending_message_action: :api_pending_message_actions
      }.freeze

      attr_reader :db
      TABLES.each_key { |name| attr_reader name }

      def initialize(db)
        @db = db
        build_classes
        define_associations
      end

      # Serialise a Ruby value for a JSON TEXT column.
      def self.dump_json(value)
        JSON.generate(value)
      end

      private

      def build_classes
        TABLES.each do |name, table|
          klass = Class.new(Sequel::Model)
          klass.include(JsonColumn)
          name_string = "Rubotty::ControlPlane::Models::#{camelize(name)}"
          klass.define_singleton_method(:name) { name_string }
          klass.define_singleton_method(:to_s) { name_string }
          klass.set_dataset(@db[table])
          instance_variable_set("@#{name}", klass)
        end
      end

      def camelize(symbol)
        symbol.to_s.split("_").map(&:capitalize).join
      end

      def define_associations
        community.one_to_many :platform_connections, class: platform_connection, key: :community_id
        community.one_to_many :channels,             class: channel,             key: :community_id
        community.one_to_many :rooms,                class: room,                key: :community_id
        community.one_to_many :people,               class: person,              key: :community_id
        community.one_to_many :operators,            class: operator,            key: :community_id
        community.one_to_many :operator_requests,    class: operator_request,    key: :community_id
        # Denormalized off the identity's own person, the same way
        # observed_identities carries community_id directly rather than through
        # people, so the community a platform account is linked in can be indexed
        # and scoped without a join.
        community.one_to_many :person_identities,    class: person_identity,     key: :community_id
        community.one_to_many :feature_settings,     class: feature_setting,     key: :community_id
        # Deliberately NOT linked to people: passive observation cannot know two
        # handles are the same human.
        community.one_to_many :observed_identities,  class: observed_identity,   key: :community_id
        community.one_to_many :observed_identity_names, class: observed_identity_name, key: :community_id
        community.one_to_many :content_policy_actions, class: content_policy_action, key: :community_id
        community.one_to_many :content_policy_misfires, class: content_policy_misfire, key: :community_id
        community.one_to_many :content_policy_reposts, class: content_policy_repost, key: :community_id
        community.one_to_many :topic_move_proposals, class: topic_move_proposal, key: :community_id
        community.one_to_many :undelivered_dms, class: undelivered_dm, key: :community_id
        community.one_to_many :warning_announcements, class: warning_announcement, key: :community_id
        community.one_to_many :member_reports, class: member_report, key: :community_id
        community.one_to_many :bridged_nicknames,    class: bridged_nickname,    key: :community_id
        community.one_to_many :bridged_nickname_history, class: bridged_nickname_history, key: :community_id
        # Channel-scoped, expiring invites and the feed behind the guest web chat.
        community.one_to_many :guest_invites,        class: guest_invite,        key: :community_id
        community.one_to_many :guest_messages,       class: guest_message,       key: :community_id
        # A guest-uploaded file's bytes, kept out of the polled feed and served
        # back at a token URL.
        community.one_to_many :guest_uploads,        class: guest_upload,        key: :community_id
        # Each community may define any number of IRC networks and Fluxer
        # instances, which do not join through platform_connections.
        community.one_to_many :irc_networks,         class: irc_network,         key: :community_id
        community.one_to_many :fluxer_instances,     class: fluxer_instance,     key: :community_id
        # Events are room-scoped, so a community also reaches every event across
        # its rooms directly.
        community.one_to_many :events,               class: event,               key: :community_id
        community.one_to_many :polls,                class: poll,                key: :community_id
        # Only a developer key carries a community_id; an administrator key's is
        # NULL and is reached through models.api_key directly.
        community.one_to_many :api_keys,              class: api_key,             key: :community_id
        community.one_to_many :community_scripts,     class: community_script,    key: :community_id
        community.one_to_many :script_endpoints,      class: script_endpoint,     key: :community_id
        community.one_to_many :script_memos,          class: script_memo,         key: :community_id
        # Kept totals, community scoped by construction: unlike a memo there
        # is no room in the key at all, and no owning script either, since a
        # total outlives whichever rule happened to open it.
        community.one_to_many :script_ledgers,        class: script_ledger,       key: :community_id
        community.one_to_many :script_stats,          class: script_stat,         key: :community_id
        community.one_to_many :model_call_stats,      class: model_call_stat,     key: :community_id
        community.one_to_many :script_runs,           class: script_run,          key: :community_id
        community.one_to_many :script_sessions,       class: script_session,      key: :community_id
        community.one_to_many :script_rounds,         class: script_round,        key: :community_id
        # Queued API posts and the live-stream buffer both cascade with the
        # community, so removing a tenant takes its in-flight content too.
        community.one_to_many :api_pending_messages,  class: api_pending_message, key: :community_id
        community.one_to_many :live_room_messages,    class: live_room_message,   key: :community_id
        community.one_to_many :room_summary_messages, class: room_summary_message, key: :community_id
        community.one_to_many :room_summary_watermarks, class: room_summary_watermark, key: :community_id
        community.one_to_many :room_summary_pins,     class: room_summary_pin,     key: :community_id
        community.one_to_many :redirections,          class: redirection,         key: :community_id
        community.one_to_many :alerts,                class: alert,               key: :community_id
        community.one_to_many :relay_fingerprints,    class: relay_fingerprint,   key: :community_id
        # The association takes a community's rehosted-file metadata rows with it;
        # the BYTES are on disk and are removed by ControlPlane::RehostedFiles, so
        # deleting a tenant must go through that service, not the cascade alone.
        community.one_to_many :rehosted_files,        class: rehosted_file,       key: :community_id
        community.one_to_many :rehosted_upload_tickets, class: rehosted_upload_ticket, key: :community_id
        # A delivery cascades with its subscription as well, so deleting a
        # subscriber takes the record of what it was sent with it.
        community.one_to_many :webhook_subscriptions, class: webhook_subscription, key: :community_id
        community.one_to_many :webhook_deliveries,    class: webhook_delivery,     key: :community_id

        platform_connection.many_to_one :community, class: community, key: :community_id
        platform_connection.one_to_many :channels,  class: channel,   key: :platform_connection_id

        channel.many_to_one  :community,           class: community,           key: :community_id
        channel.many_to_one  :platform_connection, class: platform_connection, key: :platform_connection_id
        channel.one_to_many  :room_channels,       class: room_channel,        key: :channel_id
        channel.one_to_many  :guest_invites,       class: guest_invite,        key: :channel_id
        channel.one_to_many  :guest_messages,      class: guest_message,       key: :channel_id
        channel.one_to_many  :guest_uploads,       class: guest_upload,        key: :channel_id
        channel.many_to_many :rooms, class: room, join_table: :room_channels,
                                     left_key: :channel_id, right_key: :room_id

        room.many_to_one  :community,        class: community,       key: :community_id
        room.one_to_many  :room_channels,    class: room_channel,    key: :room_id
        # feature_settings is room-scoped (a rule set on a room applies to every
        # channel bridged into it); a NULL room_id row is the community-wide
        # default and is reached through community.feature_settings.
        room.one_to_many  :feature_settings, class: feature_setting, key: :room_id
        room.many_to_many :channels, class: channel, join_table: :room_channels,
                                     left_key: :room_id, right_key: :channel_id
        # A guest session is room-scoped, so a room's invites, feed rows and
        # uploads hang off it too, alongside the channel-keyed associations above
        # (kept for the rows that still carry an optional, informational channel_id).
        room.one_to_many  :guest_invites,  class: guest_invite,  key: :room_id
        room.one_to_many  :guest_messages, class: guest_message, key: :room_id
        room.one_to_many  :guest_uploads,  class: guest_upload,  key: :room_id
        room.one_to_many  :events,         class: event,         key: :room_id
        room.one_to_many  :polls,          class: poll,          key: :room_id
        # A queued API post names the room it is destined for. The live-stream
        # buffer deliberately has no association here: it is keyed by room_key
        # rather than by a rooms foreign key.
        room.one_to_many  :api_pending_messages, class: api_pending_message, key: :room_id

        room_channel.many_to_one :room,    class: room,    key: :room_id
        room_channel.many_to_one :channel, class: channel, key: :channel_id

        person.many_to_one :community,         class: community,       key: :community_id
        person.one_to_many :person_identities, class: person_identity, key: :person_id
        person.one_to_many :operators,         class: operator,        key: :person_id

        person_identity.many_to_one :person,    class: person,    key: :person_id
        person_identity.many_to_one :community, class: community, key: :community_id

        operator.many_to_one :community, class: community, key: :community_id
        operator.many_to_one :person,    class: person,    key: :person_id

        operator_request.many_to_one :community, class: community, key: :community_id

        feature_setting.many_to_one :community, class: community, key: :community_id
        feature_setting.many_to_one :room,      class: room,      key: :room_id

        observed_identity.many_to_one :community, class: community, key: :community_id

        observed_identity_name.many_to_one :community, class: community, key: :community_id

        bridged_nickname.many_to_one :community, class: community, key: :community_id
        bridged_nickname.many_to_one :person,    class: person,    key: :person_id

        bridged_nickname_history.many_to_one :community, class: community, key: :community_id
        bridged_nickname_history.many_to_one :person,    class: person,    key: :person_id

        guest_invite.many_to_one :community,     class: community,     key: :community_id
        guest_invite.many_to_one :room,          class: room,          key: :room_id
        guest_invite.many_to_one :channel,       class: channel,       key: :channel_id
        guest_invite.one_to_many :guest_messages, class: guest_message, key: :invite_id

        guest_message.many_to_one :community,    class: community,     key: :community_id
        guest_message.many_to_one :room,         class: room,          key: :room_id
        guest_message.many_to_one :channel,      class: channel,       key: :channel_id
        guest_message.many_to_one :invite,       class: guest_invite,  key: :invite_id

        guest_upload.many_to_one :community,     class: community,     key: :community_id
        guest_upload.many_to_one :room,          class: room,          key: :room_id
        guest_upload.many_to_one :channel,       class: channel,       key: :channel_id

        irc_network.many_to_one     :community, class: community, key: :community_id
        fluxer_instance.many_to_one :community, class: community, key: :community_id

        # many_to_one only, never required: an administrator key's community_id is
        # NULL by design.
        api_key.many_to_one :community, class: community, key: :community_id
        community_script.many_to_one :community, class: community, key: :community_id
        script_endpoint.many_to_one :community, class: community, key: :community_id
        script_memo.many_to_one :community, class: community, key: :community_id
        script_ledger.many_to_one :community, class: community, key: :community_id
        script_stat.many_to_one :community, class: community, key: :community_id
        model_call_stat.many_to_one :community, class: community, key: :community_id
        script_run.many_to_one :community, class: community, key: :community_id
        # A count belongs to the script it counts, so purging one takes its
        # history with it.
        script_run.many_to_one :script, class: community_script, key: :script_id
        community_script.one_to_many :script_runs, class: script_run, key: :script_id
        script_session.many_to_one :community, class: community, key: :community_id
        script_round.many_to_one :community, class: community, key: :community_id
        # A round belongs to a session, so dropping a session takes its rounds
        # with it.
        script_round.many_to_one :session, class: script_session, key: :session_id
        script_session.one_to_many :script_rounds, class: script_round, key: :session_id
        redirection.many_to_one :community, class: community, key: :community_id
        alert.many_to_one :community, class: community, key: :community_id
        rehosted_file.many_to_one :community, class: community, key: :community_id
        rehosted_upload_ticket.many_to_one :community, class: community, key: :community_id
        webhook_subscription.many_to_one :community, class: community, key: :community_id
        webhook_delivery.many_to_one :community, class: community, key: :community_id
        webhook_delivery.many_to_one :webhook_subscription, class: webhook_subscription, key: :subscription_id
        webhook_subscription.one_to_many :webhook_deliveries, class: webhook_delivery, key: :subscription_id
        script_memo.many_to_one :community_script, class: community_script, key: :community_script_id
        community_script.one_to_many :script_memos, class: script_memo, key: :community_script_id
        # Every request-log row belongs to exactly one key, required, so a count is
        # always attributable.
        api_request_log.many_to_one :api_key, class: api_key, key: :api_key_id

        api_pending_message.many_to_one :community, class: community, key: :community_id
        api_pending_message.many_to_one :room,      class: room,      key: :room_id
        # Which credential posted it, for the audit trail. Never required: the
        # column goes NULL when a key is deleted, so the queued row survives its
        # author.
        api_pending_message.many_to_one :api_key,   class: api_key,   key: :api_key_id

        live_room_message.many_to_one :community, class: community, key: :community_id
        room_summary_message.many_to_one :community, class: community, key: :community_id
        room_summary_watermark.many_to_one :community, class: community, key: :community_id

        event.many_to_one :community, class: community,  key: :community_id
        event.many_to_one :room,      class: room,       key: :room_id
        event.one_to_many :rsvps,     class: event_rsvp, key: :event_id
        # The posted card copies for this event, so
        # Events::Announcer#refresh_rsvp reaches every one to edit in place.
        event.one_to_many :cards,     class: event_card, key: :event_id

        event_rsvp.many_to_one :event, class: event, key: :event_id
        event_card.many_to_one :event, class: event, key: :event_id

        poll.many_to_one :community, class: community, key: :community_id
        poll.many_to_one :room,      class: room,      key: :room_id
        poll.one_to_many :options,   class: poll_option, key: :poll_id
        poll.one_to_many :votes,     class: poll_vote,   key: :poll_id
        poll.one_to_many :cards,     class: poll_card,   key: :poll_id

        poll_option.many_to_one :poll,  class: poll,      key: :poll_id
        poll_option.one_to_many :votes, class: poll_vote, key: :option_id
        poll_vote.many_to_one :poll,   class: poll,        key: :poll_id
        poll_vote.many_to_one :option, class: poll_option, key: :option_id
        poll_card.many_to_one :poll,   class: poll,        key: :poll_id

        # community_id is nullable (NULL while pending, and again once denied), so
        # this is many_to_one rather than a required association, and community
        # gets no reverse one_to_many.
        pending_space.many_to_one :community, class: community, key: :community_id
      end
    end
  end
end
