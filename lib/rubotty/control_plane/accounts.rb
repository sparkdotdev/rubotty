# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # CRUD over the deployment's credentialed gateway accounts, plus the read side
    # that turns a stored row back into a live {Config::Account}.
    #
    # Accounts are GLOBAL: one bot token serves every community at once, so there
    # is no `community:` keyword here and adding one would be a modelling error.
    # A row stores token_env, never a resolved token; {#storable} guarantees that.
    class Accounts
      # Raised for a request that cannot be carried out. Carries a human message a
      # dashboard flash prints as-is.
      class Invalid < Rubotty::Error; end

      # accounts.source: where a row came from. Nothing branches on it.
      SOURCE_YAML = "yaml_seed"
      SOURCE_DASHBOARD = "dashboard"

      # Column size limits, enforced here because SQLite would silently accept an
      # overlong value where Postgres refuses it.
      NAME_MAX = 64
      ADAPTER_MAX = 32

      # An account name is a routing key: stored verbatim and compared for equality
      # on every inbound event, so whitespace is refused. Otherwise loose, so every
      # name an existing bridge.config.yaml uses imports cleanly.
      NAME_PATTERN = /\A\S+\z/

      # Registered adapters that are not credentialed gateways: the guest portal
      # only. A method rather than a constant because adapters are required after
      # this file.
      def self.not_gateways = [Adapters::Guest::NAME]

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # The target adapter's own {Config::Schema}. Raises {Invalid} for an
      # unregistered adapter.
      #
      # @param adapter [String, Symbol]
      # @return [Config::Schema]
      def self.schema_for(adapter)
        adapter_class_for(adapter).account_schema
      end

      # @param adapter [String, Symbol]
      # @return [Class<Adapters::Base>]
      def self.adapter_class_for(adapter)
        raise Invalid, "#{adapter} is not a credentialed gateway" if not_gateways.include?(adapter.to_s.to_sym)

        Adapters::Registry.fetch(adapter)
      rescue UnknownAdapterError => e
        raise Invalid, e.problems.first
      end

      # Every adapter an account may be created for, from the registry.
      def self.adapter_names = Adapters::Registry.names - not_gateways

      # Every stored account, grouped platform by platform.
      def list
        @models.account.order(:adapter, :name).all
      end

      # One stored account by id, or nil.
      def find(id:)
        @models.account.where(id: id).first
      end

      # @param adapter [String, Symbol] a registered adapter name
      # @param name [String] the account's name key, e.g. "telegram_2"
      # @param settings [Hash] the adapter's own account_schema fields,
      #   token_env included. Never a raw secret.
      # @param source [String] {SOURCE_DASHBOARD} or {SOURCE_YAML}
      # @return [Models::Account]
      def create(adapter:, name:, settings:, source: SOURCE_DASHBOARD)
        attrs = validated(adapter: adapter, name: name, settings: settings)
        now = @clock.call
        row = @models.account.create(source: source.to_s, created_at: now, updated_at: now, **attrs)
        @logger&.info { "account created: #{attrs[:adapter]}/#{attrs[:name]} source=#{source}" }
        row
      rescue Sequel::UniqueConstraintViolation
        raise Invalid, "an account named #{name.to_s.inspect} already exists for #{adapter}."
      end

      # Edits an existing account's settings; the (adapter, name) identity
      # is not editable, since platform_connections.account and
      # channels.account carry it and a rename would silently orphan every
      # mapped channel. Remove and recreate instead.
      #
      # @param account [Models::Account]
      # @param settings [Hash]
      # @return [Models::Account]
      def update(account:, settings:)
        attrs = validated(adapter: account.adapter, name: account.name, settings: settings)
        account.update(settings: attrs[:settings], updated_at: @clock.call)
        @logger&.info { "account updated: #{account.adapter}/#{account.name}" }
        account
      end

      # @return [Boolean] whether a row was actually removed
      def remove(id:)
        row = find(id: id)
        return false if row.nil?

        row.destroy
        @logger&.info { "account removed: #{row.adapter}/#{row.name}" }
        true
      end

      # Import every account the boot-time YAML declares, for any (adapter, name)
      # with no row yet. Additive and never destructive, so it is safe on every
      # boot: an existing row is left alone and the database wins.
      #
      # @param config [Config::Model]
      # @return [Array<Models::Account>] the rows actually created
      def seed_from_config(config)
        config.active_accounts.filter_map do |account|
          next if exists?(adapter: account.adapter_name, name: account.name)

          seed_one(account)
        end
      end

      # Whether a row already exists for this gateway.
      def exists?(adapter:, name:)
        !@models.account.where(adapter: adapter.to_s, name: name.to_s).empty?
      end

      # Every stored account name for one adapter, for a caller that wants the
      # names alone and no env resolution.
      def names_for(adapter:)
        @models.account.where(adapter: adapter.to_s).order(:name).all.map(&:name)
      end

      # One stored account by its (adapter, name) identity, as a live
      # {Config::Account}; nil when no row matches. The single-row counterpart
      # to {#live}, for a caller holding an identity rather than a list.
      def resolved(adapter:, name:, env: ENV)
        row = @models.account.where(adapter: adapter.to_s, name: name.to_s).first
        return nil if row.nil?

        resolve(row, env: env).first
      end

      # Every stored account resolved into live {Config::Account} objects, for the
      # same construction loop a YAML account goes through. A row that fails to
      # resolve is logged and skipped, so one bad row costs only that gateway.
      #
      # @param env [Hash] environment to resolve token_env against
      # @return [Array<Config::Account>]
      def live(env: ENV)
        list.filter_map do |row|
          account, problems = resolve(row, env: env)
          if account.nil? || problems.any?
            @logger&.warn { "account #{row.adapter}/#{row.name}: skipped, #{problems.join("; ")}" }
            next
          end
          account
        end
      end

      # One stored row as a {Config::Account}, through the same validation, env
      # resolution and dormancy rules a YAML entry gets.
      #
      # @return [Array(Config::Account, nil, Array<String>)]
      def resolve(row, env: ENV)
        body = row.json_value(:settings).merge("adapter" => row.adapter)
        accounts, problems = Config::Loader.accounts_from(
          { row.name => body }, env: env, source: "accounts (database)"
        )
        [accounts[row.name], problems]
      end

      private

      # Validate and coerce one account's submitted fields, raising {Invalid} with
      # every problem found rather than only the first.
      #
      # @return [Hash] the DB-ready attrs: adapter, name, settings (JSON)
      def validated(adapter:, name:, settings:)
        adapter_name = adapter.to_s.strip
        account_name = name.to_s.strip
        problems = []
        problems << "account.adapter: is required" if adapter_name.empty?
        if account_name.empty?
          problems << "account.name: is required"
        elsif !NAME_PATTERN.match?(account_name)
          problems << "account.name: must not contain whitespace, got #{account_name.inspect}"
        elsif account_name.length > NAME_MAX
          problems << "account.name: must be at most #{NAME_MAX} characters"
        end
        raise Invalid, problems.join("; ") if problems.any?

        adapter_class = self.class.adapter_class_for(adapter_name)
        result = adapter_class.account_schema.call(symbolize(settings), path: "account")
        problems = result.problems + adapter_class.validate_account(result.value || {}, "account")
        raise Invalid, problems.join("; ") if problems.any?

        {
          adapter: adapter_name[0, ADAPTER_MAX],
          name: account_name[0, NAME_MAX],
          settings: Models.dump_json(storable(adapter_class, result.value || {}))
        }
      end

      # Import one already-loaded YAML account. Its settings arrive resolved
      # (token_env has become token), so {#storable}'s secret-dropping is load
      # bearing here: skipping it would persist a live secret.
      def seed_one(account)
        create(
          adapter: account.adapter_name, name: account.name,
          settings: storable(account.adapter_class, account.settings),
          source: SOURCE_YAML
        )
      rescue Invalid => e
        # A YAML account this rejects must never take down a boot.
        @logger&.warn { "account #{account.adapter_name}/#{account.name}: not imported, #{e.message}" }
        nil
      rescue Sequel::UniqueConstraintViolation
        # Two processes booting at once both passed #exists?; the other won.
        nil
      end

      # The subset of a settings hash that is safe and useful to persist. Only keys
      # the adapter's account_schema declares survive, which is the secret guarantee
      # (a resolved `token` is dropped); so is a value equal to the schema default.
      def storable(adapter_class, settings)
        fields = adapter_class.account_schema.fields
        settings.each_with_object({}) do |(key, value), out|
          field = fields[key.to_sym]
          next if field.nil? || value.nil?
          next if !field.default.nil? && value == field.default

          out[key.to_s] = value
        end
      end

      def symbolize(hash)
        (hash || {}).each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end
    end
  end
end
