# frozen_string_literal: true

module Rubotty
  module Config
    # The core configuration schema. Everything here is platform neutral;
    # platform specific keys live in the schemas the adapters publish.
    module Definition
      module_function

      # Keys core owns on every endpoint. Unknown keys are permitted here and only
      # here; the rest belong to the adapter, validated in {Loader#adapter_settings}.
      def endpoint_core_schema
        Schema.define do
          field :id, :string, required: true,
                              desc: "unique identifier for this endpoint, referenced in logs and storage"
          field :adapter, :symbol, required: true,
                                   desc: "which platform adapter owns this endpoint"
          field :account, :string, default: "default",
                                   desc: "which entry under accounts: supplies credentials"
          field :label, :string, desc: "human facing name, used in log lines"
          field :receive, :boolean, default: true,
                                    desc: "accept messages arriving here and fan them out"
          field :send, :boolean, default: true,
                                 desc: "deliver messages from other endpoints here"
          field :relay, :hash, of: Definition.relay_schema, default: {},
                               desc: "which non chat event kinds to pass on"
          field :display_name, :hash, of: Definition.display_name_schema,
                                      desc: "sender name template overriding the default label for messages from here"
        end.allow_unknown!
      end

      def relay_schema
        Schema.define do
          field :join_messages, :boolean, default: true
          field :leave_messages, :boolean, default: true
          field :system_messages, :boolean, default: true
          field :reactions, :boolean, default: true,
                                      desc: "mirror reactions to and from this endpoint"
        end
      end

      def display_name_schema
        Schema.define do
          field :format, :string,
                desc: 'optional override template such as "{first_name} ({username})"; ' \
                      "unset uses the default cross platform label" do |value, path|
            unknown = Core::DisplayName.unknown_fields_in(value)
            next nil if unknown.empty?

            "#{path}: unknown placeholder#{unknown.size > 1 ? "s" : ""} " \
              "#{unknown.map { |u| "{#{u}}" }.join(", ")}. " \
              "Available: #{Core::Author::FIELDS.map { |f| "{#{f}}" }.join(", ")}"
          end
          field :fallback_format, :string,
                desc: "used when the main template references a field the sender does not have" do |value, path|
            unknown = Core::DisplayName.unknown_fields_in(value)
            next nil if unknown.empty?

            "#{path}: unknown placeholder #{unknown.map { |u| "{#{u}}" }.join(", ")}"
          end
        end
      end

      def room_schema
        endpoint = Schema.define.allow_unknown!
        Schema.define do
          field :id, :string, required: true, desc: "unique room identifier"
          field :label, :string, desc: "human facing name"
          field :display_name, :hash, of: Definition.display_name_schema,
                                      desc: "sender name template overriding the default label for this room"
          field :endpoints, :array, of: endpoint, required: true,
                                    desc: "two or more endpoints that mirror each other"
        end
      end

      def storage_schema
        Schema.define do
          field :driver, :symbol, default: :sqlite,
                                  one_of: %i[memory sqlite pg mdb mariadb mysql pstore],
                                  desc: "which storage backend to use. sqlite needs no external " \
                                        "service; pg and mdb (MariaDB, aliases mariadb/mysql) are " \
                                        "for shared or multi process deployments."
          field :url_env, :string, desc: "environment variable holding the connection URL, pg and mdb only"
          field :url, :string, desc: "connection URL, pg and mdb only. Prefer url_env so credentials stay out of the file."
          field :path, :string, desc: "file path, for the sqlite and pstore drivers"
          field :max_connections, :integer, default: 4
          field :auto_migrate, :boolean, default: true,
                                         desc: "create or update the schema at boot"
        end
      end

      # One person, with their identities on every platform they use.
      def operator_schema
        Schema.define do
          field :name, :string, required: true, desc: "human label, shown in logs and result summaries"
          field :identities, :hash, required: true,
                                    desc: "adapter name to a list of native user ids, " \
                                          "for example {telegram: [\"55\"], discord: [\"900\"]}"
          field :actions, :array, of: :symbol,
                          desc: "moderation actions this person may perform. Omit for all."
          field :rooms, :array, of: :string,
                        desc: "rooms this person may act in. Omit for all."
        end
      end

      # The identity map for mention resolution, shared with the operator list.
      # Separate from `operators:`, which grants moderation.
      def person_schema
        Schema.define do
          field :name, :string, required: true, desc: "human label, used in logs"
          field :identities, :hash,
                desc: "adapter name to a list of native user ids, for example " \
                      "{telegram: [\"55\"], discord: [\"900\"]}"
          field :handles, :hash,
                desc: "adapter name to a list of usernames. Telegram sends @handle " \
                      "mentions with no user id attached, so a handle is the only " \
                      "thing there is to match on."
        end
      end

      def commands_schema
        Schema.define do
          field :enabled, :boolean, default: true,
                                    desc: "commands are inert anyway unless operators are configured"
          field :prefixes, :array, of: :string, default: ["/", "!"],
                           desc: "the markers a command may start with. \"/\" is natural on " \
                                 "Telegram; \"!\" is added for Discord, where a leading \"/\" opens " \
                                 "the native slash-command UI and never reaches the bot as text. " \
                                 "Both work everywhere by default; only recognised commands are " \
                                 "consumed, so an unknown \"!word\" still relays normally."
          field :prefix, :string,
                         desc: "legacy single command marker, folded into `prefixes`. Prefer " \
                               "`prefixes`; kept so an older config keeps working."
          field :acknowledge, :boolean, default: true,
                                        desc: "report the result back to the endpoint the command came from"
          field :actions, :array, of: :symbol, default: %i[delete],
                          desc: "which actions are accepted at all"
          field :cleanup_after, :integer, default: 0,
                                          desc: "seconds to wait before a command takes effect, after " \
                                                "which the command message and its acknowledgement are " \
                                                "removed too. The acknowledgement is edited in place to " \
                                                "the outcome first, then deleted the same number of " \
                                                "seconds later. 0 disables the grace period: the command " \
                                                "acts at once and its acknowledgement persists, which is " \
                                                "the original behaviour. 15 is a sensible value."
        end
      end

      # The startup banner: one room per startup, posted directly to each of its
      # endpoints, since loop prevention would drop a relayed copy the bot authored.
      def announce_schema
        Schema.define do
          field :room, :string,
                desc: "id of the ONE room whose endpoints receive the startup banner. " \
                      "Unset means no banner is posted anywhere. Nominate a low " \
                      "traffic room: this is a diagnostic, not an announcement."
          # Without a control plane there is no per community switch to consult,
          # and that state also covers a snapshot that failed to load, where a
          # bridge announcing itself into a live room is the last thing wanted.
          field :without_control_plane, :boolean, default: false,
                desc: "post the banner when running from static config with no control " \
                      "plane. Off, because that state is usually a control plane that " \
                      "failed to come up rather than a deliberate config only deployment."
          field :detail, :symbol, default: :minimal, one_of: %i[minimal full],
                                  desc: "minimal prints service, version and commit. " \
                                        "full adds the Ruby build, hostname, kernel " \
                                        "and distribution. See the note below before " \
                                        "choosing full."
          field :suppress_window, :duration, default: 3600,
                                             desc: "do not post again within this window, so a " \
                                                   "crash looping bridge cannot spam the channel. " \
                                                   "0 disables suppression."
          field :delete_after, :integer, default: 0,
                                         desc: "seconds after which the startup banner is deleted from " \
                                               "every endpoint it was posted to, so a diagnostic does " \
                                               "not linger in the channel. 0 keeps it, which is the " \
                                               "original behaviour. Only a banner that actually posted " \
                                               "is scheduled for deletion; a suppressed one is not."
        end
      end

      def behaviour_schema
        Schema.define do
          field :message_ttl, :duration, default: 86_400,
                                         desc: "how long a message stays eligible for edit and delete propagation"
          field :relay_claim_ttl, :duration, default: 604_800,
                                             desc: "how long the record that a message was already relayed is " \
                                                   "kept. This is what stops a backfill sweep re-posting " \
                                                   "something, so it must be at least as long as the longest " \
                                                   "backfill lookback any channel is configured with"
          field :purge_interval, :duration, default: 3600,
                                            desc: "how often expired message map rows are removed, and how " \
                                                  "often ended guest sessions are reclaimed"
          field :guest_retention, :duration, default: 0,
                                             desc: "how long a guest portal session's captured messages and " \
                                                   "uploads are kept AFTER its access expires. 0, the default, " \
                                                   "reclaims them the moment the session ends, which is the " \
                                                   "documented policy: the session is the purpose. A positive " \
                                                   "value is an explicit, statable retention period, capped at " \
                                                   "one hour (ControlPlane::GuestRetention::MAX_GRACE), a " \
                                                   "privacy guarantee, not a tunable default. Revoking an " \
                                                   "invite always reclaims immediately, whatever this says." do |value, path|
            max = ControlPlane::GuestRetention::MAX_GRACE
            "#{path}: must be at most #{max} seconds (one hour), got #{value}" if value.to_i > max
          end
          field :file_store_path, :string, default: Storage::ObjectStore::DEFAULT_PATH,
                desc: "directory the sealed object store keeps bulk file bytes in, for the files " \
                      "rubotty rehosts when a platform will not take them (issue #349). MUST point " \
                      "at durable storage that survives a container being replaced: on the " \
                      "production host that is a subdirectory of the mounted disk at " \
                      "/mnt/bulk-storage, never the mount point itself, and the default here is " \
                      "container-local and fine only for development. RUBOTTY_FILE_STORE in the " \
                      "environment overrides this, so a deployment can name its own subdirectory " \
                      "without editing the file. The directory is checked at boot and refused if " \
                      "it exists without the store's own marker file, since an unmounted nofail " \
                      "volume is indistinguishable from an empty directory. To claim an existing " \
                      "directory as a new store, set RUBOTTY_FILE_STORE_INIT=1 for exactly one " \
                      "boot and then remove it; leaving it set is the same hazard the marker file " \
                      "exists to catch."
          field :gateway_cycle, :boolean, default: true,
                                          desc: "drop and re-establish every long lived gateway " \
                                                "connection once a night, so a session that has gone " \
                                                "quiet while still looking connected cannot last " \
                                                "longer than a day. On by default because nothing " \
                                                "detects that state. Adapters that poll, Telegram " \
                                                "among them, are never cycled. Backfill picks up " \
                                                "whatever the reconnect drops, on the channels where " \
                                                "it is enabled."
          field :gateway_cycle_at, :string, default: Core::GatewayCycle::DEFAULT_AT,
                                            desc: "when that reconnect happens, HH:MM in UTC. Always " \
                                                  "UTC: neither the container's TZ nor the database's " \
                                                  "timezone moves it." do |value, path|
            unless value.to_s.match?(Core::GatewayCycle::TIME_OF_DAY)
              "#{path}: must be HH:MM in UTC, got #{value.inspect}"
            end
          end
          field :quiet_gateway_watchdog, :boolean, default: true,
                                                    desc: "notice a receiving endpoint whose own " \
                                                          "connection has stopped delivering while " \
                                                          "its room siblings keep moving, and log it " \
                                                          "loudly. With gateway_cycle also on, the " \
                                                          "stalled adapter is reconnected out of band " \
                                                          "instead of waiting for the nightly cycle. " \
                                                          "On by default because nothing else detects " \
                                                          "that state; gateway_cycle only caps how " \
                                                          "long it can last."
          field :quiet_gateway_threshold, :duration, default: Core::QuietGatewayWatchdog::DEFAULT_THRESHOLD,
                desc: "how long a receiving endpoint may deliver nothing of its own before it " \
                      "becomes a stall candidate. Only acted on once a room sibling on a " \
                      "DIFFERENT connection proves the room is alive in that same window, so a " \
                      "quiet channel at 4am with nobody talking anywhere near it is never flagged."
          field :quiet_gateway_interval, :duration, default: Core::QuietGatewayWatchdog::DEFAULT_INTERVAL,
                                                     desc: "how often the quiet gateway watchdog checks"
          field :deploy_head_url, :string,
                desc: "a URL answering with the head commit of the default branch, so the " \
                      "dashboard header can say when a merge never actually deployed. It may " \
                      "answer with a bare sha (a file a CI job publishes) or with GitHub's " \
                      "commit JSON, and the Accept header asks GitHub for the bare form. Unset, " \
                      "the default, means no comparison is made and the header shows nothing. " \
                      "A check that cannot be reached is silent rather than alarming."
          field :deploy_head_token_env, :string,
                desc: "name of the environment variable holding a bearer token for " \
                      "deploy_head_url, for a private repository read over the GitHub API. " \
                      "Unset sends no credential, which is what a CI-published sha needs."
          field :deploy_drift_grace, :duration, default: Core::DeployDrift::DEFAULT_GRACE,
                desc: "how long the running commit and the head of the default branch may " \
                      "differ before the header says so. A deploy takes several minutes, so a " \
                      "shorter window warns on every merge on its way out. The same window " \
                      "covers a version difference between the bot and web processes, which " \
                      "deploy separately."
          field :queue_limit, :integer, default: 1000,
                                        desc: "per room backlog before the oldest message is dropped"
          field :skip_backlog, :boolean, default: true,
                                         desc: "ignore messages that arrived while the bridge was down"
    field :log_level, :symbol, default: :info, one_of: %i[debug info warn error fatal]
    field :reply_preview_chars, :integer, default: 100,
                                          desc: "how much of a quoted parent message to show " \
                                                "when a native reply is impossible. 0 disables " \
                                                "quoting entirely."
    field :reply_preview_lines, :integer, default: 2,
                                          desc: "how many lines of a quoted parent to show"
    field :delivery_attempts, :integer, default: 3,
                                        desc: "how many times to try a failed delivery"
    field :suppress_delivery_notices, :boolean, default: false,
                                                desc: "stay silent when part of a message could not " \
                                                      "be relayed, such as a file over the size " \
                                                      "limit. Replaces suppressFileTooBigMessages."
  end
end

      # The whole file. Adapter specific blocks are validated separately, in
      # {Loader}, once the adapter each entry names is known.
      def root_schema
        Schema.define do
          field :version, :integer, default: 1, one_of: [1],
                                    desc: "config format version, for future migrations"
          field :name, :string, default: "rubotty", desc: "service name, used in logs"
          # Not required: a database-only deployment carries no bridge.config.yaml
          # at all, or one with nothing under either key, and gets its accounts and
          # rooms from the control plane instead.
          field :accounts, :hash, default: {},
                                  desc: "credentialed connections, keyed by name. Empty, or absent " \
                                        "along with the whole file, when accounts live in the " \
                                        "control-plane database instead"
          field :rooms, :array, of: Definition.room_schema, default: [],
                                desc: "the bridging topology. Empty, or absent along with the whole " \
                                      "file, when rooms live in the control-plane database instead"
          field :storage, :hash, of: Definition.storage_schema, default: {}
          field :behaviour, :hash, of: Definition.behaviour_schema, default: {}
          field :display_name, :hash, of: Definition.display_name_schema, default: {},
                                      desc: "sender name template overriding the default structured label globally"
          field :operators, :array, of: Definition.operator_schema, default: [],
                                    desc: "people permitted to issue moderation commands"
          field :commands, :hash, of: Definition.commands_schema, default: {},
                                  desc: "moderation command handling"
          field :announce, :hash, of: Definition.announce_schema, default: {},
                                  desc: "startup banner: one room, posted to all of its endpoints"
          field :people, :array, of: Definition.person_schema, default: [],
                                 desc: "identity map, so a mention on one platform pings the " \
                                       "same person on another"
        end
      end
    end
  end
end
