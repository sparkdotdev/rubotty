# frozen_string_literal: true

require "spec_helper"

# Live validation for the Fluxer adapter: send, receive, edit, react and
# delete against a REAL Fluxer server, skipped unless FLUXER_LIVE_TOKEN and
# FLUXER_LIVE_CHANNEL_ID are set. Point FLUXER_LIVE_CHANNEL_ID at an empty
# (or throwaway) guild text channel; posts as the bot itself, so none needs to exist yet.
RSpec.describe "the Fluxer adapter against a real Fluxer server",
               if: ENV["FLUXER_LIVE_TOKEN"] && ENV["FLUXER_LIVE_CHANNEL_ID"] do
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:endpoint) do
    endpoint("live-fluxer", adapter: :fluxer,
                            settings: { channel_id: ENV.fetch("FLUXER_LIVE_CHANNEL_ID"), webhook: :off })
  end
  let(:adapter) do
    Rubotty::Adapters::Fluxer::Adapter.new(
      account: "live", settings: { token: ENV.fetch("FLUXER_LIVE_TOKEN") },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [endpoint]
    )
  end

  # The suite globally refuses a real Net::HTTP request (spec_helper.rb); this
  # is the one place in the suite that is supposed to make one.
  before { allow(Net::HTTP).to receive(:start).and_call_original }

  # Fluxer's own mention token, Discord shaped. Inbound resolves it through
  # #resolve_mention when it can, so the rendered body may show "@handle"
  # rather than the literal token; either way the round trip is proven by the
  # nonce riding alongside it, not by the token surviving verbatim.
  def mention_token(started_adapter) = "<@#{started_adapter.own_account_id}>"

  include_examples "a live platform adapter"
end
