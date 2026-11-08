# frozen_string_literal: true

# Rackup entry point for the operator dashboard. Serves the same control-plane
# datastore the bot uses, from a separate process, so point it at the same
# storage. `rubotty dashboard` is the equivalent convenience command.

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

begin
  require "dotenv"
  Dotenv.load(File.expand_path(".env", __dir__))
rescue LoadError
  # dotenv is a development convenience; its absence is normal in production.
end

require "rubotty/dashboard"

config = Rubotty::Config::Loader.load_for_boot(ENV["BRIDGE_CONFIG"], env: ENV)
# This process's own recent lines, for the dashboard's Logs page.
log_buffer = Rubotty::RingBuffer.new
logger = Rubotty::Log.build(level: config.log_level, ring_buffer: log_buffer)

storage = Rubotty::Storage::Selector.build_live(config.storage, env: ENV, logger: logger)
unless Rubotty::ControlPlane::Boot.available?(storage)
  raise "The dashboard needs a Sequel-backed store (storage.driver sqlite, pg or mdb); " \
        "#{storage.describe} has no database connection to serve."
end

db = Rubotty::ControlPlane::Boot.db_of(storage)
Rubotty::ControlPlane.migrate!(db)
# Handing the config to Deps is what lets the Platforms admin page show an
# account's real settings and token_env name beside the control-plane rows.
deps = Rubotty::Dashboard::Deps.new(
  db: db, logger: logger, config: config,
  debug_logs: Rubotty::Dashboard::DebugLogs.new(
    log_buffer: log_buffer,
    bot_logs: Rubotty::Api::BotLogsClient.new(
      bot_url: ENV["RUBOTTY_BOT_INTERNAL_URL"], secret: ENV["RUBOTTY_INTERNAL_SECRET"], logger: logger
    )
  )
)

run Rubotty::Dashboard::App.assemble(deps: deps, env: ENV, logger: logger)
