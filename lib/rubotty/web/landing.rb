# frozen_string_literal: true

require "sinatra/base"

module Rubotty
  module Web
    # The signpost at the root of the unified web surface: two links, no auth and
    # no data. Everything sensitive stays behind {Dashboard::App} and
    # {GuestPortal::App} at their mount points.
    class Landing < Sinatra::Base
      # Build the landing app, told the two mount paths so its links always match
      # wherever {Web.assemble} mounts the surfaces.
      #
      # @param guest_path [String] the mount path of the guest portal
      # @param admin_path [String] the mount path of the dashboard
      # @param env [Hash]
      # @return [Class] a ready-to-serve Sinatra app subclass
      def self.assemble(guest_path:, admin_path:, env: ENV)
        Class.new(self) do
          set :guest_path, guest_path
          set :admin_path, admin_path
          set :landing_env, env
        end
      end

      set :views, File.expand_path("views", __dir__)
      # Stdlib ERB does not auto-escape, so every dynamic value goes through `h`.
      set :erb, escape_html: false
      disable :show_exceptions
      enable :raise_errors
      disable :dump_errors
      # There is no session and no credential here: the page is a public signpost.
      disable :sessions
      # The reverse proxy terminates the public hostname and is the trust boundary,
      # so Sinatra's own Host whitelist is disabled.
      set :host_authorization, permitted_hosts: []

      get "/healthz" do
        content_type "text/plain"
        "ok\n"
      end

      get "/" do
        erb :landing, layout: false
      end

      helpers do
        def h(text) = Rack::Utils.escape_html(text.to_s)

        # The absolute path to a mounted surface, correct even if the whole unified
        # app is itself mounted under a prefix.
        def mount(path) = "#{request.script_name}#{path}"
      end
    end
  end
end
