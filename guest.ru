# frozen_string_literal: true

# Rackup entry point for the guest portal. Serves the same control-plane
# datastore the bot uses, from a separate process. `rubotty guest-portal` is the
# equivalent convenience command.
#
# A guest presents an invite token in the link, so there is no login secret here.
# Access is bounded by the invite's expiry, its single-channel scope and operator
# revocation, all enforced in the datastore.

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

begin
  require "dotenv"
  Dotenv.load(File.expand_path(".env", __dir__))
rescue LoadError
  # dotenv is a development convenience; its absence is normal in production.
end

require "rubotty/guest_portal"

config = Rubotty::Config::Loader.load_for_boot(ENV["BRIDGE_CONFIG"], env: ENV)
logger = Rubotty::Log.build(level: config.log_level)

storage = Rubotty::Storage::Selector.build_live(config.storage, env: ENV, logger: logger)
unless Rubotty::ControlPlane::Boot.available?(storage)
  raise "The guest portal needs a Sequel-backed store (storage.driver sqlite, pg or mdb); " \
        "#{storage.describe} has no database connection to serve."
end

db = Rubotty::ControlPlane::Boot.db_of(storage)
Rubotty::ControlPlane.migrate!(db)
deps = Rubotty::GuestPortal::Deps.new(
  db: db, logger: logger,
  rate_max: (ENV["GUEST_PORTAL_RATE_MAX"] || Rubotty::GuestPortal::RateLimiter::DEFAULT_MAX).to_i,
  rate_window: (ENV["GUEST_PORTAL_RATE_WINDOW"] || Rubotty::GuestPortal::RateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
  file_store_path: config.file_store_path
)

run Rubotty::GuestPortal::App.assemble(deps: deps, env: ENV)
