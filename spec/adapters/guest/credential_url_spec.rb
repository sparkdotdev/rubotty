# frozen_string_literal: true

require "spec_helper"

# A guest is an outsider holding one room of one community for a bounded
# time. A Telegram file URL spells the bot token in its path, reaching
# every chat the bot serves in every community, so it can never reach a
# guest. Every other outbound adapter already gates this through Util::SafeUrl.
RSpec.describe Rubotty::Adapters::Guest::Adapter, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models) }
  let(:feed) { Rubotty::ControlPlane::GuestFeed.new(models: models) }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }

  # The shape Telegram's getFile answers with: the bot token is a path segment.
  let(:credentialed_url) { "https://api.telegram.org/file/bot123456:AAH0ffP-secret/photos/file_7.jpg" }

  subject(:adapter) do
    described_class.new(dispatcher: dispatcher, feed: feed, invites: invites, models: models,
                        registry: registry, logger: Rubotty::Log.null)
  end

  def guest_endpoint = registry.current.topology.endpoint(Rubotty::Adapters::Guest.endpoint_key_for(room.id))

  def message_with(url)
    Rubotty::Core::Message.new(
      kind: :chat, ref: Rubotty::Core::MessageRef.new("tg-general", "99"),
      origin: registry.current.topology.endpoint("tg-general"),
      author: Rubotty::Core::Author.new(username: "ada"),
      body: Rubotty::Core::RichText.plain("look at this"),
      attachments: [Rubotty::Core::Attachment.new(kind: :photo, url: url, filename: "holiday.jpg")],
      sender_label: Rubotty::Core::SenderLabel.new(username: "ada", platform: "telegram")
    )
  end

  before do
    controls.enable(community: community, selector: "general", feature: "guest_portal")
    registry.reload
    invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600)
  end

  it "never writes a credentialed URL into the stored guest feed row" do
    adapter.deliver(message_with(credentialed_url), guest_endpoint)
    stored = models.guest_message.where(direction: "in").first.attachments.to_s
    expect(stored).not_to include("bot123456")
    expect(stored).not_to include("AAH0ffP-secret")
  end

  it "still names the file, so a guest is told something was shared" do
    adapter.deliver(message_with(credentialed_url), guest_endpoint)
    stored = models.guest_message.where(direction: "in").first.attachments.to_s
    expect(stored).to include("holiday.jpg")
  end

  it "carries an ordinary CDN URL through untouched" do
    adapter.deliver(message_with("https://cdn.discordapp.com/attachments/1/2/holiday.jpg"), guest_endpoint)
    stored = models.guest_message.where(direction: "in").first.attachments.to_s
    expect(stored).to include("cdn.discordapp.com/attachments/1/2/holiday.jpg")
  end
end
