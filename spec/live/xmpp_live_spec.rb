# frozen_string_literal: true

require "spec_helper"

# Live validation for the XMPP adapter: send, receive, react and delete
# against a REAL XMPP server, skipped unless XMPP_LIVE_JID, XMPP_LIVE_PASSWORD
# or XMPP_LIVE_ROOM_JID is unset. This adapter declares edits? false, since
# XEP-0308 correction is uneven, so the shared contract's edit leg is expected to skip here, not fail.
RSpec.describe "the XMPP adapter against a real XMPP server",
               if: ENV["XMPP_LIVE_JID"] && ENV["XMPP_LIVE_PASSWORD"] && ENV["XMPP_LIVE_ROOM_JID"] do
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:endpoint) do
    endpoint("live-xmpp", adapter: :xmpp, settings: { room_jid: ENV.fetch("XMPP_LIVE_ROOM_JID") })
  end
  let(:adapter) do
    Rubotty::Adapters::Xmpp::Adapter.new(
      account: "live",
      settings: { jid: ENV.fetch("XMPP_LIVE_JID"), password: ENV.fetch("XMPP_LIVE_PASSWORD"),
                  nick: ENV["XMPP_LIVE_NICK"] },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [endpoint]
    )
  end

  # own_account_id is the bot's own MUC nick as plain text. XMPP carries no
  # structured mention at all; a mention is just typing someone's nick, so
  # this only proves the nick survives an ordinary text send and receive.
  def mention_token(started_adapter) = started_adapter.own_account_id.to_s

  include_examples "a live platform adapter"
end
