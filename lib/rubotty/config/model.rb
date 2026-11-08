# frozen_string_literal: true

module Rubotty
  module Config
    # The validated configuration, in the shape the rest of the system wants.
    # Every value has been coerced to a Ruby type, every secret resolved and every
    # reference checked, so nothing downstream reads YAML or touches ENV.
    class Model
      # The fallback when `behaviour.relay_claim_ttl` is unset, named so a caller
      # that needs "the deployment default" (rather than a live config) has one
      # place to read it from instead of restating 604_800.
      DEFAULT_RELAY_CLAIM_TTL = 604_800

      # The fallback when `announce.delete_after` is unset. Long enough for an
      # operator to read the banner, short enough that a restart loop does not
      # leave a wall of them behind.
      DEFAULT_ANNOUNCE_DELETE_AFTER = 300

      attr_reader :name, :accounts, :topology, :storage, :behaviour, :display_name,
                  :operators, :commands, :announce, :people, :source

      def initialize(name:, accounts:, topology:, storage:, behaviour:, display_name:,
                     source:, operators: nil, commands: {}, announce: {}, people: nil,
                     name_declared: true)
        @name = name
        @name_declared = name_declared
        @accounts = accounts.freeze
        @topology = topology
        @storage = storage.freeze
        @behaviour = behaviour.freeze
        @display_name = display_name
        @operators = operators || Core::Moderation::Directory.new
        @commands = commands.freeze
        @announce = announce.freeze
        @people = people || Core::Directory.new
        @source = source
        freeze
      end

      # Whether the configuration actually wrote a `name:`, rather than the
      # schema materialising its default. The control plane reconciles the
      # seeded community's display name from this file on every boot, which
      # must not happen for a file that never named one: "rubotty" would then
      # overwrite whatever the dashboard set.
      def name_declared? = @name_declared

      def rooms = topology.rooms

      def endpoints = topology.endpoints

      def message_ttl = behaviour.fetch(:message_ttl, 86_400)

      # Deliberately separate from message_ttl: that one bounds edit and delete
      # propagation, this one bounds how far back a backfill sweep can safely reach.
      def relay_claim_ttl = behaviour.fetch(:relay_claim_ttl, DEFAULT_RELAY_CLAIM_TTL)

      def purge_interval = behaviour.fetch(:purge_interval, 3600)

      # Seconds a guest portal session's captured messages and uploads are kept
      # after its access expires. 0 reclaims them at expiry.
      def guest_retention = behaviour.fetch(:guest_retention, 0)

      # Where the sealed object store keeps bulk file bytes. RUBOTTY_FILE_STORE
      # overrides the configured value.
      def file_store_path = Storage::ObjectStore.path_from(behaviour[:file_store_path])

      # Whether long lived gateway connections are dropped and re-established
      # nightly, and at what time of day in UTC.
      def gateway_cycle? = behaviour.fetch(:gateway_cycle, true)

      def gateway_cycle_at = behaviour.fetch(:gateway_cycle_at, Core::GatewayCycle::DEFAULT_AT)

      # Whether a receiving endpoint whose room siblings keep moving while it
      # delivers nothing is noticed and acted on.
      def quiet_gateway_watchdog? = behaviour.fetch(:quiet_gateway_watchdog, true)

      def quiet_gateway_threshold
        behaviour.fetch(:quiet_gateway_threshold, Core::QuietGatewayWatchdog::DEFAULT_THRESHOLD)
      end

      def quiet_gateway_interval
        behaviour.fetch(:quiet_gateway_interval, Core::QuietGatewayWatchdog::DEFAULT_INTERVAL)
      end

      # Where to read the head commit of the default branch, and the name of the
      # environment variable holding a bearer token for it. Both nil by default,
      # which leaves the dashboard header's drift check off.
      def deploy_head_url = presence(behaviour[:deploy_head_url])

      def deploy_head_token_env = presence(behaviour[:deploy_head_token_env])

      # Seconds the running commit may differ from that head, and the bot's
      # version from the web process's, before either is reported.
      def deploy_drift_grace
        behaviour.fetch(:deploy_drift_grace, Core::DeployDrift::DEFAULT_GRACE)
      end

      def queue_limit = behaviour.fetch(:queue_limit, 1000)

      def skip_backlog? = behaviour.fetch(:skip_backlog, true)

      def log_level = behaviour.fetch(:log_level, :info)

      def reply_preview_chars = behaviour.fetch(:reply_preview_chars, 100)

      def reply_preview_lines = behaviour.fetch(:reply_preview_lines, 2)

      def delivery_attempts = behaviour.fetch(:delivery_attempts, 3)

      def suppress_delivery_notices? = behaviour.fetch(:suppress_delivery_notices, false)

      def moderation_enabled? = !operators.empty? && commands.fetch(:enabled, true)

      # The markers a command may begin with: the `prefixes` list, with the legacy
      # singular `prefix` folded in, falling back to `["/", "!"]`.
      def command_prefixes = Core::CommandPrefix.from_config(commands)

      # Seconds to wait before a moderation command takes effect and its command
      # message and acknowledgement are cleaned up. 0 disables the grace period.
      def command_cleanup_after
        return 0 unless moderation_enabled?

        commands.fetch(:cleanup_after, 0).to_i
      end

      # Whether moderation commands acknowledge back to the issuing endpoint.
      def command_acknowledge? = moderation_enabled? && commands.fetch(:acknowledge, true)

      # The banner is off unless a room was nominated.
      def announce_room = announce[:room]

      def announce? = !announce_room.nil?

      def announce_detail = announce.fetch(:detail, :minimal)

      def announce_without_control_plane? = announce.fetch(:without_control_plane, false) == true

      def announce_suppress_window = announce.fetch(:suppress_window, 3600)

      # Seconds after which the startup banner is deleted from every endpoint it
      # was posted to. An explicit 0 keeps the banner; the default deletes it,
      # because an omitted value used to mean "keep forever" and filled rooms
      # and DM histories with every restart on a deployment carrying no file.
      def announce_delete_after = announce.fetch(:delete_after, DEFAULT_ANNOUNCE_DELETE_AFTER).to_i

      def storage_driver = storage.fetch(:driver, :sqlite)

      # Every declared account, whether or not an endpoint currently maps to it. A
      # zero-endpoint account still connects, so its channel-discovery seam can run,
      # and relays nothing because {#endpoints_for} hands it an empty list.
      def active_accounts
        accounts.values
      end

      # Endpoints belonging to one account, for handing to that adapter.
      def endpoints_for(account_name)
        topology.endpoints.select { |e| e.account == account_name }
      end

      # @param topology [#rooms, #endpoints] defaults to this config's own
      #   static topology; a caller reporting against the live control-plane
      #   snapshot instead (Core::LiveTopology) passes that here rather than
      #   reading a static topology that is empty by design.
      def summary(topology: self.topology)
        lines = ["#{name}: #{topology.rooms.size} room(s), #{topology.endpoints.size} endpoint(s)"]
        topology.rooms.each do |room|
          lines << "  #{room.label}: #{room.endpoints.map { |e| "#{e.id}(#{e.adapter_name})" }.join(" <-> ")}"
        end
        lines.join("\n")
      end

      private

      # A key written as an empty string reads the same as an absent one.
      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
