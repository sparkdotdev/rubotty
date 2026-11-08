# frozen_string_literal: true

require "rackup"
require "rackup/handler/webrick"

module Rubotty
  module Dashboard
    # Binds a built dashboard app to a port and serves it on WEBrick, through
    # rackup's pure-Ruby handler. Behind a reverse proxy the app can equally be
    # served by the `rackup` binary against config.ru.
    module Server
      DEFAULT_PORT = 9292
      DEFAULT_BIND = "0.0.0.0"

      module_function

      # @param app [#call] a built Rack/Sinatra app
      # @param port [Integer]
      # @param bind [String]
      # @param logger [#info, nil]
      def run(app, port: DEFAULT_PORT, bind: DEFAULT_BIND, logger: nil)
        logger&.info { "dashboard listening on #{bind}:#{port}" }
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
