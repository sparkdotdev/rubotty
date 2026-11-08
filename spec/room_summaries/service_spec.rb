# frozen_string_literal: true

require "spec_helper"
require "delegate"

RSpec.describe Rubotty::RoomSummaries::Service, :control_plane do
  include Builders

  SummaryJob = Struct.new(:payload, :community, keyword_init: true)

  class SummaryScheduler
    attr_reader :registered, :jobs, :forgotten, :max_ages

    def initialize
      @registered = {}
      @jobs = []
      @forgotten = []
      @max_ages = {}
    end

    def register(kind, max_age: nil, priority: nil, &block)
      @registered[kind] = block
      @max_ages[kind] = max_age
    end

    def schedule(**job)
      @jobs << job
      @jobs.length
    end

    def forget(**scope)
      @forgotten << scope
      0
    end
  end

  class SummaryClient
    attr_reader :requests

    def initialize(summary = "The room agreed. [messageId:1]")
      @summary = summary
      @requests = []
    end

    def complete(messages:, max_tokens:, feature:, community_id:, options: {}, retried: false)
      @requests << { messages: messages, max_tokens: max_tokens, options: options,
                     feature: feature, community_id: community_id, retried: retried }
      raise @summary if @summary.is_a?(Class)

      @summary
    end
  end

  # Answers the second, plain call and refuses the first, the way a
  # deployment that does not understand the thinking field would.
  class SummaryPickyClient < SummaryClient
    def complete(messages:, max_tokens:, feature:, community_id:, options: {}, retried: false)
      super
      # 4xx, which is a permanent refusal: the only failure the plain retry is
      # for. Anything else re-raises, since asking a busy card again at once
      # only made it busier.
      unless options.empty?
        raise Rubotty::OpenArc::Client::Error.new("OpenArc answered HTTP 400", permanent: true)
      end

      @summary
    end
  end

  # Wraps a real Archive and raises out of #complete exactly once, so a spec
  # can drive the same job through run() twice and observe the second pass
  # picking up after the interrupted first one rather than redoing it.
  class FlakyArchive < SimpleDelegator
    def initialize(archive)
      super
      @raise_next = true
    end

    def complete(**args)
      if @raise_next
        @raise_next = false
        raise "storage blip"
      end
      super
    end
  end

  class SummaryEphemeral
    attr_reader :posts

    def initialize(deliver: true)
      @deliver = deliver
      @posts = []
    end

    # A fresh native id per call, so a caller distinguishing this summary's
    # copies from an earlier cycle's (pin tracking) has something to key on.
    def post(endpoints:, **spec)
      @posts << spec.merge(endpoints: endpoints)
      native_id = "summary-#{@posts.length}"
      copies = @deliver ? endpoints.map { |endpoint| Rubotty::Core::EphemeralMessage::Copy.new(endpoint: endpoint, native_id: native_id) } : []
      Struct.new(:copies).new(copies)
    end
  end

  class SummaryAdapter
    def message_permalink(endpoint, native_id) = "https://example.test/#{endpoint.id}/#{native_id}"
  end

  # Also moderates: pins and unpins, recording every call it was asked to make.
  class SummaryModeratingAdapter
    CAPABILITIES = Rubotty::Adapters::Capabilities.new(moderation: %i[pin unpin]).freeze

    attr_reader :moderations

    def initialize
      @moderations = []
    end

    def capabilities_for(_endpoint) = CAPABILITIES

    def moderate(command, endpoint, native_id)
      @moderations << { action: command.action, endpoint_id: endpoint.id, native_id: native_id }
      Rubotty::Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)
    end
  end

  SummaryCommunity = Struct.new(:id, :slug, :name, :topology, :mode, :config, keyword_init: true) do
    def rooms = topology.rooms

    def room_key_of(channel_or_key)
      key = channel_or_key.respond_to?(:endpoint_key) ? channel_or_key.endpoint_key : channel_or_key.to_s
      rooms.find { |room| room.include?(key) }&.id
    end

    def feature_enabled?(_channel_or_key, _feature) = !mode.nil?

    def feature_config(_channel_or_key, _feature) = { mode: mode }.merge(config || {})
  end

  SummarySnapshot = Struct.new(:communities)
  SummaryRegistry = Struct.new(:current)
  SummaryContext = Struct.new(:community, :channel, :message)

  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.utc(2026, 8, 16, 12) }
  let(:source) { endpoint("discord-general", adapter: :discord, account: "bot", settings: { guild_id: "g", channel_id: "c" }) }
  let(:target) { endpoint("telegram-general", adapter: :telegram, account: "bot") }
  let(:room) { Rubotty::Core::Room.new(id: "general", endpoints: [source, target], label: "General") }
  let(:community_row) do
    models.community.create(
      slug: "first", name: "First", status: "active", settings: "{}", created_at: now, updated_at: now
    )
  end
  let(:community) do
    SummaryCommunity.new(
      id: community_row.id, slug: community_row.slug, name: community_row.name,
      topology: topology(room), mode: mode, config: config
    )
  end
  let(:mode) { "command" }
  let(:config) { {} }
  let(:registry) { SummaryRegistry.new(SummarySnapshot.new([community])) }
  let(:scheduler) { SummaryScheduler.new }
  let(:client) { SummaryClient.new }
  let(:ephemeral) { SummaryEphemeral.new }
  let(:settings) do
    Rubotty::OpenArc::Settings.new(store: Struct.new(:url, :api_key).new("http://openarc.example", nil))
  end
  let(:service) do
    described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: client, clock: -> { now }
    )
  end

  def context(native_id: "1", text: "Please ship it")
    SummaryContext.new(community, source.id, message(source, native_id: native_id, text: text))
  end

  it "registers its scheduler handler with a max_age, so an old stuck backlog job discards rather than replays" do
    service

    expect(scheduler.max_ages["room_summary"]).to eq(described_class::MAX_AGE)
    expect(scheduler.max_ages["room_summary"]).to be_a(Numeric)
  end

  it "delivers a room-only summary with a platform link, then advances its watermark" do
    service.record(context)
    service.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))

    expect(client.requests.first[:messages].last[:content]).to include("Community: First", "Room: General", "Please ship it")
    expect(ephemeral.posts.first[:body].text).to include("https://example.test/discord-general/1")
    expect(service.archive.messages(community_id: community.id, room_key: room.id)).to be_empty
    watermark = models.room_summary_watermark.where(community_id: community.id, room_key: room.id).first
    expect(watermark.last_message_id).to eq(1)
  end

  it "leaves retained text and its watermark untouched when not every platform accepted the summary" do
    failing_ephemeral = SummaryEphemeral.new(deliver: false)
    failing = described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: failing_ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: client, clock: -> { now }
    )
    failing.record(context)

    expect do
      failing.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))
    end.to raise_error(Rubotty::RoomSummaries::Service::DeliveryError)
    expect(failing.archive.pending?(community_id: community.id, room_key: room.id)).to be(true)
    expect(models.room_summary_watermark.where(community_id: community.id, room_key: room.id).count).to eq(0)
  end

  it "stays silent and does not call the endpoint when there is no new source text" do
    service.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))

    expect(client.requests).to be_empty
    expect(ephemeral.posts).to be_empty
  end

  context "when daily mode is enabled" do
    let(:mode) { "daily" }

    it "schedules one recurring UTC-midnight run for the room" do
      expect(service.reconcile).to eq(1)

      job = scheduler.jobs.first
      expect(job).to include(kind: "room_summary", recurrence: 86_400, community: "first")
      expect(job[:run_at]).to eq(Time.utc(2026, 8, 17))
      expect(job[:payload]).to include("mode" => "daily", "room_key" => "general")
    end
  end

  # now is Time.utc(2026, 8, 16, 12), a Sunday.
  context "when weekly mode is enabled" do
    let(:mode) { "weekly" }

    context "with a weekday later in the week" do
      let(:config) { { weekday: "wednesday" } }

      it "schedules one recurring weekly run for the next occurrence of that weekday" do
        expect(service.reconcile).to eq(1)

        job = scheduler.jobs.first
        expect(job).to include(kind: "room_summary", recurrence: 7 * 86_400, community: "first")
        expect(job[:run_at]).to eq(Time.utc(2026, 8, 19))
        expect(job[:payload]).to include("mode" => "weekly", "room_key" => "general")
      end
    end

    context "when the configured weekday is today" do
      let(:config) { { weekday: "sunday" } }

      it "pushes a full week out rather than firing immediately" do
        service.reconcile

        expect(scheduler.jobs.first[:run_at]).to eq(Time.utc(2026, 8, 23))
      end
    end
  end

  context "when monthly mode is enabled" do
    let(:mode) { "monthly" }
    let(:config) { { day_of_month: 20 } }

    it "schedules one one-shot run for the next occurrence of the configured day, with no fixed recurrence" do
      expect(service.reconcile).to eq(1)

      job = scheduler.jobs.first
      expect(job).to include(kind: "room_summary", community: "first")
      expect(job[:recurrence]).to be_nil
      expect(job[:run_at]).to eq(Time.utc(2026, 8, 20))
      expect(job[:payload]).to include("mode" => "monthly", "room_key" => "general")
    end

    context "when the configured day is today" do
      let(:config) { { day_of_month: 16 } }

      it "re-schedules itself for next month's occurrence after it runs" do
        service.record(context)

        service.run(
          SummaryJob.new(payload: { "mode" => "monthly", "community" => "first", "room_key" => "general" }, community: "first")
        )

        job = scheduler.jobs.last
        expect(job[:run_at]).to eq(Time.utc(2026, 9, 16))
        expect(job[:payload]).to include("mode" => "monthly")
      end
    end
  end

  context "when min_messages is configured" do
    let(:mode) { "daily" }
    let(:config) { { min_messages: 3 } }

    def run_daily
      service.run(
        SummaryJob.new(payload: { "mode" => "daily", "community" => "first", "room_key" => "general" }, community: "first")
      )
    end

    it "skips a cycle below the threshold, leaving messages pending for the next one" do
      service.record(context(native_id: "1"))
      service.record(context(native_id: "2"))

      run_daily

      expect(client.requests).to be_empty
      expect(service.archive.pending?(community_id: community.id, room_key: room.id)).to be(true)
      expect(models.room_summary_watermark.where(community_id: community.id, room_key: room.id).count).to eq(0)
    end

    it "posts and advances the watermark once the threshold is met" do
      service.record(context(native_id: "1"))
      service.record(context(native_id: "2"))
      service.record(context(native_id: "3"))

      run_daily

      expect(client.requests.length).to eq(1)
      expect(service.archive.pending?(community_id: community.id, room_key: room.id)).to be(false)
    end
  end

  context "when count mode is enabled" do
    let(:mode) { "count" }
    let(:config) { { message_threshold: 2 } }

    it "fires an immediate one-shot run only once the threshold is crossed" do
      service.record(context(native_id: "1"))
      expect(scheduler.jobs).to be_empty

      service.record(context(native_id: "2"))

      expect(scheduler.jobs.length).to eq(1)
      job = scheduler.jobs.first
      expect(job).to include(kind: "room_summary", run_at: now, community: "first")
      expect(job[:payload]).to include("mode" => "count", "room_key" => "general")
    end

    it "delivers and advances the watermark when the triggered job runs" do
      service.record(context(native_id: "1"))
      service.record(context(native_id: "2"))
      job_payload = scheduler.jobs.first[:payload]

      service.run(SummaryJob.new(payload: job_payload, community: "first"))

      expect(client.requests.length).to eq(1)
      expect(service.archive.pending?(community_id: community.id, room_key: room.id)).to be(false)
    end
  end

  context "when pin is enabled" do
    let(:mode) { "daily" }
    let(:config) { { pin: true } }
    let(:moderating_adapter) { SummaryModeratingAdapter.new }
    let(:pinning_service) do
      described_class.new(
        models: models, registry: registry, scheduler: scheduler,
        adapters: { [:discord, "bot"] => moderating_adapter, [:telegram, "bot"] => moderating_adapter },
        ephemeral: ephemeral, settings: settings, logger: Rubotty::Log.null, client: client, clock: -> { now }
      )
    end

    def run_daily(service_to_run)
      service_to_run.run(
        SummaryJob.new(payload: { "mode" => "daily", "community" => "first", "room_key" => "general" }, community: "first")
      )
    end

    it "pins the new summary on every endpoint that supports it, with no unpin the first time" do
      pinning_service.record(context(native_id: "1"))
      run_daily(pinning_service)

      pins = moderating_adapter.moderations.select { |m| m[:action] == :pin }
      expect(pins.map { |m| m[:endpoint_id] }).to contain_exactly("discord-general", "telegram-general")
      expect(moderating_adapter.moderations.none? { |m| m[:action] == :unpin }).to be(true)
    end

    it "unpins its own previous summary before pinning the new one on the next cycle" do
      pinning_service.record(context(native_id: "1"))
      run_daily(pinning_service)
      first_pin = moderating_adapter.moderations.find { |m| m[:action] == :pin && m[:endpoint_id] == "discord-general" }

      pinning_service.record(context(native_id: "2"))
      run_daily(pinning_service)

      unpin = moderating_adapter.moderations.find { |m| m[:action] == :unpin && m[:endpoint_id] == "discord-general" }
      expect(unpin[:native_id]).to eq(first_pin[:native_id])
    end

    it "tracks the pinned native id per room and endpoint" do
      pinning_service.record(context(native_id: "1"))
      run_daily(pinning_service)

      pinned = moderating_adapter.moderations.find { |m| m[:action] == :pin && m[:endpoint_id] == "discord-general" }
      tracked = models.room_summary_pin.where(
        community_id: community.id, room_key: "general", endpoint_id: "discord-general"
      ).first
      expect(tracked.native_id).to eq(pinned[:native_id])
    end
  end

  context "when pin is enabled but the adapter has no pin capability" do
    let(:mode) { "daily" }
    let(:config) { { pin: true } }

    it "posts the summary without pinning, and does not raise" do
      service.record(context(native_id: "1"))

      expect do
        service.run(
          SummaryJob.new(payload: { "mode" => "daily", "community" => "first", "room_key" => "general" }, community: "first")
        )
      end.not_to raise_error

      expect(models.room_summary_pin.count).to eq(0)
    end
  end

  def run_command
    service.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))
  end

  it "asks for the summary without deliberation, in the request and in the prompt" do
    service.record(context)

    run_command

    request = client.requests.first
    expect(request[:options]).to eq(chat_template_kwargs: { enable_thinking: false })
    expect(request[:messages].last[:content]).to end_with("/no_think")
  end

  it "tells the model to describe offensive language rather than quote it" do
    service.record(context)

    run_command

    system_prompt = client.requests.first[:messages].first[:content]
    expect(system_prompt).to include("Never quote a slur, profanity, or other offensive language verbatim")
  end

  it "asks again without the thinking field where the deployment refuses it" do
    picky = SummaryPickyClient.new
    quiet = described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: picky, clock: -> { now }
    )
    quiet.record(context)

    quiet.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))

    expect(picky.requests.map { |request| request[:options] }).to eq([described_class::NO_THINKING, {}])
    expect(ephemeral.posts.length).to eq(1)
  end

  # A reasoning model can spend its whole budget thinking out loud and never
  # reach the summary, which must raise as a clean failure rather than post
  # raw deliberation text into the room.
  # A rejected answer used to leave only a warn line, which a restart wipes.
  it "counts an unreadable answer against the model performance report" do
    counted = []
    stats = Class.new do
      def initialize(sink) = @sink = sink

      def unusable(community_id:, feature:, step: 1) = @sink << [community_id, feature, step]
    end.new(counted)
    thinking = SummaryClient.new("<think>Still deciding what to say about this room and never finishing")
    service = described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: thinking, stats: stats, clock: -> { now }
    )
    service.record(context)

    expect do
      service.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))
    end.to raise_error(Rubotty::RoomSummaries::Service::SummaryError)
    expect(counted.map(&:last)).to eq([1])
    expect(counted.first[1]).to eq("room_summaries")
  end

  it "raises rather than posting when the whole answer is an unfinished thinking block" do
    thinking = SummaryClient.new(
      "<think>Okay, let's tackle this query. The user wants a short factual summary of the chat room, using"
    )
    leaking = described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: thinking, clock: -> { now }
    )
    leaking.record(context)

    expect do
      leaking.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))
    end.to raise_error(Rubotty::RoomSummaries::Service::SummaryError, /no summary/)
    expect(ephemeral.posts).to be_empty
  end

  it "posts the summary that follows a closed thinking block" do
    closed = SummaryClient.new(
      "<think>The room only ever discussed shipping.</think>\nThe room agreed to ship. [messageId:1]"
    )
    thoughtful = described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: closed, clock: -> { now }
    )
    thoughtful.record(context)

    thoughtful.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))

    expect(ephemeral.posts.first[:body].text).to eq("Room summary:\nThe room agreed to ship. https://example.test/discord-general/1")
  end

  it "turns a [messageId:N] citation into a real platform link" do
    service.record(context)

    run_command

    expect(ephemeral.posts.first[:body].text).to eq("Room summary:\nThe room agreed. https://example.test/discord-general/1")
  end

  it "drops a citation-shaped token the model wrote as a range instead of one message id" do
    ranged = SummaryClient.new("The room covered several things. [messageId:1-3, 5]")
    vague = described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: ranged, clock: -> { now }
    )
    vague.record(context)

    vague.run(SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first"))

    expect(ephemeral.posts.first[:body].text).to eq("Room summary:\nThe room covered several things.")
  end

  # The spam bug regression test: FlakyArchive fails #complete once, right
  # after a real post already landed, the way a storage blip would. Running
  # the identical job again must finish the interrupted watermark advance
  # without asking OpenArc or the room a second time.
  it "does not repost on a retry of the same job after a successful post" do
    flaky_archive = FlakyArchive.new(Rubotty::RoomSummaries::Archive.new(models: models, logger: Rubotty::Log.null, clock: -> { now }))
    fragile = described_class.new(
      models: models, registry: registry, scheduler: scheduler,
      adapters: { [:discord, "bot"] => SummaryAdapter.new }, ephemeral: ephemeral,
      settings: settings, logger: Rubotty::Log.null, client: client, archive: flaky_archive, clock: -> { now }
    )
    fragile.record(context)
    job = SummaryJob.new(payload: { "mode" => "command", "community" => "first", "room_key" => "general" }, community: "first")

    expect { fragile.run(job) }.to raise_error("storage blip")
    expect(ephemeral.posts.length).to eq(1)
    expect(client.requests.length).to eq(1)

    fragile.run(job)

    expect(ephemeral.posts.length).to eq(1)
    expect(client.requests.length).to eq(1)
    expect(fragile.archive.pending?(community_id: community.id, room_key: room.id)).to be(false)
    watermark = models.room_summary_watermark.where(community_id: community.id, room_key: room.id).first
    expect(watermark.last_message_id).to eq(1)
  end
end
