# frozen_string_literal: true

require "spec_helper"

# A message posted through a webhook is not authored by the bot account, so
# the loop guard's self-authorship check cannot see it, and its other two
# defences are populated only after the REST call returns, which the gateway
# can beat, relaying our own message back as a duplicate.
RSpec.describe "our own webhook messages never come back in" do
  let(:client) { DiscordFakes::Client.new }
  let(:channel) { client.channel("111") }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:place) do
    endpoint("dc", adapter: :discord, settings: { channel_id: "111", webhook: :auto })
  end

  subject(:adapter) do
    Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "DC" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [place]
    ).replace_client(client).tap(&:start)
  end

  def arrive(webhook_id:)
    event = DiscordFakes::MessageEvent.new(
      message: DiscordFakes::Message.new(
        id: "900", content: "relayed text",
        author: DiscordFakes.user(id: "999", username: "Alex"),
        webhook_id: webhook_id
      ),
      channel: channel
    )
    adapter.emit_if(adapter.instance_variable_get(:@inbound).message(event))
  end

  it "ignores a message from the webhook this bridge posts through" do
    # Resolving the webhook is what registers its id as ours.
    hook = adapter.instance_variable_get(:@webhooks)
    hook.for(place)
    own_id = channel.created_webhooks.first.id

    arrive(webhook_id: own_id)
    expect(dispatcher.messages).to be_empty
  end

  # Another application's webhook is a legitimate source and must still relay.
  it "still relays a message from somebody else's webhook" do
    adapter.instance_variable_get(:@webhooks).for(place)
    arrive(webhook_id: "some-other-app")
    expect(dispatcher.messages.size).to eq(1)
  end

  it "still relays an ordinary user message" do
    adapter.instance_variable_get(:@webhooks).for(place)
    arrive(webhook_id: nil)
    expect(dispatcher.messages.size).to eq(1)
  end

  # What actually happened in production: the bot restarted, backfill read
  # Discord history before anything had been posted, and every copy the bridge
  # had written looked like a stranger's message.
  describe "backfill reading history after a restart" do
    def replay(webhook_id:)
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(
          id: "901", content: "Alex R [sample_owner@telegram]: hello",
          author: DiscordFakes.user(id: "999", username: "Alex R [sample_owner@telegram]"),
          webhook_id: webhook_id
        ),
        channel: channel
      )
      adapter.instance_variable_get(:@inbound).message(event, replaying: true)
    end

    it "does not re-feed a copy this bridge wrote before the restart" do
      channel.existing_webhooks = [DiscordFakes::Hook.new(id: "555", name: "rubotty", token: "t")]

      expect(replay(webhook_id: "555")).to be_nil
    end

    it "still replays a genuine message from somebody else" do
      channel.existing_webhooks = [DiscordFakes::Hook.new(id: "555", name: "rubotty", token: "t")]

      expect(replay(webhook_id: nil)).not_to be_nil
    end

    # Not being able to tell must stop a replay, since sending twice is worse
    # than missing one. The live path keeps the opposite default.
    it "holds back a webhook copy it cannot identify" do
      channel.webhook_error = "Missing Permissions"

      expect(replay(webhook_id: "555")).to be_nil
    end

    it "still relays that same unidentifiable message when it arrives live" do
      channel.webhook_error = "Missing Permissions"
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(
          id: "902", content: "live text",
          author: DiscordFakes.user(id: "999", username: "Alex"), webhook_id: "555"
        ),
        channel: channel
      )

      expect(adapter.instance_variable_get(:@inbound).message(event)).not_to be_nil
    end
  end

  describe Rubotty::Adapters::Discord::Webhook do
    subject(:webhooks) do
      described_class.new(client: client, logger: Rubotty::Log.null, bridge_name: "rubotty")
    end

    it "recognises a webhook it created" do
      webhooks.for(place)
      expect(webhooks.own_message?(channel.created_webhooks.first.id)).to eq(:ours)
    end

    it "rules out an unrelated webhook once it can see the channel's list" do
      webhooks.for(place)
      expect(webhooks.own_message?("999999", channel: channel)).to eq(:not_ours)
    end

    # Without a channel there is nothing to check against, and saying "not ours"
    # there is the guess that replayed a week of our own copies.
    it "admits it cannot tell when it has neither a memory nor a channel" do
      expect(webhooks.own_message?("999999")).to eq(:unknown)
    end

    it "handles a message with no webhook at all" do
      expect(webhooks.own_message?(nil)).to eq(:not_ours)
    end

    it "recognises a webhook supplied by URL" do
      configured = endpoint(
        "dc2", adapter: :discord,
        settings: { channel_id: "111", webhook_url: "https://discord.com/api/webhooks/12345/tok" }
      )
      webhooks.for(configured)
      expect(webhooks.own_message?("12345")).to eq(:ours)
    end

    # The actual failure. @own_ids is only filled in by posting, so a process
    # that has just booted has never posted and remembers nothing, while the
    # channel is full of copies it wrote before the restart.
    describe "after a restart, having posted nothing yet" do
      it "still recognises a copy it wrote in a previous run" do
        earlier = DiscordFakes::Hook.new(id: "555", name: "rubotty", token: "t")
        channel.existing_webhooks = [earlier]

        expect(webhooks.own_message?("555", channel: channel)).to eq(:ours)
      end

      it "reads the channel once however many messages it is asked about" do
        channel.existing_webhooks = [DiscordFakes::Hook.new(id: "555", name: "rubotty", token: "t")]
        3.times { webhooks.own_message?("555", channel: channel) }

        expect(channel.webhook_list_calls).to eq(1)
      end

      it "says unknown rather than guessing when Discord will not list them" do
        channel.webhook_error = "Missing Permissions"

        expect(webhooks.own_message?("555", channel: channel)).to eq(:unknown)
      end
    end
  end
end
