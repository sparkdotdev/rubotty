# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Create, edit, list and remove a community's IRC networks, one row per
    # network. A per_room network (the default) joins one channel per bridged
    # room; a hub network mirrors every room into the single hub_channel
    # instead, which {#validated} requires for hub and clears for per_room.
    # {#live} resolves each row into a live {Config::Account} but never
    # consults the channels array, so a saved network reaches the server but
    # joins nothing on its own.
    class IrcNetworks
      # Raised for a request that cannot be carried out (a blank name, a hub
      # network with no usable hub_channel, a duplicate name). Carries a human
      # message a caller prints as-is.
      class Invalid < Rubotty::Error; end

      # The two bridging modes irc_networks.mode accepts. Plain strings on the
      # row, for cross-backend portability.
      MODES = %w[per_room hub].freeze

      # DB column size limits (migrations 013, 019), enforced here because SQLite
      # would silently accept an overlong value and Postgres would refuse it.
      NAME_MAX = 64
      HOST_MAX = 255
      NICK_MAX = 128
      SASL_USER_MAX = 128
      SASL_PASSWORD_ENV_MAX = 128
      HUB_CHANNEL_MAX = 255

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # The {Config::Schema} one network's submitted fields are validated and
      # coerced through. Rebuilt per call rather than memoised, so there is no
      # shared schema object a caller could accidentally mutate.
      def self.schema
        Config::Schema.define do
          field :name, :string, required: true,
                                desc: "a short, community-chosen handle for this network, e.g. 'libera', " \
                                      "'oftc'. Referenced by onboarding and the dashboard; not the same as " \
                                      "the wire hostname"
          field :host, :string, required: true, desc: "the network's wire hostname"
          field :port, :integer, default: 6697
          field :tls, :boolean, default: true
          field :nick, :string, required: true
          field :sasl_user, :string,
                            desc: "SASL account name (PLAIN mechanism). Often the same as nick, but not always"
          field :sasl_password_env, :string, env: true,
                                             desc: "name of the environment variable holding the SASL " \
                                                   "password. Never the raw password itself"
          field :channels, :array, of: :string, default: [],
                                   desc: "channel names to join on connect, e.g. ['#general', '#offtopic']"
          field :mode, :symbol, default: :per_room, one_of: MODES.map(&:to_sym),
                                desc: "'per_room' joins one IRC channel per bridged room, the standard 1:1 " \
                                      "mapping. 'hub' mirrors every bridged room into hub_channel instead"
          field :hub_channel, :string,
                              desc: "required, and only used, when mode is 'hub'; a per_room network joins a " \
                                    "channel per room instead"
          field :channel_keys, :hash, default: {},
                                      desc: "maps a channel name to the NAME of the environment variable " \
                                            "holding that channel's +k key. Never the raw key itself"
        end
      end

      # Every IRC network for a community, alphabetically by name.
      def list(community:)
        @models.irc_network.where(community_id: community.id).order(:name).all
      end

      # Add a new IRC network to a community.
      #
      # @param mode [String, Symbol, nil] "per_room" or "hub"; hub_channel is
      #   required for hub, ignored (cleared) for per_room
      # @param channel_keys [Hash, nil] channel name => env var name holding
      #   that channel's +k key
      # @return [Models::IrcNetwork]
      def create(community:, name:, host:, port:, tls:, nick:, sasl_user:, sasl_password_env:, channels:, mode:,
                 hub_channel:, channel_keys:)
        attrs = validated(name: name, host: host, port: port, tls: tls, nick: nick, sasl_user: sasl_user,
                           sasl_password_env: sasl_password_env, channels: channels, mode: mode,
                           hub_channel: hub_channel, channel_keys: channel_keys)
        now = @clock.call
        row = @models.irc_network.create(community_id: community.id, created_at: now, updated_at: now, **attrs)
        @logger&.info do
          "irc network created: community=#{community.slug} name=#{attrs[:name].inspect} mode=#{attrs[:mode]}"
        end
        row
      rescue Sequel::UniqueConstraintViolation
        raise Invalid, "an IRC network named #{name.to_s.inspect} already exists for #{community.slug}."
      end

      # Edit an existing IRC network's connection, SASL, channel and mode settings.
      #
      # @param network [Models::IrcNetwork]
      # @return [Models::IrcNetwork]
      def update(network:, name:, host:, port:, tls:, nick:, sasl_user:, sasl_password_env:, channels:, mode:,
                 hub_channel:, channel_keys:)
        attrs = validated(name: name, host: host, port: port, tls: tls, nick: nick, sasl_user: sasl_user,
                           sasl_password_env: sasl_password_env, channels: channels, mode: mode,
                           hub_channel: hub_channel, channel_keys: channel_keys)
        network.update(updated_at: @clock.call, **attrs)
        @logger&.info do
          "irc network updated: id=#{network.id} name=#{attrs[:name].inspect} mode=#{attrs[:mode]}"
        end
        network
      rescue Sequel::UniqueConstraintViolation
        raise Invalid, "an IRC network named #{name.to_s.inspect} already exists for this community."
      end

      # Remove an IRC network by id, scoped to a community (so a caller
      # cannot remove another community's row by guessing an id).
      #
      # @return [Boolean] whether a row was actually removed
      def remove(community:, id:)
        network = @models.irc_network.where(community_id: community.id, id: id).first
        return false if network.nil?

        network.destroy
        @logger&.info { "irc network removed: id=#{id}" }
        true
      end

      # Every irc_networks row, across every community, resolved into a live
      # {Config::Account} through the same adapter schema and env resolution a
      # YAML account gets. A row that fails to resolve is logged and skipped,
      # so one bad network costs only that gateway.
      #
      # @param env [Hash] environment to resolve *_env fields against
      # @return [Array<Config::Account>]
      def live(env: ENV)
        @models.irc_network.order(:community_id, :name).all.filter_map do |row|
          account, problems = resolve(row, env: env)
          if account.nil? || problems.any?
            @logger&.warn { "irc network #{row.community.slug}/#{row.name}: skipped, #{problems.join("; ")}" }
            next
          end
          account
        end
      end

      # One stored network row as a {Config::Account} for the irc adapter.
      #
      # @return [Array(Config::Account, nil, Array<String>)]
      def resolve(row, env: ENV)
        body = {
          "adapter" => "irc", "server" => row.host, "port" => row.port, "tls" => row.tls, "nick" => row.nick,
          "sasl_user" => row.sasl_user, "sasl_password_env" => row.sasl_password_env, "mode" => row.mode,
          "hub_channel" => row.hub_channel
        }
        name = account_name_for(row)
        accounts, problems = Config::Loader.accounts_from(
          { name => body }, env: env, source: "irc_networks (database)"
        )
        [accounts[name], problems]
      end

      private

      # A network's own name is unique only WITHIN its community
      # (irc_networks_name_idx); {Config::Model#active_accounts} needs one
      # flat, globally unique namespace, so the account name carries both.
      def account_name_for(row)
        "irc_network:#{row.community.slug}:#{row.name}"
      end

      # Validate and coerce one network's submitted fields, raising {Invalid}
      # with every problem found in one pass, matching {Config::Loader}.
      #
      # @return [Hash] the DB-ready attrs: name, host, port, tls, nick,
      #   sasl_user, sasl_password_env, channels (JSON), mode (String),
      #   hub_channel, channel_keys (JSON)
      def validated(name:, host:, port:, tls:, nick:, sasl_user:, sasl_password_env:, channels:, mode:,
                    hub_channel:, channel_keys:)
        result = self.class.schema.call(
          { name: name, host: host, port: port, tls: tls, nick: nick, sasl_user: sasl_user,
            sasl_password_env: sasl_password_env, channels: channels, mode: mode, hub_channel: hub_channel,
            channel_keys: channel_keys },
          path: "irc_network"
        )
        value = result.value || {}
        problems = result.problems.dup

        # Config::Schema's `required` check only catches an ABSENT or nil field; a
        # form submits a present but blank string for an empty input, which needs
        # its own check, guarded so it is never reported as "required" twice.
        if value.key?(:name) && value[:name].to_s.strip.empty?
          problems << "irc_network.name: is required"
        end
        if value.key?(:host) && value[:host].to_s.strip.empty?
          problems << "irc_network.host: is required"
        end
        if value.key?(:nick) && value[:nick].to_s.strip.empty?
          problems << "irc_network.nick: is required"
        end

        if value[:mode] == :hub
          if value[:hub_channel].to_s.strip.empty?
            problems << "irc_network.hub_channel: a hub network needs a channel to mirror every bridged room " \
                        "into"
          end
        else
          # A per_room network joins a channel per bridged room: drop any
          # hub_channel submitted alongside it rather than keep stale data.
          value[:hub_channel] = nil
        end

        raise Invalid, problems.join("; ") if problems.any?

        {
          name: value[:name].to_s.strip[0, NAME_MAX],
          host: value[:host].to_s.strip[0, HOST_MAX],
          port: value[:port],
          tls: value[:tls],
          nick: value[:nick].to_s.strip[0, NICK_MAX],
          sasl_user: value[:sasl_user]&.strip&.slice(0, SASL_USER_MAX),
          sasl_password_env: value[:sasl_password_env]&.strip&.slice(0, SASL_PASSWORD_ENV_MAX),
          channels: Models.dump_json(value[:channels] || []),
          mode: value[:mode].to_s,
          hub_channel: value[:hub_channel]&.strip&.slice(0, HUB_CHANNEL_MAX),
          channel_keys: Models.dump_json(value[:channel_keys] || {})
        }
      end
    end
  end
end
