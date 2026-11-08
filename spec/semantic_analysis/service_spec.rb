# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::SemanticAnalysis::Service do
  include Builders

  SemanticJob = Struct.new(:payload, :community, keyword_init: true)

  class SemanticScheduler
    attr_reader :jobs, :registered

    def initialize
      @jobs = []
      @registered = {}
      @max_ages = {}
    end

    attr_reader :max_ages

    def register(kind, max_age: nil, priority: nil, &block)
      @registered[kind] = block
      @max_ages[kind] = max_age
    end

    def schedule(**job)
      @jobs << job
      @jobs.length
    end
  end

  class SemanticClient
    attr_reader :requests

    def initialize(response = '{"id":"where","confidence":0.91}')
      @response = response
      @requests = []
    end

    def complete(messages:, max_tokens:, feature:, community_id:, options: {}, retried: false)
      @requests << { messages: messages, max_tokens: max_tokens, options: options,
                     feature: feature, community_id: community_id, retried: retried }
      raise @response if @response.is_a?(Class)

      @response
    end
  end

  # Answers the second, plain call and refuses the first, the way a deployment
  # that does not understand the thinking field would.
  class SemanticPickyClient < SemanticClient
    def complete(messages:, max_tokens:, feature:, community_id:, options: {}, retried: false)
      super
      # 4xx, which is a permanent refusal: the only failure the plain retry is
      # for. Anything else re-raises, since asking a busy card again at once
      # only made it busier.
      unless options.empty?
        raise Rubotty::OpenArc::Client::Error.new("OpenArc answered HTTP 400", permanent: true)
      end

      @response
    end
  end

  class SemanticEphemeral
    attr_reader :posts

    def initialize(deliver: true)
      @deliver = deliver
      @posts = []
    end

    def post(endpoints:, **spec)
      @posts << spec.merge(endpoints: endpoints)
      copies = @deliver ? endpoints.map { |endpoint| Rubotty::Core::EphemeralMessage::Copy.new(endpoint: endpoint, native_id: "faq") } : []
      Struct.new(:copies).new(copies)
    end
  end

  SemanticCommunity = Struct.new(:id, :slug, :name, :topology, :features, :configs, keyword_init: true) do
    def rooms = topology.rooms

    def room_key_of(channel_or_key)
      key = channel_or_key.respond_to?(:endpoint_key) ? channel_or_key.endpoint_key : channel_or_key.to_s
      rooms.find { |room| room.include?(key) }&.id
    end

    def feature_enabled?(_channel_or_key, feature) = features.fetch(feature.to_s, false)

    def feature_config(_channel_or_key, feature) = configs.fetch(feature.to_s, {})
  end

  SemanticSnapshot = Struct.new(:communities)
  SemanticRegistry = Struct.new(:current)
  SemanticContext = Struct.new(:community, :channel, :message) do
    def command_prefixes = Rubotty::Core::CommandPrefix.new
  end

  let(:source) { endpoint("telegram-general", adapter: :telegram, account: "bot") }
  let(:other) { endpoint("discord-general", adapter: :discord, account: "bot") }
  let(:room) { Rubotty::Core::Room.new(id: "general", endpoints: [source, other]) }
  let(:features) { { "semantic_analysis" => true, "faq" => false } }
  let(:configs) do
    {
      "semantic_analysis" => { minimum_confidence: 0.82 },
      "faq" => {
        name: "help",
        entries: [
          { id: "where", keyword: "where can I find the rules", response: "Start with #rules." },
          { id: "when", keyword: "when is the next event", response: "See /events." }
        ]
      }
    }
  end
  let(:community) do
    SemanticCommunity.new(
      id: 7, slug: "first", name: "First", topology: topology(room), features: features, configs: configs
    )
  end
  let(:registry) { SemanticRegistry.new(SemanticSnapshot.new([community])) }
  let(:scheduler) { SemanticScheduler.new }
  let(:client) { SemanticClient.new }
  let(:ephemeral) { SemanticEphemeral.new }
  let(:settings) { Rubotty::OpenArc::Settings.new(store: Struct.new(:url, :api_key).new("http://openarc.example", nil)) }
  let(:service) do
    described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: client, logger: Rubotty::Log.null
    )
  end

  def context(text: "Where do I read the rules?", native_id: "1")
    SemanticContext.new(community, source.id, message(source, text: text, native_id: native_id))
  end

  it "queues only the originating room and question, not an answer snapshot" do
    service.enqueue(context)

    job = scheduler.jobs.first
    expect(job).to include(kind: "semantic_faq", community: "first")
    expect(job[:discard_payload]).to be(true)
    expect(job[:payload]).to include("room_key" => "general", "endpoint_id" => "telegram-general")
    expect(job[:payload]).not_to have_key("faq")
  end

  it "posts the current room's selected FAQ answer as a reply after the durable run" do
    service.enqueue(context)
    job = scheduler.jobs.first
    service.run(SemanticJob.new(payload: job[:payload], community: "first"))

    prompt = JSON.parse(client.requests.first[:messages].last[:content][/\{.*\}/m])
    expect(prompt["faq"].map { |entry| entry["id"] }).to eq(%w[where when])
    expect(ephemeral.posts.length).to eq(1)
    expect(ephemeral.posts.first[:endpoints]).to eq([source])
    expect(ephemeral.posts.first[:body].text).to eq("Start with #rules.")
    expect(ephemeral.posts.first[:reply_to]).to eq(Rubotty::Core::MessageRef.new(source.id, "1"))
  end

  it "offers only existing non-command FAQ entries to the background run" do
    configs["faq"][:entries] << { id: "command", command: "rules", response: "Use /rules." }
    service.enqueue(context)

    service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))

    prompt = JSON.parse(client.requests.first[:messages].last[:content][/\{.*\}/m])
    expect(prompt["faq"].map { |entry| entry["id"] }).to eq(%w[where when])
  end

  it "stays silent when no configured FAQ answer meets the confidence" do
    quiet = SemanticClient.new('{"id":null,"confidence":0.12}')
    service = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: quiet, logger: Rubotty::Log.null
    )
    service.enqueue(context)

    service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))

    expect(ephemeral.posts).to be_empty
  end

  it "drops a job whose source endpoint is no longer inside the recorded room" do
    service.enqueue(context)
    payload = scheduler.jobs.first[:payload].merge("endpoint_id" => "missing")

    service.run(SemanticJob.new(payload: payload, community: "first"))

    expect(client.requests).to be_empty
    expect(ephemeral.posts).to be_empty
  end

  it "raises for an invalid decision so the durable scheduler can retry the isolated job" do
    broken = SemanticClient.new('{"id":"missing","confidence":0.9}')
    service = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: broken, logger: Rubotty::Log.null
    )
    service.enqueue(context)

    expect do
      service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))
    end.to raise_error(Rubotty::SemanticAnalysis::Service::DecisionError, /unknown entry/)
  end

  # The shape topic routing was silently dead in for as long as it was enabled
  # (issue #1871): a model wrapping its answer answers no id at all, and reading
  # that as "nothing matched" is indistinguishable from a quiet feature.
  it "rejects an answer carrying no id, rather than reading it as nothing matched" do
    wrapped = SemanticClient.new('{"decision":{"id":"where","confidence":0.9}}')
    service = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: wrapped, logger: Rubotty::Log.null
    )
    service.enqueue(context)

    expect do
      service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))
    end.to raise_error(Rubotty::SemanticAnalysis::Service::DecisionError, /without an id/)
  end

  it "still reads an explicit null id as nothing matching, which the prompt asks for" do
    none = SemanticClient.new('{"id":null,"confidence":0.1}')
    service = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: none, logger: Rubotty::Log.null
    )
    service.enqueue(context)
    service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))

    expect(ephemeral.posts).to be_empty
  end

  # A rejected answer used to leave only a warn line, so a feature answering
  # nothing readable looked exactly like one finding nothing.
  it "counts an unreadable answer against the model performance report" do
    counted = []
    stats = Class.new do
      def initialize(sink) = @sink = sink

      def unusable(community_id:, feature:, step: 1) = @sink << [community_id, feature, step]
    end.new(counted)
    broken = SemanticClient.new('{"decision":{"id":"where"}}')
    service = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: broken, stats: stats, logger: Rubotty::Log.null
    )
    service.enqueue(context)

    expect do
      service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))
    end.to raise_error(Rubotty::SemanticAnalysis::Service::DecisionError)
    expect(counted.map(&:last)).to eq([1])
    expect(counted.first[1]).to eq("semantic_analysis")
  end

  it "asks for the answer without deliberation, in the request and in the prompt" do
    service.enqueue(context)

    service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))

    request = client.requests.first
    expect(request[:options]).to eq(chat_template_kwargs: { enable_thinking: false })
    expect(request[:messages].last[:content]).to end_with("/no_think")
  end

  it "asks again without the thinking field where the deployment refuses it" do
    picky = SemanticPickyClient.new
    quiet = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: picky, logger: Rubotty::Log.null
    )
    quiet.enqueue(context)

    quiet.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))

    expect(picky.requests.map { |request| request[:options] }).to eq([described_class::NO_THINKING, {}])
    expect(ephemeral.posts.length).to eq(1)
  end

  # A reasoning model spends the whole budget thinking out loud and never
  # reaches the answer, which must raise as a clean decision failure rather
  # than blow up trying to hand raw deliberation text to JSON.parse.
  it "raises a decision error rather than a parse error when the whole answer is an unfinished thinking block" do
    thinking = SemanticClient.new(
      "<think>Okay, let's see. The user sent a message saying they can't find the rules. Let me think about which"
    )
    service = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: thinking, logger: Rubotty::Log.null
    )
    service.enqueue(context)

    expect do
      service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))
    end.to raise_error(Rubotty::SemanticAnalysis::Service::DecisionError, /no decision/)
    expect(ephemeral.posts).to be_empty
  end

  # Thinking that does reach an answer still has to be read, so switching the
  # model to a chattier one degrades to working rather than to inert.
  it "reads the decision that follows a closed thinking block" do
    closed = SemanticClient.new(
      "<think>The member is asking where the rules live.</think>\n{\"id\":\"where\",\"confidence\":0.91}"
    )
    service = described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, client: closed, logger: Rubotty::Log.null
    )
    service.enqueue(context)

    service.run(SemanticJob.new(payload: scheduler.jobs.first[:payload], community: "first"))

    expect(ephemeral.posts.first[:body].text).to eq("Start with #rules.")
  end
end
