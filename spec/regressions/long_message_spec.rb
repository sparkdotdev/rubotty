# frozen_string_literal: true

require "spec_helper"

# Discord's message content limit is 2000 characters and Telegram's is 4096, so
# an ordinary Telegram message can exceed a Discord message body. The bridge used
# to cut at 2000 and append an ellipsis; over 2000 it now takes the embed path,
# whose description holds 4096 and so covers Telegram's whole range.
RSpec.describe "long messages cross without losing content" do
  let(:client) { DiscordFakes::Client.new }
  let(:channel) { client.channel("111") }
  let(:hook) { DiscordFakes::WebhookClient.new }

  def place(**settings)
    endpoint("dc", adapter: :discord,
                   settings: { channel_id: "111", webhook: :off }.merge(settings))
  end

  def adapter_for(endpoint_value)
    Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "DC" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
      endpoints: [endpoint_value]
    ).replace_client(client).tap(&:start)
  end

  def deliver(text, endpoint_value)
    outgoing = message(endpoint_value, text: text).with(sender_label: "Alex")
    adapter_for(endpoint_value).deliver(outgoing, endpoint_value)
  end

  describe "posting as the bot" do
    it "sends a long message as an embed rather than truncating it" do
      target = place
      deliver("x" * 3000, target)
      sent = channel.sent.first
      expect(sent[:embed]).not_to be_nil
      expect(sent[:content].to_s).to eq("")
    end

    it "keeps the whole body" do
      target = place
      body = "y" * 3000
      deliver(body, target)
      expect(channel.sent.first[:embed].description).to include(body[0, 2500])
    end

    it "covers Telegram's entire 4096 character range" do
      target = place
      deliver("z" * 4096, target)
      description = channel.sent.first[:embed].description
      expect(description.length).to be >= 4000
      expect(description).not_to end_with("…")
    end

    it "leaves a short message as ordinary text" do
      target = place
      deliver("short and sweet", target)
      expect(channel.sent.first[:embed]).to be_nil
      expect(channel.sent.first[:content]).to include("short and sweet")
    end

    it "still suppresses mass mentions inside an embed" do
      target = place
      deliver("x" * 3000, target)
      expect(channel.sent.first[:allowed_mentions]).to eq(parse: [], users: [], roles: [])
    end

    it "always uses an embed when the operator asks for always" do
      target = place(use_embeds: :always)
      deliver("short", target)
      expect(channel.sent.first[:embed]).not_to be_nil
    end

    # An operator who prefers plain text can have it, and accepts the loss.
    it "truncates when the operator turns embeds off" do
      target = place(use_embeds: :never)
      deliver("x" * 3000, target)
      expect(channel.sent.first[:embed]).to be_nil
      expect(channel.sent.first[:content].length).to eq(2000)
    end
  end

  describe "posting through a webhook" do
    it "sends a long message as an embed" do
      target = place(webhook: :auto)
      adapter = adapter_for(target)
      allow(adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
      adapter.deliver(message(target, text: "x" * 3000).with(sender_label: "Alex"), target)
      expect(hook.executed.first[:embeds]).not_to be_empty
    end

    it "keeps a short message as ordinary text" do
      target = place(webhook: :auto)
      adapter = adapter_for(target)
      allow(adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
      adapter.deliver(message(target, text: "hello").with(sender_label: "Alex"), target)
      expect(hook.executed.first[:embeds]).to be_empty
      expect(hook.executed.first[:content]).to eq("hello")
    end
  end

  describe Rubotty::Adapters::Discord::Outbound do
    subject(:outbound) { described_class.new }

    it "decides on an embed by length under auto" do
      target = endpoint("dc", adapter: :discord, settings: { channel_id: "1" })
      expect(outbound.embed?("short", target)).to be(false)
      expect(outbound.embed?("x" * 2001, target)).to be(true)
    end

    it "clamps an embed at Discord's 4096 description limit" do
      payload = outbound.embed_for("x" * 9000)
      expect(payload[:description].length).to eq(4096)
    end
  end
end
