# frozen_string_literal: true

require "spec_helper"

# A relayed message goes into Fluxer through a webhook, so the copy the gateway
# hands back is authored by the webhook, not the bot account, and the loop
# guard's self-authorship check cannot see it. The other two defences fill in
# only once the REST call returns, which the gateway can beat, causing an echo.
RSpec.describe "our own Fluxer webhook messages never come back in" do
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:gateway) { FluxerFakes::Gateway.new }
  let(:existing) { [] }
  let(:client) { FluxerFakes::Client.new(existing_webhooks: existing) }
  let(:hooked) do
    endpoint("fx-hooked", adapter: :fluxer, settings: { channel_id: "222222222", webhook: :auto })
  end

  subject(:adapter) do
    described_class = Rubotty::Adapters::Fluxer::Adapter
    described_class.new(
      account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [hooked]
    ).replace_client(client).replace_gateway(gateway).tap(&:start)
  end

  # The label a relayed Telegram message wears once Fluxer hands it back.
  def arrive(author_id:, webhook_id: :absent, id: "900", type: "MESSAGE_CREATE")
    payload = {
      "id" => id, "channel_id" => "222222222", "guild_id" => "g1",
      "content" => "hello", "author" => {
        "id" => author_id, "username" => "Alex R [sample_owner@telegram]"
      }
    }
    payload["webhook_id"] = webhook_id unless webhook_id == :absent
    adapter.handle_event({ "t" => type, "d" => payload })
  end

  # Resolving the webhook to post through is what registers its id as ours.
  def resolve_own_webhook
    adapter.instance_variable_get(:@webhooks).for(hooked)
    client.created_webhooks.first["id"]
  end

  describe "with the webhook resolved in this process" do
    it "ignores a copy that names the webhook id it was posted through" do
      own = resolve_own_webhook

      expect(arrive(author_id: "999", webhook_id: own)).to be_nil
      expect(dispatcher.messages).to be_empty
    end

    # Fluxer's payloads mirror Discord's, where a webhook message is authored BY
    # the webhook. Keying only on the dedicated field misses the copy entirely
    # wherever the server omits it.
    it "ignores a copy that carries no webhook_id but is authored by the webhook" do
      own = resolve_own_webhook

      expect(arrive(author_id: own)).to be_nil
      expect(dispatcher.messages).to be_empty
    end

    it "ignores an edit of its own copy, which arrives the same way" do
      own = resolve_own_webhook

      expect(arrive(author_id: "999", webhook_id: own, type: "MESSAGE_UPDATE")).to be_nil
      expect(dispatcher.messages).to be_empty
    end

    # The bot flag on Core::Author feeds anti_raid, the room summaries archive
    # and the identity recorder, so it needs the same recognition the echo guard
    # above uses. Checked directly against Inbound because a copy this bridge
    # wrote is dropped as an echo before an author is ever built for it.
    it "would recognise that same copy's author as a webhook, had it not already been dropped as an echo" do
      own = resolve_own_webhook
      inbound = adapter.instance_variable_get(:@inbound)

      expect(inbound.send(:webhook_author?, { "author" => { "id" => own } })).to be(true)
    end
  end

  # The webhook outlives the process that made it, so a restart starts with an
  # empty set of remembered ids and must ask Fluxer rather than assume a
  # stranger wrote it.
  describe "with a webhook this deployment made before the current process" do
    let(:existing) { [{ "id" => "wh-earlier", "name" => "rubotty", "token" => "tok" }] }

    it "recognises it from Fluxer's own webhook list, without having posted through it yet" do
      expect(arrive(author_id: "999", webhook_id: "wh-earlier")).to be_nil
      expect(dispatcher.messages).to be_empty
    end

    it "reads the channel's webhook list once, however many messages arrive" do
      allow(client).to receive(:list_webhooks).and_call_original

      3.times { |i| arrive(author_id: "999", webhook_id: "wh-earlier", id: "90#{i}") }

      expect(client).to have_received(:list_webhooks).once
    end
  end

  describe "somebody else's traffic" do
    let(:existing) { [{ "id" => "wh-earlier", "name" => "rubotty", "token" => "tok" }] }

    it "still relays another application's webhook, which is a legitimate source" do
      expect(arrive(author_id: "999", webhook_id: "wh-elsewhere")).not_to be_nil
    end

    it "still relays an ordinary user message" do
      expect(arrive(author_id: "55")).not_to be_nil
    end

    # An ordinary message must not pay for a webhook listing on every arrival.
    it "does not read the channel's webhook list for a message naming no webhook" do
      allow(client).to receive(:list_webhooks).and_call_original

      arrive(author_id: "55")

      expect(client).not_to have_received(:list_webhooks)
    end
  end
end
