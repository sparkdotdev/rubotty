# frozen_string_literal: true

require "spec_helper"

# Live validation for the IRC adapter against a REAL server, skipped unless
# IRC_LIVE_SERVER, IRC_LIVE_NICK and IRC_LIVE_CHANNEL are set. Skips
# spec/support/live_gateway_contract.rb, unlike the other four: plain IRC
# never echoes a PRIVMSG back to its sender, so this only proves the send does not raise.
RSpec.describe "the IRC adapter against a real IRC server",
               if: ENV["IRC_LIVE_SERVER"] && ENV["IRC_LIVE_NICK"] && ENV["IRC_LIVE_CHANNEL"] do
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:endpoint) { endpoint("live-irc", adapter: :irc, settings: { channel: ENV.fetch("IRC_LIVE_CHANNEL") }) }
  let(:adapter) do
    Rubotty::Adapters::Irc::Adapter.new(
      account: "live",
      settings: {
        server: ENV.fetch("IRC_LIVE_SERVER"), port: (ENV["IRC_LIVE_PORT"] || 6697).to_i,
        tls: ENV["IRC_LIVE_TLS"] != "0", nick: ENV.fetch("IRC_LIVE_NICK"),
        sasl_user: ENV["IRC_LIVE_SASL_USER"], sasl_password: ENV["IRC_LIVE_SASL_PASSWORD"]
      },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [endpoint]
    )
  end

  after { adapter.stop }

  it "connects and sends a real PRIVMSG, then chases whatever this server's negotiated caps allow verifying" do
    adapter.start
    expect(adapter.running?).to be(true), "the adapter never reported itself running against the real server"

    negotiated = adapter.client.negotiated_capabilities
    warn "  (IRC server negotiated: #{negotiated.sort.join(", ")})"
    caps = adapter.capabilities_for(endpoint)
    nonce = "rubotty-live-#{SecureRandom.hex(6)}"

    receipt = adapter.deliver(message(endpoint, text: "rubotty live check #{nonce}"), endpoint)
    expect(receipt).not_to be_nil
    native_id = receipt.native_id
    expect(native_id).not_to be_nil

    unless negotiated.include?("echo-message") && negotiated.include?("msgid")
      warn "  (skipping the receive/edit/reaction/delete legs: this server did not negotiate " \
           "echo-message and msgid, so a plain PRIVMSG here never comes back to its own sender)"
      return
    end

    sent_back = LiveGateway.wait_for_message(dispatcher) { |m| m.kind == :chat && m.body.to_s.include?(nonce) }
    expect(sent_back).not_to be_nil, "this server negotiated echo-message and msgid but the send never came back"
    expect(sent_back.ref.native_id).to eq(native_id.to_s)

    if caps.reactions?
      reaction = Rubotty::Core::Reaction.new(emoji: "✅")
      adapter.sync_reactions(endpoint, native_id, desired: [reaction], previous: [])
      added = LiveGateway.wait_for_message(dispatcher) do |m|
        m.kind == :reaction_add && m.ref.native_id == native_id.to_s
      end
      expect(added).not_to be_nil, "never saw the reaction add come back live"

      adapter.sync_reactions(endpoint, native_id, desired: [], previous: [reaction])
      removed = LiveGateway.wait_for_message(dispatcher) do |m|
        m.kind == :reaction_remove && m.ref.native_id == native_id.to_s
      end
      expect(removed).not_to be_nil, "never saw the reaction remove come back live"
    else
      warn "  (skipping the reaction leg: this server did not negotiate message-tags+msgid)"
    end

    if caps.deletes?
      adapter.delete(endpoint, native_id)
      deleted_back = LiveGateway.wait_for_message(dispatcher) { |m| m.kind == :delete && m.ref.native_id == native_id.to_s }
      expect(deleted_back).not_to be_nil, "never saw the delete come back live"
    else
      warn "  (skipping the delete leg: this server did not negotiate draft/message-redaction)"
    end
  end
end
