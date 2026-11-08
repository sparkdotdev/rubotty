# frozen_string_literal: true

require "yamlcamel"

module Rubotty
  module Config
    # Reads, validates and assembles the YAML configuration. Every pass collects
    # problems rather than raising, so an operator fixing a config needs one run.
    class Loader
      # Suffix marking a field whose value is the NAME of an environment
      # variable: `<thing>_env` resolves into `<thing>`.
      ENV_SUFFIX = "_env"

      class << self
        # A missing file reads the same as an empty one: no accounts, no rooms,
        # both valid since the control plane can hold them instead. A file
        # that exists but fails to parse or fails validation still raises.
        #
        # @param path [String]
        # @param env [Hash] environment to resolve secrets from
        # @return [Model]
        # @raise [ConfigError]
        def load_file(path, env: ENV)
          yaml = File.file?(path) ? File.read(path) : ""
          new(yaml, source: path, env: env).load
        end

        def load_string(yaml, source: "(string)", env: ENV)
          new(yaml, source: source, env: env).load
        end

        # CLI and Rack startup both allow configuration held entirely in the
        # database, but must make an absent static configuration visible.
        def load_for_boot(path, env: ENV, err: $stderr)
          if path.to_s.strip.empty?
            err.puts "No configuration given; " \
                     "starting with accounts and topology from the database alone."
            return load_string("", source: "(no configuration given)", env: env)
          end

          unless File.file?(path)
            err.puts "Configuration file #{path.inspect} is missing or is not a regular file; " \
                     "starting with accounts and topology from the database alone."
          end
          load_file(path, env: env)
        end

        # Build {Account} objects from an `accounts:`-shaped mapping that did not
        # come from YAML, such as the control plane's accounts table.
        #
        # @param raw [Hash] name => body, where body carries `adapter:` and the
        #   adapter's own account_schema keys, exactly as YAML would
        # @return [Array(Hash{String=>Account}, Array<String>)] the accounts, and
        #   every problem found, reported rather than raised
        def accounts_from(raw, env: ENV, source: "(accounts)")
          new("", source: source, env: env).load_accounts(raw)
        end
      end

      # @see .accounts_from
      # @return [Array(Hash{String=>Account}, Array<String>)]
      def load_accounts(raw)
        accounts = build_accounts(raw)
        [accounts, prefixed(@problems)]
      end

      def initialize(yaml, source: "(string)", env: ENV)
        @yaml = yaml
        @source = source
        @env = env
        @problems = []
      end

      def load
        raw = parse
        root = Definition.root_schema.call(raw, path: "")
        @problems.concat(root.problems)
        raise ConfigError, prefixed(@problems) if @problems.any?

        data = root.value
        accounts = build_accounts(data[:accounts])
        rooms = build_rooms(data[:rooms], accounts)
        check_topology(rooms)
        # Built before the raise, so problems here are reported alongside the rest.
        operators = build_operators(data[:operators], rooms)
        check_announce(data[:announce], rooms)
        people = build_people(data[:people], operators)

        raise ConfigError, prefixed(@problems) if @problems.any?

        Model.new(
          name: data[:name],
          name_declared: name_declared?(raw),
          accounts: accounts,
          topology: Core::Topology.new(rooms),
          storage: data[:storage] || {},
          behaviour: data[:behaviour] || {},
          display_name: build_display_name(data[:display_name]),
          operators: operators,
          commands: data[:commands] || {},
          announce: data[:announce] || {},
          people: people,
          source: @source
        )
      end

      private

      # Whether the parsed file actually named the service, which the schema's
      # own default cannot be told apart from once it has been materialised.
      def name_declared?(raw)
        return false unless raw.is_a?(Hash)

        raw.any? { |key, value| key.to_s == "name" && !value.to_s.strip.empty? }
      end

      def parse
        # Aliases carry a repeated relay policy across endpoints and are read as
        # written. Only core schema types are ever built, so config cannot name a
        # class to instantiate.
        YAMLCamel.load(@yaml)
      rescue YAMLCamel::Error => e
        # The message already carries the line, so the file name is all this adds.
        raise ConfigError, ["#{@source}: #{e.message}"]
      end

      ACCOUNT_CORE = Schema.define do
        field :adapter, :symbol, required: true, desc: "which platform this account is for"
      end.allow_unknown!

      def build_accounts(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(name, body), out|
          path = "accounts.#{name}"
          core = ACCOUNT_CORE.call(body, path: path)
          @problems.concat(core.problems)
          next if core.problems.any?

          adapter_class = resolve_adapter(core.value[:adapter], path)
          next if adapter_class.nil?

          rest = core.value.reject { |key, _| key == :adapter }
          settings = adapter_class.account_schema.call(rest, path: path)
          @problems.concat(settings.problems)
          next if settings.problems.any?

          resolved, missing = resolve_env(
            adapter_class.account_schema, settings.value, path,
            dormant_ok: adapter_class.dormant_on_missing_secret?
          )
          # Non-secret problems (a bad webhook_url, an unknown transport) still
          # raise even when the secret is missing; only a missing key is graceful.
          @problems.concat(adapter_class.validate_account(resolved, path))

          out[name.to_s] = Account.new(
            name: name.to_s,
            adapter_name: core.value[:adapter],
            adapter_class: adapter_class,
            settings: resolved,
            dormant_reason: missing.empty? ? nil : "waiting for key (#{missing.join(", ")} not set)"
          )
        end
      end

      def build_rooms(raw, accounts)
        Array(raw).each_with_index.map do |room, index|
          path = "rooms[#{index}]"
          endpoints = build_endpoints(room[:endpoints], accounts, "#{path}.endpoints")

          if endpoints.empty?
            @problems << "#{path}: a room needs at least one endpoint, found 0"
          end

          naming = room[:display_name] || {}
          Core::Room.new(
            id: room[:id],
            label: room[:label],
            endpoints: endpoints,
            display_name_template: naming[:format],
            display_name_fallback: naming[:fallback_format]
          )
        end
      end

      def build_endpoints(raw, accounts, base_path)
        Array(raw).each_with_index.filter_map do |entry, index|
          path = "#{base_path}[#{index}]"
          core = Definition.endpoint_core_schema.call(entry, path: path)
          @problems.concat(core.problems)
          next nil if core.problems.any?

          values = core.value
          adapter_class = resolve_adapter(values[:adapter], path)
          next nil if adapter_class.nil?

          # Guest endpoints are synthesised by SnapshotBuilder from a room's own
          # guest-access setting, never read from YAML; the config loader has no
          # room id or community id to give one, which is exactly what its
          # required-nothing schema would otherwise let through silently.
          if values[:adapter] == Adapters::Guest::NAME
            @problems << "#{path}.adapter: guest endpoints are created automatically and cannot be " \
                         "declared in configuration"
            next nil
          end

          account = accounts[values[:account]]
          if account.nil?
            @problems << "#{path}.account: no account named #{values[:account].inspect} is defined. " \
                         "Defined accounts: #{accounts.keys.join(", ")}"
            next nil
          elsif account.adapter_name != values[:adapter]
            @problems << "#{path}: endpoint uses adapter #{values[:adapter]} but account " \
                         "#{values[:account].inspect} is for #{account.adapter_name}"
            next nil
          end

          settings = adapter_settings(adapter_class, entry, path)
          next nil if settings.nil?

          naming = values[:display_name] || {}
          Core::Endpoint.new(
            id: values[:id],
            adapter_name: values[:adapter],
            account: values[:account],
            settings: settings,
            receives: values[:receive],
            sends: values[:send],
            relay: values[:relay] || {},
            display_name_template: naming[:format],
            display_name_fallback: naming[:fallback_format],
            label: values[:label]
          )
        end
      end

      # Extract the keys the adapter owns and validate them against its schema.
      def adapter_settings(adapter_class, entry, path)
        core_keys = Definition.endpoint_core_schema.fields.keys
        adapter_part = entry.each_with_object({}) do |(key, value), out|
          symbol = key.to_s.to_sym
          out[symbol] = value unless core_keys.include?(symbol)
        end

        result = adapter_class.endpoint_schema.call(adapter_part, path: path)
        @problems.concat(result.problems)
        return nil if result.problems.any?

        # No dormant_ok here: an endpoint's missing env backed field stays fatal.
        resolved, = resolve_env(adapter_class.endpoint_schema, result.value, path)
        extra = adapter_class.validate_endpoint(resolved, path)
        @problems.concat(extra)
        return nil if extra.any?

        resolved
      end

      def resolve_adapter(name, path)
        Adapters::Registry.fetch(name)
      rescue UnknownAdapterError => e
        @problems << "#{path}.adapter: #{e.problems.first}"
        nil
      end

      # Turn `token_env: TELEGRAM_BOT_TOKEN` into `token: <value>`. A missing
      # variable is a configuration error, except a required secret when
      # +dormant_ok+ is true: that one is handed back and the account built anyway.
      #
      # @return [Array(Hash, Array<String>)] the resolved settings, and the
      #   env var names that were allowed to stay missing
      def resolve_env(schema, settings, path, dormant_ok: false)
        settings = settings.dup
        missing = []
        schema.fields.each_value do |field|
          next unless field.env_backed

          key = field.name
          var = settings[key]
          next if var.nil?

          unless key.to_s.end_with?(ENV_SUFFIX)
            @problems << "#{path}.#{key}: env backed fields must be named <name>#{ENV_SUFFIX}"
            next
          end

          target = key.to_s.delete_suffix(ENV_SUFFIX).to_sym
          value = @env[var.to_s]
          if value.nil? || value.empty?
            if dormant_ok && field.required
              missing << var.to_s
            else
              @problems << "#{path}.#{key}: environment variable #{var} is not set. " \
                           "Set it in the environment, or in a .env file for local runs."
            end
            next
          end

          settings[target] = unwrap_secret(value)
        end
        [settings, missing]
      end

      # Strip surrounding whitespace and at most one matching pair of wrapping
      # quotes, since a quoted secret makes the token an invalid URI and the URI
      # error puts the whole token in the logs.
      def unwrap_secret(value)
        text = value.to_s.strip
        first = text[0]
        if text.length >= 2 && (first == "'" || first == '"') && text[-1] == first
          text = text[1..-2]
        end
        text
      end

      # Build the operator directory. Rejects an unknown adapter or room name.
      def build_operators(raw, rooms)
        room_ids = rooms.map(&:id)
        operators = Array(raw).each_with_index.map do |entry, index|
          path = "operators[#{index}]"
          identities = (entry[:identities] || {}).each_with_object({}) do |(adapter, ids), out|
            name = adapter.to_s.to_sym
            unless Adapters::Registry.known?(name)
              @problems << "#{path}.identities.#{adapter}: unknown adapter. " \
                           "Known adapters: #{Adapters::Registry.names.join(", ")}"
              next
            end
            list = Array(ids).map(&:to_s)
            if list.empty?
              @problems << "#{path}.identities.#{adapter}: needs at least one user id"
            end
            out[name] = list
          end

          Array(entry[:actions]).each do |action|
            next if Core::Moderation.known?(action)

            @problems << "#{path}.actions: unknown moderation action #{action.inspect}. " \
                         "Known actions: #{Core::Moderation::ACTIONS.join(", ")}"
          end

          Array(entry[:rooms]).each do |room_id|
            next if room_ids.include?(room_id.to_s)

            @problems << "#{path}.rooms: no room named #{room_id.inspect}. " \
                         "Defined rooms: #{room_ids.join(", ")}"
          end

          Core::Moderation::Operator.new(
            name: entry[:name],
            identities: identities,
            actions: entry[:actions] ? Array(entry[:actions]).map(&:to_sym) : :all,
            rooms: entry[:rooms] ? Array(entry[:rooms]).map(&:to_s) : :all
          )
        end
        Core::Moderation::Directory.new(operators)
      end

      # Build the mention directory from `people:`, folding in the operators.
      def build_people(raw, operators)
        entries = Array(raw).each_with_index.map do |entry, index|
          path = "people[#{index}]"
          Core::Person.new(
            name: entry[:name],
            identities: validated_identities(entry[:identities], path),
            handles: validated_identities(entry[:handles], path, key: "handles")
          )
        end

        operator_people = operators.operators.map do |operator|
          Core::Person.new(name: operator.name, identities: operator.identities)
        end

        Core::Directory.new(entries + operator_people)
      end

      def validated_identities(map, path, key: "identities")
        (map || {}).each_with_object({}) do |(adapter, values), out|
          name = adapter.to_s.to_sym
          unless Adapters::Registry.known?(name)
            @problems << "#{path}.#{key}.#{adapter}: unknown adapter. " \
                         "Known adapters: #{Adapters::Registry.names.join(", ")}"
            next
          end
          list = Array(values).map(&:to_s).reject(&:empty?)
          @problems << "#{path}.#{key}.#{adapter}: needs at least one entry" if list.empty?
          out[name] = list
        end
      end

      def build_display_name(raw)
        raw ||= {}
        # No format means no override: the router builds the structured sender label.
        Core::DisplayName.new(
          template: raw[:format],
          fallback: raw[:fallback_format]
        )
      end

      # Whole file consistency checks that no single schema can express.
      def check_topology(rooms)
        room_ids = rooms.map(&:id)
        duplicate_rooms = room_ids.tally.select { |_, count| count > 1 }.keys
        duplicate_rooms.each { |id| @problems << "rooms: duplicate room id #{id.inspect}" }

        endpoint_ids = rooms.flat_map { |room| room.endpoints.map(&:id) }
        endpoint_ids.tally.each do |id, count|
          next if count == 1

          # One endpoint id may appear in several rooms (a hub topology), but
          # twice in the same room would fan a message out to itself.
          rooms.each do |room|
            occurrences = room.endpoints.count { |e| e.id == id }
            next if occurrences <= 1

            @problems << "rooms[#{room.id}]: endpoint id #{id.inspect} appears #{occurrences} times in one room"
          end
        end

        # An endpoint id used twice must describe the same place, otherwise the
        # message map would conflate two different channels.
        rooms.flat_map(&:endpoints).group_by(&:id).each do |id, group|
          shapes = group.map { |e| [e.adapter_name, e.account, e.settings] }.uniq
          next if shapes.size <= 1

          @problems << "endpoint id #{id.inspect} is used for #{shapes.size} different destinations. " \
                       "Endpoint ids must be unique across the whole configuration."
        end
      end

      # Rejects a banner aimed at an unknown room, dropped silently at boot otherwise.
      def check_announce(announce, rooms)
        target = announce && announce[:room]
        return if target.nil?

        known = rooms.map(&:id)
        return if known.include?(target.to_s)

        @problems << "announce.room: no room named #{target.to_s.inspect}. " \
                     "Defined rooms: #{known.join(", ")}"
      end

      def prefixed(problems)
        problems.map { |problem| "#{@source}: #{problem}" }
      end
    end

    # One credentialed platform connection. +dormant_reason+ is nil for an enabled
    # account, otherwise a short reason the runtime logs before skipping that gateway.
    Account = Struct.new(:name, :adapter_name, :adapter_class, :settings, :dormant_reason, keyword_init: true) do
      def dormant? = !dormant_reason.nil?
    end
  end
end
