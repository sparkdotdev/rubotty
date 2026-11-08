# frozen_string_literal: true

require "rackup"
require "rackup/handler/webrick"

module Rubotty
  module Api
    # Binds a built API app to a port and serves it on WEBrick, through rackup's
    # pure-Ruby handler.
    module Server
      # Distinct from every other surface's default, so the single-surface commands
      # can run side by side in development.
      DEFAULT_PORT = 9595
      DEFAULT_BIND = "0.0.0.0"

      module_function

      # @param app [#call] a built Rack/Sinatra app
      # @param port [Integer]
      # @param bind [String]
      # @param logger [#info, nil]
      def run(app, port: DEFAULT_PORT, bind: DEFAULT_BIND, logger: nil)
        logger&.info { "api listening on #{bind}:#{port}" }
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
