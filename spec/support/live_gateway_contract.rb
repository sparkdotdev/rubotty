# frozen_string_literal: true

require "securerandom"

# One scripted pass through Adapters::Base's real interface, against a real,
# credentialed connection: connect, send, watch it come back over the gateway
# itself (not the REST call's 2xx), edit, react, unreact, delete; an unsupported
# leg is logged, not dropped. IRC skips this: it never echoes a PRIVMSG back.
RSpec.shared_examples "a live platform adapter" do
  it "sends, receives, edits, reacts to and deletes a real message over the live connection" do
    adapter.start
    expect(LiveGateway.wait_until { adapter.running? })
      .to be_truthy, "the adapter never reported itself running against the real gateway"

    caps = adapter.capabilities_for(endpoint)
    nonce = "rubotty-live-#{SecureRandom.hex(6)}"

    receipt = adapter.deliver(message(endpoint, text: "rubotty live check #{nonce}"), endpoint)
    expect(receipt).not_to be_nil
    native_id = receipt.native_id
    expect(native_id).not_to be_nil

    sent_back = LiveGateway.wait_for_message(dispatcher) { |m| m.kind == :chat && m.body.to_s.include?(nonce) }
    expect(sent_back).not_to be_nil,
      "never saw the message carrying #{nonce} come back over the live connection within " \
      "#{LiveGateway::DEFAULT_TIMEOUT}s: either the platform is not reflecting our own sends the way " \
      "this contract assumes, or the room/channel is wrong"
    expect(sent_back.ref.native_id).to eq(native_id.to_s)

    exercise_edit(caps, native_id, nonce)
    exercise_reactions(caps, native_id)
    exercise_mention(nonce)

    adapter.delete(endpoint, native_id)
    deleted_back = LiveGateway.wait_for_message(dispatcher) { |m| m.kind == :delete && m.ref.native_id == native_id.to_s }
    expect(deleted_back).not_to be_nil, "never saw the delete come back live"
  ensure
    adapter.stop
  end

  def exercise_edit(caps, native_id, nonce)
    unless caps.edits?
      warn "  (skipping the edit leg: #{adapter.class} reports edits? false for this endpoint)"
      return
    end

    edited_nonce = "#{nonce}-edited"
    adapter.edit(message(endpoint, text: "rubotty live check #{edited_nonce}"), endpoint, native_id)
    edited_back = LiveGateway.wait_for_message(dispatcher) { |m| m.kind == :edit && m.body.to_s.include?(edited_nonce) }
    expect(edited_back).not_to be_nil, "never saw the edit carrying #{edited_nonce} come back live"
  end

  def exercise_reactions(caps, native_id)
    unless caps.reactions?
      warn "  (skipping the reaction leg: #{adapter.class} reports reactions? false for this endpoint)"
      return
    end

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
  end

  def exercise_mention(nonce)
    return unless respond_to?(:mention_token)

    token = mention_token(adapter)
    return if token.to_s.empty?

    mention_nonce = "#{nonce}-mention"
    adapter.deliver(message(endpoint, text: "#{token} #{mention_nonce}"), endpoint)
    mentioned_back = LiveGateway.wait_for_message(dispatcher) { |m| m.kind == :chat && m.body.to_s.include?(mention_nonce) }
    expect(mentioned_back).not_to be_nil, "never saw the message carrying a native self mention come back live"
  end
end
