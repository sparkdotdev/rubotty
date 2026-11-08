# Process types for buildpack platforms (Heroku, Coolify, Dokku, Scalingo).
#
# Both entries run the same command; the Telegram transport in your config
# decides which one to scale. long_polling needs `worker` at 1 and `web` at 0.
# webhook needs `web` at 1 and `worker` at 0, and binds $PORT.
#
# Never run both at once against the same bot token. Telegram allows one receive
# mechanism per bot, so whichever started last wins and the other goes silent.
#
# YJIT is switched on by RUBY_YJIT_ENABLE in the image environment rather than by
# a prefix on each line here. Building with --enable-yjit only compiles the JIT
# in, and a platform where somebody has set an explicit start command never reads
# this file, which is how the dashboard ran without YJIT while the bot had it.
web: bundle exec bin/rubotty run
worker: bundle exec bin/rubotty run

# The operator web dashboard, a separate process from the bot. Binds $PORT, needs
# DASHBOARD_SECRET, and reads the same datastore the bot uses. Off unless scaled.
dashboard: bundle exec bin/rubotty dashboard

# The token-gated guest web chat, a separate process reading the same datastore.
# There is no login secret: a guest presents an invite token in the link, bounded
# by the invite's expiry, its single-channel scope and operator revocation.
guest-portal: bundle exec bin/rubotty guest-portal

# A rehosted file's download route, a separate process reading the same
# datastore. Mounted at /filestorage and the legacy /f, since a download link
# is always built under that path wherever it resolves. Needs
# RUBOTTY_FILE_STORAGE_URL set to this process's own public base, on the bot
# process too.
file-storage: bundle exec bin/rubotty file-storage

# Landing page, dashboard, guest portal and file storage on one host, separated
# by path (/, /admin-panel, /guest-chat, /filestorage). Needs DASHBOARD_SECRET,
# GUEST_PORTAL_URL and RUBOTTY_FILE_STORAGE_URL. Prefer this over scaling the
# surfaces separately.
webui: bundle exec bin/rubotty web
