# frozen_string_literal: true

require "spec_helper"

# Helpers for the dm mode spec below, namespaced so a same-named helper in
# another spec file cannot reopen one of these as a top-level constant.
module DmModeFakes
  DmJob = Struct.new(:payload, :community, keyword_init: true)

  # Records every job asked for, so the enqueue side can be read back.
  class DmScheduler
    attr_reader :jobs

    def initialize = (@jobs = [])

    def register(kind, max_age: nil, priority: nil, &block) = nil

    def schedule(**job)
      @jobs << job
      @jobs.length
    end

    def forget(**scope) = 0
  end

  class DmClient
    def complete(messages:, max_tokens:, feature:, community_id:, options: {}, retried: false)
      "They talked about shipping. [messageId:1]"
    end
  end

  # Says whether it could reach the member, and keeps what it sent.
  class DmAdapter
    attr_reader :dms

    def initialize(reachable: true)
      @reachable = reachable
      @dms = []
    end

    def supports_admin_dm? = true

    def message_permalink(endpoint, native_id) = "https://example.test/#{endpoint.id}/#{native_id}"

    def send_admin_dm(native_id, text)
      return nil unless @reachable

      @dms << { native_id: native_id, text: text }
      Rubotty::Core::DmReceipt.new(native_id: "dm-1", channel_ref: "chan")
    end
  end

  class DmEphemeral
    attr_reader :posts

    def initialize = (@posts = [])

    def post(endpoints:, body:, name:, delete_after: 0, **)
      @posts << { endpoints: endpoints.map(&:id), text: body.to_s, delete_after: delete_after, name: name }
      Struct.new(:copies).new([])
    end
  end

  DmCommunity = Struct.new(:id, :slug, :name, :topology, keyword_init: true) do
    def rooms = topology.rooms

    def room_key_of(channel_or_key)
      key = channel_or_key.respond_to?(:endpoint_key) ? channel_or_key.endpoint_key : channel_or_key.to_s
      rooms.find { |room| room.include?(key) }&.id
    end

    def feature_enabled?(_channel_or_key, _feature) = true

    def feature_config(_channel_or_key, _feature) = { mode: "dm" }
  end

  DmSnapshot = Struct.new(:communities)
  DmRegistry = Struct.new(:current)
  DmContext = Struct.new(:community, :channel, :message)
end

# dm mode answers anybody's /summary privately over a fixed fourteen day
# window. It consumes nothing: one member asking must not take the summary away
# from the next, so no watermark moves and no transcript row is dropped.
RSpec.describe Rubotty::RoomSummaries::Service, "dm mode", :control_plane do
  include Builders

  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.utc(2026, 8, 30, 12) }
  let(:source) { endpoint("tg-general", adapter: :telegram, account: "bot") }
  let(:room) { Rubotty::Core::Room.new(id: "general", endpoints: [source], label: "General") }
  let(:community_row) do
    models.community.create(slug: "first", name: "First", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end
  let(:community) do
    DmModeFakes::DmCommunity.new(id: community_row.id, slug: community_row.slug, name: community_row.name,
                    topology: topology(room))
  end
  let(:registry) { DmModeFakes::DmRegistry.new(DmModeFakes::DmSnapshot.new([community])) }
  let(:scheduler) { DmModeFakes::DmScheduler.new }
  let(:ephemeral) { DmModeFakes::DmEphemeral.new }
  let(:adapter) { DmModeFakes::DmAdapter.new }
  let(:settings) do
    Rubotty::OpenArc::Settings.new(store: Struct.new(:url, :api_key).new("http://openarc.example", nil))
  end

  subject(:service) do
    described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:telegram, "bot"] => adapter }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: DmModeFakes::DmClient.new, clock: -> { now }
    )
  end

  def asking(native_id: "u1")
    DmModeFakes::DmContext.new(community, source.id, message(source, native_id: "cmd", text: "/summary",
                                                        author: author(native_id: native_id)))
  end

  def archived(text: "ship it", at: now - 60)
    models.room_summary_message.create(
      community_id: community_row.id, room_key: "general", endpoint_id: source.id,
      native_id: "m#{models.room_summary_message.count + 1}", author_label: "Ada",
      body: text, created_at: at
    )
  end

  def run_queued
    service.run(DmModeFakes::DmJob.new(payload: scheduler.jobs.last[:payload], community: community.slug))
  end

  describe "queueing one" do
    it "carries who asked and where from, so the answer and any failure both land" do
      archived
      expect(service.enqueue_dm(asking)).to eq(:queued)

      expect(scheduler.jobs.last[:payload]).to include(
        "mode" => "dm", "room_key" => "general", "native_id" => "u1", "origin" => "tg-general"
      )
    end

    it "refuses an author with no id to DM" do
      context = DmModeFakes::DmContext.new(community, source.id,
                              message(source, native_id: "cmd", author: author(native_id: nil)))

      expect(service.enqueue_dm(context)).to eq(:unavailable)
    end
  end

  describe "answering one" do
    it "DMs the member who asked and posts nothing in the room" do
      archived
      service.enqueue_dm(asking)
      run_queued

      expect(adapter.dms.map { |dm| dm[:native_id] }).to eq(["u1"])
      expect(ephemeral.posts).to be_empty
    end

    # The whole point of the mode: asking is a read, so the room's transcript
    # and its boundary are exactly as they were.
    it "consumes nothing, so the next member who asks sees the same window" do
      archived
      service.enqueue_dm(asking)
      run_queued

      expect(models.room_summary_message.count).to eq(1)
      expect(models.room_summary_watermark.count).to eq(0)
    end

    it "reads past a watermark an earlier posted summary left" do
      archived
      models.room_summary_watermark.create(
        community_id: community_row.id, room_key: "general",
        last_message_id: models.room_summary_message.first.id, completed_at: now
      )
      service.enqueue_dm(asking)
      run_queued

      expect(adapter.dms.length).to eq(1)
    end

    it "leaves out anything older than the fourteen day window" do
      archived(text: "ancient", at: now - described_class::DM_WINDOW - 60)
      service.enqueue_dm(asking)
      run_queued

      expect(adapter.dms).to be_empty
      expect(ephemeral.posts.first[:text]).to include("nothing to summarise")
    end
  end

  describe "when the member cannot be reached" do
    let(:adapter) { DmModeFakes::DmAdapter.new(reachable: false) }

    # A bot cannot open a conversation on Telegram, so the only place left to
    # say so is the room, and it has to stand long enough to be read.
    it "says so in the room, for long enough to act on" do
      archived
      service.enqueue_dm(asking)
      run_queued

      notice = ephemeral.posts.first
      expect(notice[:text]).to include("Send me a direct message first")
      expect(notice[:endpoints]).to eq(["tg-general"])
      expect(notice[:delete_after]).to eq(described_class::DM_NOTICE_TTL)
    end
  end
end
