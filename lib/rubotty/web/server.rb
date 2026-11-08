# frozen_string_literal: true

require "rackup"
require "rackup/handler/webrick"

module Rubotty
  module Web
    # Binds the unified web app (landing + dashboard + guest portal) to a port and
    # serves it through WEBrick, the convenience the `rubotty web` command drives.
    # A production deployment can equally use `rackup web.ru`.
    module Server
      # 3000 because a proxy that has not been told a port probes it. `rubotty web`
      # reads $PORT first, so this only decides what happens on a host that set
      # nothing, where a port no proxy points at fails the healthcheck silently.
      DEFAULT_PORT = 3000
      DEFAULT_BIND = "0.0.0.0"

      module_function

      # @param app [#call] the assembled unified Rack app
      # @param port [Integer]
      # @param bind [String]
      # @param logger [#info, nil]
      def run(app, port: DEFAULT_PORT, bind: DEFAULT_BIND, logger: nil)
        logger&.info { "web (landing + dashboard + guest portal) listening on #{bind}:#{port}" }
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
