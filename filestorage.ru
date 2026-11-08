# frozen_string_literal: true

# Rackup entry point for the rehosted-file download route, on its own host.
# Serves the same control-plane datastore the bot uses, from a separate
# process. `rubotty file-storage` is the equivalent convenience command.
#
# Mounted at /filestorage (and the legacy /f, for a link minted before that
# path existed), not at the process root: a download link is always built as
# RUBOTTY_FILE_STORAGE_URL + /filestorage/<token>, whatever process ends up
# serving it, so the healthcheck lives at /filestorage/healthz here rather
# than the bare root.
#
# Set RUBOTTY_FILE_STORAGE_URL to this deployment's own public base, on this
# process as well as the bot's: a rehosted file's download link is built
# wherever the file is stored, which for a relay is the bot.

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

begin
  require "dotenv"
  Dotenv.load(File.expand_path(".env", __dir__))
rescue LoadError
  # dotenv is a development convenience; its absence is normal in production.
end

require "rubotty/file_storage"

config = Rubotty::Config::Loader.load_for_boot(ENV["BRIDGE_CONFIG"], env: ENV)
logger = Rubotty::Log.build(level: config.log_level)

storage = Rubotty::Storage::Selector.build_live(config.storage, env: ENV, logger: logger)
unless Rubotty::ControlPlane::Boot.available?(storage)
  raise "File storage needs a Sequel-backed store (storage.driver sqlite, pg or mdb); " \
        "#{storage.describe} has no database connection to serve."
end

db = Rubotty::ControlPlane::Boot.db_of(storage)
Rubotty::ControlPlane.migrate!(db)
models = Rubotty::ControlPlane.models(db)

# nil, rather than a raised boot failure, when the store is not usable: the
# route itself already 404s every request in that case, the same tolerance
# {GuestPortal::Deps} gives the object store on the guest portal side.
rehosted_files =
  begin
    object_store = Rubotty::Storage::ObjectStore.new(root: config.file_store_path, logger: logger)
    object_store.ready!
    Rubotty::ControlPlane::RehostedFiles.new(models: models, store: object_store, logger: logger)
  rescue Rubotty::Storage::ObjectStore::Unavailable => e
    logger&.warn { "file store unavailable, so rehosted downloads are off: #{e.message}" }
    nil
  end

run Rubotty::FileStorage.assemble(rehosted_files: rehosted_files, logger: logger)
