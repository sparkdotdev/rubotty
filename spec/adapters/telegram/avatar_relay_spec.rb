# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# A Telegram sender arrives on Discord under their own name, and now with
# their own face, through a link that is not the one Telegram gave (that one
# carries the bot token).
RSpec.describe "relaying a Telegram sender's avatar", :control_plane do
  # Stands in for Util::MediaFetcher on the same #with(url, filename:) contract.
  class RelayPhotoFetcher
    def with(_url, filename: nil)
      io = StringIO.new("png bytes")
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  # Enough of a Snapshot::Community for the adapter's per-message feature check,
  # and, since #1419, for finding whether the channel's room has anywhere else
  # to puppet the sender.
  class AvatarCommunity
    def initialize(id:, enabled:, room: nil)
      @id = id
      @enabled = enabled
      @room = room
    end

    attr_reader :id

    def feature_enabled?(_channel, feature) = feature == "telegram_avatars" && @enabled

    def feature_config(_channel, _feature) = {}

    def room_key_of(_channel) = @room&.id

    def rooms = @room ? [@room] : []
  end

  # The live resolver the adapter reads its endpoint and its community from.
  class AvatarRoutes
    def initialize(endpoint:, community:, channel:)
      @endpoint = endpoint
      @community = community
      @channel = channel
    end

    def endpoint_for(_adapter, _account, _route_key) = @endpoint

    def route(_adapter, _account, _route_key) = [@community, @channel]
  end

  around do |example|
    Dir.mktmpdir("rubotty-avatar-relay") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  # The copy happens on a worker thread, so an example that leaves one running
  # would still be writing into the store directory while the block above is
  # removing it.
  after { telegram.avatars&.stop }

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_id) { models.community.where(slug: "sample").first[:id] }
  let(:enabled) { true }
  # Bridged with a second, sending platform by default, so the picture has
  # somewhere to go; the "single-platform room" examples below override this
  # with a room holding only the Telegram endpoint.
  let(:puppet_room) { room("lobby", tg_endpoint, dc_endpoint) }
  let(:community) { AvatarCommunity.new(id: community_id, enabled: enabled, room: puppet_room) }
  let(:tg_channel) do
    Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg_endpoint, community_id: community_id, route_key: "lobby")
  end

  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:files) { Rubotty::ControlPlane::RehostedFiles.new(models: models, store: store) }
  let(:rehoster) do
    Rubotty::Core::AttachmentRehoster.new(
      files: files, fetcher_for: ->(_limit) { RelayPhotoFetcher.new },
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end

  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:tg_endpoint) { endpoint("tg-lobby", adapter: :telegram, settings: { chat_id: "-1008000000001" }) }

  let(:telegram) do
    described = Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg",
      settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [tg_endpoint],
      endpoint_resolver: AvatarRoutes.new(endpoint: tg_endpoint, community: community, channel: tg_channel)
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    described.rehoster = rehoster
    described
  end

  # What Telegram answers, and what its file URL really looks like.
  let(:file_path) { "profile_photos/file_9.jpg" }
  let(:telegram_file_url) { "https://api.telegram.org/file/bot123:abc/#{file_path}" }

  def update(id)
    {
      "update_id" => id,
      "message" => {
        "message_id" => 100 + id,
        "date" => 1_700_000_000,
        "chat" => { "id" => -1008000000001, "type" => "supergroup" },
        "from" => { "id" => 55, "first_name" => "Ada", "username" => "ada", "is_bot" => false },
        "text" => "hello"
      }
    }
  end

  def answer_telegram
    http.on("getUserProfilePhotos",
            { "total_count" => 1,
              "photos" => [[{ "file_id" => "photo-1", "width" => 640 }]] })
    http.on("getFile", { "file_path" => file_path })
  end

  describe "with the community's telegram_avatars feature on" do
    before { answer_telegram }

    # The first message pays nothing and carries nothing; the copy is made behind
    # it and every message after that has the picture.
    it "gives the second message the sender's own picture" do
      telegram.handle_update(update(1))
      expect(dispatcher.last.author.avatar_url).to be_nil

      telegram.avatars.stop
      telegram.handle_update(update(2))

      expect(dispatcher.last.author.avatar_url).to start_with("https://rubotty.test/filestorage/")
    end

    it "hands out a link with no bot token in it, which is the point of the copy" do
      telegram.handle_update(update(1))
      telegram.avatars.stop
      telegram.handle_update(update(2))
      avatar = dispatcher.last.author.avatar_url

      expect(avatar).not_to include("api.telegram.org")
      expect(Rubotty::Util::SafeUrl.credentialed?(avatar)).to be(false)
      expect(Rubotty::Util::SafeUrl.public(avatar)).to eq(avatar)
    end

    # Every outbound puppeting path runs the avatar through SafeUrl, so this is
    # what the raw Telegram URL would have become had it ever got this far.
    it "reaches the Discord webhook payload as the copied link" do
      telegram.handle_update(update(1))
      telegram.avatars.stop
      telegram.handle_update(update(2))
      relayed = dispatcher.last.with(sender_label: "Ada (ada)")

      discord.deliver(relayed, dc_endpoint)

      expect(hook.executed.first[:avatar_url]).to eq(dispatcher.last.author.avatar_url)
      expect(hook.executed.first[:avatar_url]).not_to include("bot123:abc")
    end

    it "never puts the Telegram file URL on the author, even before the copy exists" do
      telegram.handle_update(update(1))

      expect(dispatcher.last.author.avatar_url).to be_nil
      expect(telegram_file_url).to include("bot123:abc")
    end

    # A reply preview is rendered as text, so looking a picture up for its author
    # would be Bot API traffic nobody ever sees.
    it "looks up one picture per message, for the sender and not the reply parent" do
      telegram.handle_update(
        update(1).tap do |raw|
          raw["message"]["reply_to_message"] = {
            "message_id" => 90, "text" => "earlier",
            "chat" => { "id" => -1008000000001 },
            "from" => { "id" => 66, "first_name" => "Bo", "is_bot" => false }
          }
        end
      )
      telegram.avatars.stop

      expect(http.calls("getUserProfilePhotos").size).to eq(1)
      expect(http.last("getUserProfilePhotos").params["user_id"]).to eq("55")
    end
  end

  describe "with the feature off, which is the default" do
    let(:enabled) { false }

    before { answer_telegram }

    it "relays exactly as it did before: no picture and no Bot API call" do
      telegram.handle_update(update(1))
      telegram.handle_update(update(2))

      expect(dispatcher.messages.map { |m| m.author.avatar_url }).to eq([nil, nil])
      expect(http.called?("getUserProfilePhotos")).to be(false)
      expect(models.rehosted_file.count).to eq(0)
    end

    it "still relays the sender's name and body" do
      telegram.handle_update(update(1))

      expect(dispatcher.last.author.username).to eq("ada")
      expect(dispatcher.last.body.to_s).to eq("hello")
    end
  end

  # #1419: a Telegram-only room has nowhere to show the copied picture, so
  # switching the feature on there paid its full privacy and storage cost for
  # no benefit at all.
  describe "with the feature on but the room has no second platform to puppet the sender on" do
    let(:puppet_room) { room("solo", tg_endpoint) }

    before { answer_telegram }

    it "relays with no picture and asks Telegram nothing" do
      telegram.handle_update(update(1))
      telegram.handle_update(update(2))

      expect(dispatcher.messages.map { |m| m.author.avatar_url }).to eq([nil, nil])
      expect(http.called?("getUserProfilePhotos")).to be(false)
      expect(models.rehosted_file.count).to eq(0)
    end

    it "still relays the sender's name and body" do
      telegram.handle_update(update(1))

      expect(dispatcher.last.author.username).to eq("ada")
      expect(dispatcher.last.body.to_s).to eq("hello")
    end
  end

  describe "without a rehoster, which is a deployment with no object store" do
    let(:telegram) do
      Rubotty::Adapters::Telegram::Adapter.new(
        account: "tg",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [tg_endpoint],
        endpoint_resolver: AvatarRoutes.new(endpoint: tg_endpoint, community: community, channel: tg_channel)
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    end

    it "relays with no picture and asks Telegram nothing" do
      answer_telegram
      telegram.handle_update(update(1))

      expect(telegram.avatars).to be_nil
      expect(dispatcher.last.author.avatar_url).to be_nil
      expect(http.called?("getUserProfilePhotos")).to be(false)
    end
  end

  # The receiving half, kept out of the way of the tests above.
  let(:discord_client) { DiscordFakes::Client.new }
  let(:hook) { DiscordFakes::WebhookClient.new }
  let(:dc_endpoint) do
    endpoint("dc-general", adapter: :discord,
                           settings: { channel_id: "8000000000000000003", webhook: :auto })
  end
  let(:discord) do
    built = Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
      endpoints: [dc_endpoint]
    ).replace_client(discord_client)
    built.start
    allow(built.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
    built
  end
end
