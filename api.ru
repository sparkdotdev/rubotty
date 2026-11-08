# frozen_string_literal: true

# Rackup entry point for the REST admin API. Serves the same control-plane
# datastore the bot uses, from a separate process. `rubotty api` is the
# equivalent convenience command.
#
# Access requires a bearer API key issued from the dashboard, with developer or
# administrator scope. See {Rubotty::Api::App} for the auth model.

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

begin
  require "dotenv"
  Dotenv.load(File.expand_path(".env", __dir__))
rescue LoadError
  # dotenv is a development convenience; its absence is normal in production.
end

require "rubotty/api"

config = Rubotty::Config::Loader.load_for_boot(ENV["BRIDGE_CONFIG"], env: ENV)
# This process's own recent lines, for the admin debug/logs endpoint's source=web.
log_buffer = Rubotty::RingBuffer.new
logger = Rubotty::Log.build(level: config.log_level, ring_buffer: log_buffer)

storage = Rubotty::Storage::Selector.build_live(config.storage, env: ENV, logger: logger)
unless Rubotty::ControlPlane::Boot.available?(storage)
  raise "The API needs a Sequel-backed store (storage.driver sqlite, pg or mdb); " \
        "#{storage.describe} has no database connection to serve."
end

db = Rubotty::ControlPlane::Boot.db_of(storage)
Rubotty::ControlPlane.migrate!(db)
deps = Rubotty::Api::Deps.new(
  db: db, logger: logger,
  rate_max: (ENV["API_RATE_MAX"] || Rubotty::ControlPlane::ApiRateLimiter::DEFAULT_MAX).to_i,
  rate_window: (ENV["API_RATE_WINDOW"] || Rubotty::ControlPlane::ApiRateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
  log_buffer: log_buffer, bot_url: ENV["RUBOTTY_BOT_INTERNAL_URL"], bot_secret: ENV["RUBOTTY_INTERNAL_SECRET"],
  file_store_path: config.file_store_path
)

run Rubotty::Api::App.assemble(deps: deps, env: ENV, logger: logger)
