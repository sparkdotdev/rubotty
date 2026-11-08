# frozen_string_literal: true

require "rackup"
require "rackup/handler/webrick"

module Rubotty
  module FileStorage
    # Binds a built file-storage app to a port and serves it on WEBrick, through
    # rackup's pure-Ruby handler, like every other surface's standalone server.
    module Server
      # Distinct from every other surface's default, so the single-surface commands
      # can run side by side in development.
      DEFAULT_PORT = 9494
      DEFAULT_BIND = "0.0.0.0"

      module_function

      # @param app [#call] a built Rack app
      # @param port [Integer]
      # @param bind [String]
      # @param logger [#info, nil]
      def run(app, port: DEFAULT_PORT, bind: DEFAULT_BIND, logger: nil)
        logger&.info { "file storage listening on #{bind}:#{port}" }
        Rackup::Handler::WEBrick.run(
          app,
          Host: bind,
          Port: port,
          Logger: WEBrick::Log.new(File::NULL),
          AccessLog: []
        )
      end
    end
  end
end
