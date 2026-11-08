# frozen_string_literal: true

# Rackup entry point for the unified web surface: the landing page at /, the
# operator dashboard at /admin-panel, the guest portal at /guest-chat and a
# rehosted file's download route at /filestorage, on one hostname behind one
# process. `rubotty web` is the equivalent convenience command; config.ru and
# guest.ru mount each surface on its own host instead.
#
# Set GUEST_PORTAL_URL to the /guest-chat base, so the dashboard's invite links
# and the guest portal's upload URLs both resolve under the mount, and
# RUBOTTY_FILE_STORAGE_URL to this deployment's own public base, so a
# rehosted file's download link resolves too.

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

begin
  require "dotenv"
  Dotenv.load(File.expand_path(".env", __dir__))
rescue LoadError
  # dotenv is a development convenience; its absence is normal in production.
end

require "rubotty/web"

config = Rubotty::Config::Loader.load_for_boot(ENV["BRIDGE_CONFIG"], env: ENV)
# This process's own recent lines, for the admin debug/logs endpoint's source=web.
log_buffer = Rubotty::RingBuffer.new
logger = Rubotty::Log.build(level: config.log_level, ring_buffer: log_buffer)

storage = Rubotty::Storage::Factory.build(config.storage, env: ENV, logger: logger)
unless Rubotty::ControlPlane::Boot.available?(storage)
  raise "The unified web surface needs a Sequel-backed store (storage.driver sqlite or pg); " \
        "#{storage.describe} has no database connection to serve."
end

db = Rubotty::ControlPlane::Boot.db_of(storage)
Rubotty::ControlPlane.migrate!(db)

dashboard_deps = Rubotty::Dashboard::Deps.new(
  db: db, logger: logger,
  debug_logs: Rubotty::Dashboard::DebugLogs.new(
    log_buffer: log_buffer,
    bot_logs: Rubotty::Api::BotLogsClient.new(
      bot_url: ENV["RUBOTTY_BOT_INTERNAL_URL"], secret: ENV["RUBOTTY_INTERNAL_SECRET"], logger: logger
    )
  )
)
guest_deps = Rubotty::GuestPortal::Deps.new(
  db: db, logger: logger,
  rate_max: (ENV["GUEST_PORTAL_RATE_MAX"] || Rubotty::GuestPortal::RateLimiter::DEFAULT_MAX).to_i,
  rate_window: (ENV["GUEST_PORTAL_RATE_WINDOW"] || Rubotty::GuestPortal::RateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
  file_store_path: config.file_store_path
)
api_deps = Rubotty::Api::Deps.new(
  db: db, logger: logger,
  rate_max: (ENV["API_RATE_MAX"] || Rubotty::ControlPlane::ApiRateLimiter::DEFAULT_MAX).to_i,
  rate_window: (ENV["API_RATE_WINDOW"] || Rubotty::ControlPlane::ApiRateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
  log_buffer: log_buffer, bot_url: ENV["RUBOTTY_BOT_INTERNAL_URL"], bot_secret: ENV["RUBOTTY_INTERNAL_SECRET"],
  file_store_path: config.file_store_path
)

run Rubotty::Web.assemble(
  dashboard_deps: dashboard_deps, guest_deps: guest_deps, api_deps: api_deps, env: ENV, logger: logger
)
