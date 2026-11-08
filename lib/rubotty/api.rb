# frozen_string_literal: true

# The REST admin API. Loaded on demand, NOT by `require "rubotty"`: only the API
# entry points (`rubotty api`, api.ru, `rubotty web`) require this file, so the
# bot's relay runtime never pulls Sinatra or Rack into its process.
require "rubotty"

# For the debug/info report on the Lua toolchain.
require "rubotty/scripting"

require "rubotty/api/bot_logs_client"
# The push that asks the bot to relay an accepted backfill proposal. Shared with
# the dashboard rather than copied, so one hop serves both surfaces. One small
# file, no Sinatra, no views.
require "rubotty/dashboard/bot_nudge"
# The deployment-wide operator action-permission catalog, the same small
# read/write service the dashboard's Operators page checkbox grid drives.
# Requiring Role rather than ActionPermissions directly, since the latter
# references Role at call time without requiring it itself.
require "rubotty/dashboard/role"
require "rubotty/api/deps"
require "rubotty/api/app"
require "rubotty/api/server"

module Rubotty
  # See {Api::App} for the surface and {Api::Deps} for the reused
  # control-plane operations behind it.
  module Api
  end
end
