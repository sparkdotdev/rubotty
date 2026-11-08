# frozen_string_literal: true

require "spec_helper"

# Live validation for the Stoat adapter: send, receive, edit, react and
# delete against a REAL Stoat server, skipped unless STOAT_LIVE_TOKEN or
# STOAT_LIVE_CHANNEL_ID is unset; `rake adapters:live` warns rather than
# reading a skip as a pass. Point STOAT_LIVE_CHANNEL_ID at an empty channel the bot can manage.
RSpec.describe "the Stoat adapter against a real Stoat server",
               if: ENV["STOAT_LIVE_TOKEN"] && ENV["STOAT_LIVE_CHANNEL_ID"] do
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:endpoint) do
    endpoint("live-stoat", adapter: :stoat, settings: { channel_id: ENV.fetch("STOAT_LIVE_CHANNEL_ID") })
  end
  let(:adapter) do
    Rubotty::Adapters::Stoat::Adapter.new(
      account: "live", settings: { token: ENV.fetch("STOAT_LIVE_TOKEN") },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [endpoint]
    )
  end

  # The suite globally refuses a real Net::HTTP request (spec_helper.rb); this
  # is the one place in the suite that is supposed to make one.
  before { allow(Net::HTTP).to receive(:start).and_call_original }

  # Stoat's own mention token: a raw "<@ULID>" survives Stoat's inbound
  # parse as literal text rather than resolving to a name (see
  # Adapters::Stoat::Inbound's own comment), so this only proves the token
  # rides through send and receive intact.
  def mention_token(started_adapter) = "<@#{started_adapter.own_account_id}>"

  include_examples "a live platform adapter"
end
