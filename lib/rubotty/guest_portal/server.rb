# frozen_string_literal: true

require "rackup"
require "rackup/handler/webrick"

module Rubotty
  module GuestPortal
    # Binds a built guest-portal app to a port and serves it, over WEBrick through
    # rackup's pure-Ruby handler, as the dashboard and the health endpoint do. For a
    # production deployment the app can equally be served by `rackup guest.ru`.
    module Server
      DEFAULT_PORT = 9393
      DEFAULT_BIND = "0.0.0.0"

      module_function

      # @param app [#call] a built Rack/Sinatra app
      # @param port [Integer]
      # @param bind [String]
      # @param logger [#info, nil]
      def run(app, port: DEFAULT_PORT, bind: DEFAULT_BIND, logger: nil)
        logger&.info { "guest portal listening on #{bind}:#{port}" }
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
