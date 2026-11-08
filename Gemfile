# frozen_string_literal: true

source "https://rubygems.org"

# The Ruby version lives in .ruby-version, deliberately not here as well: a
# `ruby` directive writes a RUBY VERSION stanza into Gemfile.lock, which then has
# to match the deploy interpreter exactly and breaks on any patch difference.

# Dependency policy: no third party gem here may need a compiler at install
# time. Every one is either pure Ruby or ships precompiled binaries for the
# platforms this project targets. The exceptions are bigdecimal, json and
# fiddle, which are standard library: the interpreter ships all three and none
# publishes a platform gem. The `dependencies` CI job asserts the exact set of
# compiled gems, so a new C extension arriving through a transitive bump fails
# the build.
#
# fiddle costs slightly more than the other two at build time and that is the
# one thing to know before bumping it. bigdecimal and json build against
# headers the interpreter already ships; fiddle wants libffi's, so a build
# image needs libffi-dev. railpack.json and heroku-24 both have it, and ci.yml
# installs it in the two jobs that vendor the bundle. What it buys is the
# syscall layer in lib/rubotty/scripting/libc.rb, where the sandbox hands the
# kernel structures full of zero bytes that Kernel#syscall will not pass. The
# libffi underneath is not new: discordrb already brings ffi.
#
# json is in the bundle rather than taken from the interpreter because faraday,
# under telegram-bot-ruby, declares it with no version bound. Pinning it to the
# version the interpreter ships as a default gem is the obvious thing to reach
# for, and it was tried: the lock resolves cleanly, and bundler still vendors
# and builds it, because a vendored bundle path installs every gem into that
# path whether or not the interpreter already has that exact version. So the
# pin buys nothing, and the honest answer is to declare json compiled and let
# the CI job hold the line on everything else.

# Stdlib components unbundled from the interpreter over the 3.x and 4.0 series.
# Declaring them is what makes one Gemfile.lock work across 3.3, 3.4 and 4.0.
gem "logger", "~> 1.6"
gem "net-http", "~> 0.6"
gem "pstore", "~> 0.2"

# The syscall layer under the operator scripting sandbox. Stopped being a
# default gem on 4.0, so `require "fiddle"` needs it declared. Policy note above.
gem "fiddle", "~> 1.1"

# The Ruby side of the same sandbox's pipe to its Lua child, in place of the
# stdlib json gem: pure Ruby, so it needs nothing from the toolchain step at
# all, not even the compiler force_ruby_platform already tolerates elsewhere.
gem "messagepack", "~> 1.0"

# XML parser for the in house XMPP client. Unbundled on 4.0, so it has to be
# declared to be usable under `bundle exec`.
gem "rexml", "~> 3.4"

# The YAML engine, in place of Psych. Pure Ruby, unlike Psych's bundled libyaml
# C extension, and reads YAML 1.2.2 instead of 1.1. HTTPS keeps clean public
# clones usable without deployment credentials. The lockfile pins the revision.
gem "yamlcamel-ruby", git: "https://github.com/sparkdotdev/yamlcamel-ruby.git", ref: "847e58df5d36056e6d7b0f46077d17f0a5d1ca17"

# Query layer for the message map.
gem "sequel", "~> 5.106"

# The default storage driver, so a bridge for a handful of people needs no
# database server to start. A C extension, but precompiled for every target.
gem "sqlite3", "~> 2.9"

# Used by the Telegram webhook transport. Ships with Ruby as a bundled gem, so it
# still has to be declared.
gem "webrick", "~> 1.9"

# QR decoding for the link filter (issue #857): FFI bindings to libzbar, no
# compiler needed at install and no extension of its own, only `ffi`, already
# in the allowed list below. Requires libzbar itself on the host (railpack.json
# and ci.yml install libzbar0); Util::QrDecoder checks once at first use and
# decodes nothing on a deployment without it rather than raising.
gem "zbar", "~> 0.3"

# Named IANA timezone math for the bridge's Discord <t:UNIX:FORMAT> timestamp
# expansion (Features::TimestampExpansion): Time#getlocal only ever resolves a
# fixed "+HH:MM" offset or "UTC", never a zone name, and mutating ENV["TZ"] to
# fake one is not an option since every room runs on its own concurrent
# worker. tzinfo-data ships the whole IANA database as plain Ruby source, so
# this carries no dependency on the deploy image having system tzdata
# installed. Both gems are pure Ruby.
gem "tzinfo", "~> 2.0"
gem "tzinfo-data", "~> 1.2026", ">= 1.2026.3"

# Telegram Bot API transport. Pure Ruby, and so is its whole closure: dry-struct,
# faraday, faraday-multipart and zeitwerk all install without a compiler.
#
# Its gemspec sets no license field, so a scanner reading metadata sees nothing.
# The gem does ship a LICENSE file, WTFPL v2, which permits everything with no
# conditions.
gem "telegram-bot-ruby", "~> 2.8"

# Discord gateway and REST. Pulls `ffi` and `opus-ruby`, both voice only and
# never invoked here; precompiled ffi binaries exist for every target platform.
gem "discordrb", "~> 3.8"

# PostgreSQL, opt in with `bundle config set --local with postgres`. `pg` is a C
# extension but ships precompiled for arm64-darwin, x86_64-linux, aarch64-linux
# and the musl variants.
#
# Do not swap in sequel-postgres-pr or extralite: the first has no TLS and md5
# auth only, so it fails against a default scram-sha-256 server, and the second
# publishes only the generic platform, so it compiles on every install.

group :postgres, optional: true do
  gem "pg", "~> 1.5"
end

# MariaDB / MySQL, opt in with `bundle config set --local with mariadb`, purely
# to keep the default bundle small. The driver is pure Ruby and Sequel's own
# `mysql` adapter binds it, so MariaDB goes through the same SequelStore as
# Postgres.
group :mariadb, optional: true do
  gem "ruby-mysql", "~> 4.1"
end

# The operator dashboard, a separate Sinatra surface over the control-plane
# database. `require "rubotty"` never pulls it in, so the relay runtime carries
# none of it at boot. The server it binds is the WEBrick declared above, reached
# through rackup's pure-Ruby handler.
# Rack must include the multipart, host validation and static-header security fixes.
gem "rack", "~> 3.2", ">= 3.2.8"
gem "sinatra", "~> 4.1"
gem "rackup", "~> 2.2"

# Renders README.md on the dashboard index. Picked over redcarpet and
# commonmarker because those compile a C extension.
gem "kramdown", "~> 2.5"

group :development, :test do
  # Loaded only by bin/rubotty and guarded by a rescue, so a deployment without
  # it runs normally on real environment variables.
  gem "dotenv", "~> 3.1"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"

  # Drives the dashboard's Rack app in-process, with no socket and no server.
  gem "rack-test", "~> 2.2"

  # Validates real API responses against docs/api/openapi.yaml so the published
  # spec cannot drift from the routes. Its whole runtime closure was downloaded
  # and scanned to confirm it ships no extension, because a remote gemspec
  # reports zero extensions whether or not one is really there.
  gem "json_schemer", "~> 2.5"
end
