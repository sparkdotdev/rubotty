# frozen_string_literal: true

require "spec_helper"

# Live validation for the Matrix adapter: send, receive, edit, react and
# delete against a REAL homeserver, skipped unless MATRIX_LIVE_HOMESERVER,
# MATRIX_LIVE_TOKEN or MATRIX_LIVE_ROOM_ID is unset. MATRIX_LIVE_TOKEN is an
# access token, never a password; point MATRIX_LIVE_ROOM_ID at a room the account already joined.
RSpec.describe "the Matrix adapter against a real homeserver",
               if: ENV["MATRIX_LIVE_HOMESERVER"] && ENV["MATRIX_LIVE_TOKEN"] && ENV["MATRIX_LIVE_ROOM_ID"] do
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:endpoint) do
    endpoint("live-matrix", adapter: :matrix, settings: { room_id: ENV.fetch("MATRIX_LIVE_ROOM_ID") })
  end
  let(:adapter) do
    Rubotty::Adapters::Matrix::Adapter.new(
      account: "live",
      settings: { homeserver: ENV.fetch("MATRIX_LIVE_HOMESERVER"), token: ENV.fetch("MATRIX_LIVE_TOKEN") },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [endpoint]
    )
  end

  # The suite globally refuses a real Net::HTTP request (spec_helper.rb); this
  # is the one place in the suite that is supposed to make one.
  before { allow(Net::HTTP).to receive(:start).and_call_original }

  # own_account_id is already a full "@user:server" Matrix id, as plain text.
  # Matrix mentions proper ride on the m.mentions field and a formatted_body
  # pill, which this adapter's Outbound does not build for an arbitrary Span
  # (only Telegram and the guest adapter render the :mention span kind at
  # all, see README.md), so this only proves the id survives an ordinary
  # text send and receive.
  def mention_token(started_adapter) = started_adapter.own_account_id.to_s

  include_examples "a live platform adapter"
end
