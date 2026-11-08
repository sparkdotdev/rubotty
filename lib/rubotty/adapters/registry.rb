# frozen_string_literal: true

module Rubotty
  module Adapters
    # Maps the `adapter:` value in YAML onto an adapter class. Registration is
    # explicit, so an adapter shipped in a separate gem becomes usable by
    # calling .register.
    module Registry
      @adapters = {}
      @mutex = Mutex.new

      class << self
        def register(klass)
          name = klass.adapter_name.to_sym
          @mutex.synchronize do
            existing = @adapters[name]
            if existing && existing != klass
              raise Error, "adapter #{name} is already registered to #{existing}"
            end

            @adapters[name] = klass
          end
          klass
        end

        # @raise [UnknownAdapterError]
        def fetch(name)
          klass = @adapters[name.to_sym]
          return klass if klass

          raise UnknownAdapterError,
                ["unknown adapter #{name.inspect}, known adapters are: #{names.join(", ")}"]
        end

        def [](name) = @adapters[name.to_sym]

        def known?(name) = @adapters.key?(name.to_sym)

        def names = @adapters.keys.sort

        def all = @adapters.dup

        # Test helper. Not for production use.
        def reset!
          @mutex.synchronize { @adapters = {} }
        end
      end
    end
  end
end
