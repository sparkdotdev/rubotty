# frozen_string_literal: true

# The operator web dashboard. Loaded on demand, NOT by `require "rubotty"`: only
# the dashboard entry points (`rubotty dashboard`, config.ru) require this file,
# so the bot's relay runtime never pulls Sinatra or Rack into its process.
require "rubotty"

require "rubotty/dashboard/action_permissions"
require "rubotty/dashboard/config_humanizer"
require "rubotty/dashboard/feature_display"
require "rubotty/dashboard/bot_nudge"
# The header's drift check asks the bot process for its own build facts over the
# authenticated internal hop, which this client already is. Required on its own
# so the dashboard does not pull the whole admin API in behind it.
require "rubotty/api/bot_logs_client"
require "rubotty/dashboard/debug_logs"
require "rubotty/dashboard/job_failures"
require "rubotty/dashboard/primitives"
require "rubotty/dashboard/nav"
require "rubotty/dashboard/deps"
require "rubotty/dashboard/readme_renderer"
require "rubotty/dashboard/role"
require "rubotty/dashboard/search_scope"
require "rubotty/dashboard/view_data"
require "rubotty/dashboard/app"
require "rubotty/dashboard/server"

module Rubotty
  # See {Dashboard::App} for the surface and {Dashboard::Deps} for the reused
  # control-plane operations behind it.
  module Dashboard
  end
end
