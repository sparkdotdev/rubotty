# frozen_string_literal: true

# The guest portal web surface. Loaded on demand, NOT by `require "rubotty"`:
# only the guest-portal entry points (`rubotty guest-portal`, guest.ru) require
# this file, so the bot process never pulls Sinatra or Rack into its runtime.
require "rubotty"

require "rubotty/guest_portal/rate_limiter"
require "rubotty/guest_portal/stream_limiter"
require "rubotty/guest_portal/deps"
require "rubotty/guest_portal/app"
require "rubotty/guest_portal/server"

module Rubotty
  # Two halves over one shared feed: {GuestPortal::App}, the token-gated web chat
  # (this process), and {Adapters::Guest::Adapter}, the bot-side adapter that
  # emits a guest's queued sends and writes relayed messages back into the feed.
  module GuestPortal
  end
end
