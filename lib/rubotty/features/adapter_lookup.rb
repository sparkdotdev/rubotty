# frozen_string_literal: true

module Rubotty
  module Features
    # Finds the adapter instance serving an endpoint. Logs and returns nil for
    # an unregistered endpoint.
    module AdapterLookup
      def adapter_for(endpoint)
        adapter = @adapters[[endpoint.adapter_name, endpoint.account]]
        logger.error { "no adapter instance for #{endpoint}" } if adapter.nil?
        adapter
      end
    end
  end
end
