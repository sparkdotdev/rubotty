# frozen_string_literal: true

# The unified web surface: a landing page at `/`, the operator dashboard at
# `/admin-panel`, the guest portal at `/guest-chat`, the REST admin API at
# `/api` and a rehosted file's download route at `/filestorage` (and the
# legacy `/f`), each mounted verbatim with {Rack::URLMap} on one hostname.
#
# Loaded on demand, NOT by `require "rubotty"`: only the unified entry points
# (`rubotty web`, web.ru) require this file, so the bot's relay runtime never
# pulls Sinatra or Rack into its process.
require "rubotty"

require "rubotty/dashboard"
require "rubotty/guest_portal"
require "rubotty/api"
require "rubotty/file_storage"
require "rack"
require "rack/urlmap"

require "rubotty/web/landing"
require "rubotty/web/proxied_scheme"
require "rubotty/web/server"

module Rubotty
  # The one-hostname composition of the dashboard, the guest portal and the REST
  # admin API. {.assemble} returns the ready-to-serve Rack app.
  module Web
    # The path each surface is mounted under. Public so the CLI, the standalone
    # .ru files, the landing template and the tests all agree on one set of
    # prefixes.
    ADMIN_MOUNT = "/admin-panel"
    GUEST_MOUNT = "/guest-chat"
    API_MOUNT = "/api"
    FILES_MOUNT = "/filestorage"

    # The bare-secret shape a download link could have been minted under
    # before {FILES_MOUNT} carried its own extension. Kept working rather
    # than removed: a rehosted file can sit on disk for up to a year, so a
    # link already posted into a real room may still be live.
    LEGACY_FILES_MOUNT = "/f"

    module_function

    # Build the unified Rack app, each surface over the same control-plane
    # datastore through its own injected deps.
    #
    # @param env [Hash] the environment the sub-apps read their secret NAMES from
    # @return [#call] a Rack app ready to serve
    def assemble(dashboard_deps:, guest_deps:, api_deps:, env: ENV, logger: nil)
      # The one instance both file-storage mounts serve from, and the same
      # one guest_deps itself already reads from for a rehosted guest upload.
      files = FileStorage::App.assemble(rehosted_files: guest_deps.rehosted_files, logger: logger)
      map = Rack::URLMap.new(
        ADMIN_MOUNT => Dashboard::App.assemble(deps: dashboard_deps, env: env, logger: logger),
        GUEST_MOUNT => GuestPortal::App.assemble(deps: guest_deps, env: env),
        API_MOUNT => Api::App.assemble(deps: api_deps, env: env, logger: logger),
        FILES_MOUNT => files,
        LEGACY_FILES_MOUNT => files,
        "/" => Landing.assemble(guest_path: GUEST_MOUNT, admin_path: ADMIN_MOUNT, env: env)
      )
      # OUTSIDE the URLMap, so the scheme is already right by the time
      # Sinatra builds its session middleware and its redirects. Wrapping a
      # sub-app instead would leave the session cookie being written by
      # middleware that still believed the request was http.
      ProxiedScheme.new(map, assume_tls: ProxiedScheme.assume_tls?(env))
    end
  end
end
