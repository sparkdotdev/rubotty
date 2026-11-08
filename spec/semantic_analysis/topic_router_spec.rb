# frozen_string_literal: true

require "spec_helper"

module TopicRouterSupport
end

RSpec.describe Rubotty::SemanticAnalysis::TopicRouter do
  include Builders

  TopicRouterSupport::RoutingJob = Struct.new(:payload, :community, keyword_init: true)

  class RoutingScheduler
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

    def jobs_of(kind) = @jobs.select { |job| job[:kind] == kind }
  end

  class RoutingClient
    attr_reader :requests

    def initialize(response = '{"best":"support","score":0.95,"here":0.10}')
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
  class RoutingPickyClient < RoutingClient
    def complete(messages:, max_tokens:, feature:, community_id:, options: {}, retried: false)
      super
      unless options.empty?
        # A deployment refusing the field answers 4xx, which is the only failure
        # the plain retry is for; a timeout is the card being busy and re-raises.
        raise Rubotty::OpenArc::Client::Error.new("OpenArc answered HTTP 400", permanent: true)
      end

      @response
    end
  end

  # The posted group answers #any? and #delete_now, which is what the notice's
  # cleanup pairing reads before it schedules the self-delete.
  class RoutingGroup
    attr_reader :deletes

    def initialize
      @deletes = 0
    end

    def any? = true

    def delete_now = @deletes += 1
  end

  class RoutingEphemeral
    attr_reader :posts, :groups

    def initialize
      @posts = []
      @groups = []
    end

    def post(endpoints:, **spec)
      @posts << spec.merge(endpoints: endpoints)
      @groups << RoutingGroup.new
      @groups.last
    end
  end

  class RoutingCleanup
    attr_reader :scheduled

    def initialize
      @scheduled = []
    end

    def after(delay, &action)
      @scheduled << { delay: delay, action: action }
    end

    def run_all = @scheduled.each { |job| job[:action].call }
  end

  # Answers a Delivery, exactly as AdminNotifier does, so a spec can hand back
  # an audience nobody was reached in without that reading as a delivery.
  class RoutingNotifier
    attr_reader :sent

    def initialize(reached = 1)
      @delivery = Rubotty::ControlPlane::AdminNotifier::Delivery.new(
        audience: [reached, 1].max, reached: reached, refused: reached.zero? ? 1 : 0, unreachable: 0
      )
      @sent = []
    end

    def notify_operators!(community_id:, text:)
      @sent << { community_id: community_id, text: text }
      @delivery
    end
  end

  class RoutingRedirections
    Row = Struct.new(:id, :community_id, :source_endpoint_id, :target_room_id, :operator, :plan,
                     keyword_init: true)

    attr_reader :opened

    def initialize(fail_with: nil)
      @opened = []
      @fail_with = fail_with
    end

    def open(community_id:, source_endpoint_id:, target_room_id:, operator:, plan:, operator_native_id: nil)
      raise @fail_with, "no control plane" if @fail_with

      row = Row.new(
        id: @opened.length + 1, community_id: community_id, source_endpoint_id: source_endpoint_id,
        target_room_id: target_room_id, operator: operator, plan: plan
      )
      @opened << row
      row
    end
  end

  class RoutingAudit
    attr_reader :events

    def initialize
      @events = []
    end

    def record(**event)
      @events << event
      event
    end
  end

  # Records only what {ModelCallStats#unusable} would, so a spec can tell an
  # answer that came back unusable apart from a call that never came back.
  class RoutingStats
    attr_reader :unusable_calls

    def initialize
      @unusable_calls = []
    end

    def unusable(community_id:, feature:)
      @unusable_calls << { community_id: community_id, feature: feature }
    end
  end

  class RoutingOperators
    def initialize(handles = [])
      @handles = handles
    end

    def resolve(_adapter, native_id, username: nil)
      @handles.include?(native_id.to_s) || @handles.include?(username.to_s) ? Object.new : nil
    end
  end

  TopicRouterSupport::RoutingCommunity = Struct.new(:id, :slug, :name, :topology, :features, :configs, keyword_init: true) do
    def rooms = topology.rooms

    def room_key_of(channel_or_key)
      key = channel_or_key.respond_to?(:endpoint_key) ? channel_or_key.endpoint_key : channel_or_key.to_s
      rooms.find { |room| room.include?(key) }&.id
    end

    def feature_enabled?(channel_or_key, feature)
      features.fetch(room_key_of(channel_or_key).to_s, {}).fetch(feature.to_s, false)
    end

    def feature_config(channel_or_key, feature)
      configs.fetch(room_key_of(channel_or_key).to_s, {}).fetch(feature.to_s, {})
    end
  end

  TopicRouterSupport::RoutingSnapshot = Struct.new(:communities)
  TopicRouterSupport::RoutingRegistry = Struct.new(:current)
  TopicRouterSupport::RoutingContext = Struct.new(:community, :channel, :message, :operators) do
    def command_prefixes = Rubotty::Core::CommandPrefix.new
  end

  let(:general) { endpoint("tg-general", adapter: :telegram, account: "bot") }
  let(:support) { endpoint("tg-support", adapter: :telegram, account: "bot") }
  let(:general_room) { Rubotty::Core::Room.new(id: "general", endpoints: [general], label: "general") }
  let(:support_room) { Rubotty::Core::Room.new(id: "support", endpoints: [support], label: "support") }

  let(:features) do
    {
      "general" => { "topic_routing" => true, "topic_routing_moves" => false },
      "support" => { "topic_routing" => true, "topic_routing_moves" => false }
    }
  end

  let(:configs) do
    {
      "general" => { "topic_routing" => { subject: "anything else going on" } },
      "support" => { "topic_routing" => { subject: "help with a broken install" } }
    }
  end

  let(:community) do
    TopicRouterSupport::RoutingCommunity.new(
      id: 7, slug: "first", name: "First", topology: topology(general_room, support_room),
      features: features, configs: configs
    )
  end

  let(:registry) { TopicRouterSupport::RoutingRegistry.new(TopicRouterSupport::RoutingSnapshot.new([community])) }
  let(:scheduler) { RoutingScheduler.new }
  let(:client) { RoutingClient.new }
  let(:ephemeral) { RoutingEphemeral.new }
  let(:redirections) { RoutingRedirections.new }
  let(:audit) { RoutingAudit.new }
  let(:notifier) { RoutingNotifier.new }
  let(:cleanup) { RoutingCleanup.new }
  let(:operators) { RoutingOperators.new }
  let(:stats) { RoutingStats.new }
  let(:settings) do
    Rubotty::OpenArc::Settings.new(store: Struct.new(:url, :api_key).new("http://openarc.example", nil))
  end

  # A null logger is built at fatal level and never calls the block it is
  # handed, so asserting on a debug line takes a sink that keeps one.
  class RoutingLogger
    attr_reader :debugs

    def initialize
      @debugs = []
    end

    def debug(message = nil, &block)
      @debugs << (block ? block.call : message).to_s
    end

    %i[info warn error fatal].each do |level|
      define_method(level) { |_message = nil, &_block| nil }
    end
  end

  let(:capturing) { RoutingLogger.new }

  def router_logging
    described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, redirections: redirections, audit: audit, client: client,
      admin_notifier: notifier, cleanup: cleanup, logger: capturing, stats: stats
    )
  end

  let(:router) do
    described_class.new(
      registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
      settings: settings, redirections: redirections, audit: audit, client: client,
      admin_notifier: notifier, cleanup: cleanup, logger: Rubotty::Log.null, stats: stats
    )
  end

  # Comfortably over the 120 character default gate.
  def long(text = "the installer keeps failing part way through and I cannot work out why it stops")
    "#{text} #{"and it happens every single time I try it again" * 2}"
  end

  def context(text: long, native_id: "1", **rest)
    TopicRouterSupport::RoutingContext.new(community, general.id, message(general, text: text, native_id: native_id, **rest), operators)
  end

  def job_for(context_object)
    router.enqueue(context_object)
    TopicRouterSupport::RoutingJob.new(payload: scheduler.jobs_of("topic_routing").last[:payload], community: "first")
  end

  describe "#enqueue" do
    it "queues the message text and its scope, and nothing about the FAQ or the rooms" do
      router.enqueue(context)

      job = scheduler.jobs.first
      expect(job).to include(kind: "topic_routing", community: "first", discard_payload: true)
      expect(job[:payload]).to include(
        "room_key" => "general", "endpoint_id" => "tg-general", "native_id" => "1"
      )
      expect(job[:payload]["text"]).to include("the installer keeps failing")
    end

    it "queues nothing at all when the room has classification switched off" do
      features["general"]["topic_routing"] = false

      expect(router.enqueue(context)).to be_nil
      expect(scheduler.jobs).to be_empty
    end

    # A catch-all is where things go, not somewhere to be moved out of:
    # everything said in one fits somewhere else by definition, so policing it
    # would spend the day proposing to empty the room.
    it "queues nothing said in a room that only receives" do
      configs["general"]["topic_routing"][:destination_only] = true

      expect(router.enqueue(context)).to be_nil
      expect(scheduler.jobs).to be_empty
    end

    it "leaves an operator's own message alone" do
      operator_context = TopicRouterSupport::RoutingContext.new(
        community, general.id, message(general, text: long), RoutingOperators.new(["u1"])
      )

      expect(router.enqueue(operator_context)).to be_nil
    end

    it "leaves a short message and an attachment alone" do
      expect(router.enqueue(context(text: "yep"))).to be_nil
      expect(router.enqueue(context(attachments: [photo_attachment], native_id: "4"))).to be_nil
    end

    # A forum topic is not a sub conversation of the room: on Telegram it IS
    # the room, so refusing a threaded message left the feature inert in every
    # forum supergroup, which is the shape this is most used in.
    it "checks a message in a thread, since the thread is the room" do
      expect(router.enqueue(context(thread: Rubotty::Core::ThreadRef.new(native_id: "t1"), native_id: "3")))
        .not_to be_nil
    end

    # A reply is most of what gets said in a room where people answer each
    # other, and it is the case context exists to make placeable at all.
    it "checks a reply like any other message" do
      expect(router.enqueue(context(reply_to: ref(general.id, "9"), native_id: "2"))).not_to be_nil
    end

    # A message rarely places itself: "mine took eight months" is about whatever
    # came before it, so the few preceding ones travel with the check.
    it "carries the preceding messages and what a reply was answering" do
      configs["general"]["topic_routing"][:cooldown_seconds] = 0
      router.enqueue(context(text: long("how long is the wait for an appointment now"), native_id: "1"))
      router.enqueue(context(text: long("mine took eight months in the end"), native_id: "2"))

      payload = scheduler.jobs_of("topic_routing").last[:payload]
      expect(payload["context"].map { |item| item["text"] }.join(" ")).to include("how long is the wait")
      expect(payload["context"].first.keys).to contain_exactly("author", "text")
    end

    # Context is the messages BEFORE this one. Remembering it first handed the
    # model a clipped copy of the very message it was being asked to place, and
    # at a context of one it would have received nothing else.
    it "never sends the message under judgement as its own context" do
      configs["general"]["topic_routing"][:cooldown_seconds] = 0
      router.enqueue(context(text: long("the first thing anybody said"), native_id: "1"))
      router.enqueue(context(text: long("a completely separate second thing"), native_id: "2"))

      texts = scheduler.jobs_of("topic_routing").last[:payload]["context"].map { |item| item["text"] }
      expect(texts.join(" ")).not_to include("a completely separate second thing")
    end

    it "sends the message alone where the room asked for no context" do
      configs["general"]["topic_routing"][:context_messages] = 0
      configs["general"]["topic_routing"][:cooldown_seconds] = 0
      router.enqueue(context(text: long("the first thing that anybody said in here"), native_id: "1"))
      router.enqueue(context(text: long("a completely separate second thing said after"), native_id: "2"))

      expect(scheduler.jobs_of("topic_routing").last[:payload]["context"]).to be_empty
    end

    it "checks a room at most once per cooldown" do
      expect(router.enqueue(context(native_id: "1"))).not_to be_nil
      expect(router.enqueue(context(native_id: "2"))).to be_nil
    end

    it "checks every message once the cooldown is switched off" do
      configs["general"]["topic_routing"][:cooldown_seconds] = 0

      expect(router.enqueue(context(native_id: "1"))).not_to be_nil
      expect(router.enqueue(context(native_id: "2"))).not_to be_nil
    end

    it "truncates a long message at the room's own bound before it is stored" do
      configs["general"]["topic_routing"][:max_characters] = 130

      router.enqueue(context)

      expect(scheduler.jobs.first[:payload]["text"].length).to eq(130)
    end

    it "queues no repostable copy while the move switch is off" do
      router.enqueue(context)

      expect(scheduler.jobs.first[:payload]).not_to have_key("move")
    end

    it "queues one when the move switch is on, in the shape a redirection plan takes" do
      features["general"]["topic_routing_moves"] = true

      router.enqueue(context)

      expect(scheduler.jobs.first[:payload]["move"]).to include(
        "native_id" => "1", "endpoint_id" => "tg-general", "platform" => "telegram"
      )
    end

    # The move runs through Features::Redirection's own paced worker, which
    # reads a plan item by symbol key after a JSON round trip.
    it "queues an item carrying every field that worker reads" do
      features["general"]["topic_routing_moves"] = true

      router.enqueue(context)

      item = JSON.parse(JSON.generate(scheduler.jobs.first[:payload]["move"]), symbolize_names: true)
      expect(item.keys).to include(:native_id, :endpoint_id, :handle, :name, :fallback,
                                   :platform, :text, :spans, :attachments)
    end

    it "queues nothing without an OpenArc connection" do
      quiet = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: Rubotty::OpenArc::Settings.new, client: client, logger: Rubotty::Log.null
      )

      expect(quiet.enqueue(context)).to be_nil
      expect(scheduler.jobs).to be_empty
    end

    it "queues nothing when no other room has a subject written for it" do
      configs["support"]["topic_routing"] = {}

      expect(router.enqueue(context)).to be_nil
    end
  end

  # Both features queue onto one scheduler that claims strictly by due time, so
  # under a backlog whichever kind ages out first is the one shed. Classifying
  # has to be the one that gives way.
  it "ages out sooner than content policy, so a backlog sheds this and not moderation" do
    router

    expect(scheduler.max_ages["topic_routing"]).to eq(described_class::MAX_AGE)
    expect(described_class::MAX_AGE).to be < Rubotty::ContentPolicy::Service::MAX_AGE
  end

  # A gate that declines silently makes a feature that is off and a feature
  # that is working and finding nothing look identical from outside the
  # process, which is exactly the afternoon this came out of.
  describe "saying why a message was skipped" do
    it "names the gate rather than declining silently" do
      router_logging.enqueue(context(text: "too short"))

      expect(capturing.debugs.join("\n")).to match(/under the 120 minimum/)
    end

    it "says so when the message carries an attachment" do
      router_logging.enqueue(context(text: long, attachments: [photo_attachment]))

      expect(capturing.debugs.join("\n")).to include("it carries an attachment")
    end
  end

  describe "#run" do
    it "offers every room with a subject and names the one the message was said in" do
      router.run(job_for(context))

      sent = JSON.parse(client.requests.first[:messages].last[:content][/\{.*\}/m])
      expect(sent["said_in"]).to eq("general")
      expect(sent["rooms"]).to contain_exactly(
        { "key" => "general", "subject" => "anything else going on" },
        { "key" => "support", "subject" => "help with a broken install" }
      )
    end

    # The example an operator is shown is three clauses naming a real site, so
    # the whole of one has to arrive at the model rather than a first sentence.
    it "sends a multi-clause subject whole, semicolons, line breaks and all" do
      written = "Buying or selling property in Portugal; renting and tenancy;\n" \
                "any links to Idealista or similar real estate websites"
      configs["support"]["topic_routing"][:subject] = written

      router.run(job_for(context))

      sent = JSON.parse(client.requests.first[:messages].last[:content][/\{.*\}/m])
      expect(sent["rooms"]).to include({ "key" => "support", "subject" => written })
    end

    it "spends nothing from the answer budget on a subject however long it is" do
      configs["support"]["topic_routing"][:subject] = "help with a broken install; " * 200

      router.run(job_for(context))

      expect(client.requests.first[:max_tokens]).to eq(described_class::ANSWER_TOKENS)
    end

    # The rooms are the same bytes on every check and the message never is, so
    # the rooms lead. A server reusing the work it did on a prefix can only
    # reuse what comes before the first difference.
    it "puts the rooms ahead of the message, so the constant half leads" do
      router.run(job_for(context))

      sent = client.requests.first[:messages].last[:content]
      expect(sent.index('"rooms"')).to be < sent.index('"message"')
      expect(sent.index('"rooms"')).to be < sent.index('"said_in"')
    end

    it "records the finding and moves nothing while the move switch is off" do
      router.run(job_for(context))

      expect(redirections.opened).to be_empty
      expect(audit.events.first).to include(
        source: "topic_routing", action: "flag", outcome: "flag", channel: "tg-general"
      )
      expect(audit.events.first[:metadata]).to include(target_room: "support", room: "general")
    end

    it "names nobody in a finding that moved nothing" do
      router.run(job_for(context))

      expect(audit.events.first[:subject]).to be_nil
      expect(audit.events.first[:subject_native_id]).to be_nil
    end

    it "does nothing at all when the message already fits the room it is in" do
      client.instance_variable_set(:@response, '{"best":"general","score":0.95,"here":0.95}')

      router.run(job_for(context))

      expect(audit.events).to be_empty
      expect(redirections.opened).to be_empty
    end

    it "does nothing when the winning room clears the threshold without clearing the margin" do
      client.instance_variable_set(:@response, '{"best":"support","score":0.95,"here":0.90}')

      router.run(job_for(context))

      expect(audit.events).to be_empty
    end

    it "does nothing when the answer leaves out a score the margin needs" do
      client.instance_variable_set(:@response, '{"best":"support","score":0.95}')

      router.run(job_for(context))

      expect(audit.events).to be_empty
    end

    # Both scores are recorded, since the pair is what the decision turned on
    # and the audit log carried a score per room before there was only one.
    it "records the score it moved on and the score it beat" do
      router.run(job_for(context))

      expect(audit.events.first[:metadata]).to include(
        confidence: 0.95, here: 0.10, scores: { "support" => 0.95, "general" => 0.10 }
      )
    end

    it "does nothing when the answer is unparseable, out of range, or a made-up room" do
      configs["general"]["topic_routing"][:cooldown_seconds] = 0

      ['not json at all', '{"best":"support","score":4,"here":0.1}',
       '{"best":"elsewhere","score":0.99,"here":0.1}'].each do |response|
        client.instance_variable_set(:@response, response)

        expect { router.run(job_for(context(native_id: "9"))) }.not_to raise_error
        expect(audit.events).to be_empty
        expect(redirections.opened).to be_empty
      end
    end

    # An unusable answer is counted apart from a clean run that simply found
    # nothing worth moving, so a quietly broken deployment does not read the
    # same as one that is working and finding nothing.
    it "counts an unusable answer apart from a run that found nothing" do
      configs["general"]["topic_routing"][:cooldown_seconds] = 0
      client.instance_variable_set(:@response, "not json at all")

      router.run(job_for(context(native_id: "9")))

      expect(stats.unusable_calls).to eq([{ community_id: community.id, feature: "topic_routing" }])
    end

    it "counts nothing as unusable when the model answers cleanly and finds no better fit" do
      client.instance_variable_set(:@response, '{"best":"general","score":0.95,"here":0.95}')

      router.run(job_for(context))

      expect(stats.unusable_calls).to be_empty
    end

    # Delivery is the critical path, so an unreachable OpenArc has to settle the
    # job rather than raise it back for the scheduler to retry.
    it "does nothing and does not raise when OpenArc cannot be reached" do
      failing = RoutingClient.new
      failing.define_singleton_method(:complete) do |**|
        raise Rubotty::OpenArc::Client::Error, "could not reach OpenArc"
      end
      quiet = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: settings, redirections: redirections, audit: audit, client: failing,
        logger: Rubotty::Log.null
      )

      expect { quiet.run(job_for(context)) }.not_to raise_error
      expect(audit.events).to be_empty
    end

    # The other half of the pair: only receiving is about where a message may be
    # SENT from, and a room that only receives is still somewhere to send to.
    it "still offers a room that only receives as somewhere to move to" do
      configs["support"]["topic_routing"][:destination_only] = true

      router.run(job_for(context))

      expect(audit.events.first).to include(action: "flag")
      expect(client.requests.first[:messages].last[:content]).to include("support")
    end

    it "asks for the answer without deliberation, in the request and in the prompt" do
      router.run(job_for(context))

      request = client.requests.first
      expect(request[:options]).to eq(chat_template_kwargs: { enable_thinking: false })
      expect(request[:messages].last[:content]).to end_with("/no_think")
    end

    # A clearer instruction costs nothing and is worth sending even though the
    # parser now also accepts the bare shape a deployment answers with instead.
    it "shows the model the exact shape wanted, wrapper included" do
      router.run(job_for(context))

      expect(client.requests.first[:messages].first[:content])
        .to include('{"best": "room_key", "score": 0.5, "here": 0.5}')
    end

    # A reasoning model spends the whole budget thinking out loud and never
    # reaches the answer, which must read as no answer rather than as a score.
    it "does nothing when the whole answer is an unfinished thinking block" do
      client.instance_variable_set(
        :@response, "<think>Okay, let's see. The user sent a message about an installer. First I should"
      )

      router.run(job_for(context))

      expect(audit.events).to be_empty
      expect(redirections.opened).to be_empty
    end

    it "does nothing when the thinking block closes but carries no decision" do
      client.instance_variable_set(:@response, "<think>Weighing this up now.</think>\nHard to say either way.")

      router.run(job_for(context))

      expect(audit.events).to be_empty
    end

    # Thinking that does reach an answer still has to be read, so switching the
    # model to a chattier one degrades to working rather than to inert.
    it "reads the decision that follows a closed thinking block" do
      client.instance_variable_set(
        :@response,
        "<think>The message is about a broken install.</think>\n```json\n{\"best\":\"support\",\"score\":0.95,\"here\":0.1}\n```"
      )

      router.run(job_for(context))

      expect(audit.events.first[:metadata]).to include(target_room: "support")
    end

    it "asks again without the thinking field where the deployment refuses it" do
      picky = RoutingPickyClient.new
      quiet = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: settings, redirections: redirections, audit: audit, client: picky,
        logger: Rubotty::Log.null
      )

      quiet.run(job_for(context))

      expect(picky.requests.map { |request| request[:options] }).to eq([described_class::NO_THINKING, {}])
      expect(audit.events.first).to include(action: "flag")
    end

    it "stops when classification was switched off between the queue and the run" do
      job = job_for(context)
      features["general"]["topic_routing"] = false

      router.run(job)

      expect(client.requests).to be_empty
      expect(audit.events).to be_empty
    end
  end

  describe "#run announcing a finding" do
    def announce(mode)
      configs["general"]["topic_routing"][:announce_findings] = mode
    end

    it "DMs the community's operators by default, naming the room and the confidence" do
      router.run(job_for(context))

      dm = notifier.sent.first
      expect(dm[:community_id]).to eq(7)
      expect(dm[:text]).to include("First", "better fit for support", "Confidence: 0.95")
      expect(ephemeral.posts).to be_empty
    end

    # As with the content policy alert: the console reads this opening to
    # resolve which community a reply to it is about (#1959).
    it "opens with the community's name, which a reply is disambiguated by" do
      router.run(job_for(context))

      expect(notifier.sent.first[:text]).to start_with("First: ")
    end

    it "carries an excerpt of the message so an operator can judge the call" do
      router.run(job_for(context))

      expect(notifier.sent.first[:text]).to include("the installer keeps failing")
    end

    # Reading the Delivery as a number raised inside this path's own rescue,
    # so a DM that went out was logged as one that could not be sent, which is
    # the line anybody diagnosing a quiet operator alert reads first.
    it "logs a delivered finding as delivered rather than as a failure" do
      logs = StringIO.new
      loud = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: settings, redirections: redirections, audit: audit, client: client,
        admin_notifier: notifier, cleanup: cleanup, stats: stats,
        logger: Rubotty::Log.build(level: "info", io: logs)
      )

      loud.run(job_for(context))

      expect(logs.string).to include("accepted for 1 operator DM(s)")
      expect(logs.string).not_to include("could not DM a finding")
      expect(logs.string).not_to include("nobody has been told")
    end

    it "posts a self-deleting notice in the room the message was said in" do
      announce("room")

      router.run(job_for(context))

      notice = ephemeral.posts.first
      expect(notice[:endpoints].map(&:id)).to eq(["tg-general"])
      expect(notice[:body].text).to include("better fit for support than general", "confidence 0.95")
      expect(notice[:reply_to].native_id).to eq("1")
      expect(notifier.sent).to be_empty
    end

    it "pairs that notice with the cleanup that actually removes it" do
      announce("room")

      router.run(job_for(context))

      expect(ephemeral.posts.first[:delete_after]).to eq(Rubotty::Core::RemovalNotice::DEFAULT_TTL_SECONDS)
      expect(cleanup.scheduled.first[:delay]).to eq(Rubotty::Core::RemovalNotice::DEFAULT_TTL_SECONDS)
      expect { cleanup.run_all }.to change { ephemeral.groups.first.deletes }.from(0).to(1)
    end

    it "leaves a notice up where the room asked for no self-delete" do
      announce("room")
      configs["general"]["topic_routing"][Rubotty::Core::RemovalNotice::TTL_FIELD] = 0

      router.run(job_for(context))

      expect(ephemeral.posts.first[:delete_after]).to eq(0)
      expect(cleanup.scheduled).to be_empty
    end

    it "says nothing anywhere when the room has switched announcing off" do
      announce("off")

      router.run(job_for(context))

      expect(ephemeral.posts).to be_empty
      expect(notifier.sent).to be_empty
    end

    # The audit row is the record; announcing is delivery on top of it, so
    # turning delivery down must never turn the record off with it.
    it "records the finding whichever way it is announced" do
      configs["general"]["topic_routing"][:cooldown_seconds] = 0

      %w[off room operators].each_with_index do |mode, index|
        announce(mode)

        router.run(job_for(context(native_id: index.to_s)))
      end

      expect(audit.events.length).to eq(3)
      expect(audit.events.map { |event| event[:outcome] }).to eq(%w[flag flag flag])
    end

    it "falls back to a DM where the room's setting is not one of the three" do
      announce("somewhere else")

      router.run(job_for(context))

      expect(notifier.sent.length).to eq(1)
    end

    # AdminNotifier answers a Delivery rather than a count, and reading it as a
    # number raised inside the rescue here, so every finding logged as a failed
    # DM whether or not one went out. A delivery nobody was reached in must not
    # raise, and must not pass for a finding somebody heard about either.
    it "does not raise when no operator DM was accepted, or when there is no notifier" do
      quiet = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: settings, redirections: redirections, audit: audit, client: client,
        admin_notifier: RoutingNotifier.new(0), logger: Rubotty::Log.null
      )
      none = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: settings, redirections: redirections, audit: audit, client: client,
        logger: Rubotty::Log.null
      )

      configs["general"]["topic_routing"][:cooldown_seconds] = 0

      expect { quiet.run(job_for(context)) }.not_to raise_error
      expect { none.run(job_for(context(native_id: "2"))) }.not_to raise_error
      expect(audit.events.map { |event| event[:action] }).to eq(%w[flag flag])
    end

    it "records the finding even when the in-room notice cannot be posted" do
      announce("room")
      ephemeral.define_singleton_method(:post) { |**| raise "no send capability here" }

      expect { router.run(job_for(context)) }.not_to raise_error
      expect(audit.events.first).to include(action: "flag")
    end
  end

  describe "#run with the move switch on" do
    before { features["general"]["topic_routing_moves"] = true }

    it "opens a one-message redirection into the better-fitting room" do
      router.run(job_for(context))

      row = redirections.opened.first
      expect(row.community_id).to eq(7)
      expect(row.source_endpoint_id).to eq("tg-general")
      expect(row.target_room_id).to eq("support")
      expect(row.plan.length).to eq(1)
      expect(row.plan.first).to include("native_id" => "1", "text" => a_string_including("installer"))
    end

    it "hands the move to the paced worker redirection already owns" do
      router.run(job_for(context))

      job = scheduler.jobs_of(Rubotty::Features::Redirection::KIND).first
      expect(job[:payload]).to include("redirection_id" => 1, "community_id" => 7)
    end

    it "records the move against the author it affected" do
      router.run(job_for(context))

      expect(audit.events.first).to include(action: "move", outcome: "move", subject_native_id: "u1")
    end

    it "tells the author where the message went, in the room it left" do
      router.run(job_for(context))

      notice = ephemeral.posts.first
      expect(notice[:endpoints].map(&:id)).to eq(["tg-general"])
      expect(notice[:body].text).to include("has been moved to support")
      expect(notice[:delete_after]).to eq(0)
    end

    # The name of the room a message went to is only useful if the reader can
    # follow it, which on a platform with room links means a link.
    it "links the room a message went to, where the platform publishes one" do
      linking = Class.new do
        def room_permalink(endpoint) = "https://example.test/#{endpoint.id}"
      end.new
      router = described_class.new(
        registry: registry, scheduler: scheduler, adapters: { [:telegram, "bot"] => linking },
        ephemeral: ephemeral, settings: settings, redirections: redirections, audit: audit,
        client: client, logger: Rubotty::Log.null
      )

      router.run(job_for(context))

      notice = ephemeral.posts.first
      link = notice[:body].spans.find { |span| span.kind == :link }
      expect(link.attributes[:url]).to eq("https://example.test/tg-support")
      expect(notice[:body].text[link.begin_index...link.end_index]).to eq("support")
    end

    it "says nothing when the room has switched the notice off" do
      configs["general"]["topic_routing_moves"] = { notify_author: false }

      router.run(job_for(context))

      expect(ephemeral.posts).to be_empty
      expect(redirections.opened.length).to eq(1)
    end

    # A move has already said its piece in the room it left, so the suggestion
    # notice is for the half of the pair where nothing was done.
    it "announces no suggestion on top of a move that went through" do
      configs["general"]["topic_routing"][:announce_findings] = "room"

      router.run(job_for(context))

      expect(ephemeral.posts.length).to eq(1)
      expect(ephemeral.posts.first[:body].text).to include("has been moved to support")
      expect(notifier.sent).to be_empty
    end

    # A move queued while the switch was on must still check it at run time,
    # which is the half of the pair that keeps a switched-off room untouched.
    it "falls back to recording a finding when the move switch went off after queueing" do
      job = job_for(context)
      features["general"]["topic_routing_moves"] = false

      router.run(job)

      expect(redirections.opened).to be_empty
      expect(audit.events.first).to include(action: "flag")
    end

    it "records a finding rather than raising when the move cannot be opened" do
      broken = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: settings, redirections: RoutingRedirections.new(fail_with: RuntimeError),
        audit: audit, client: client, logger: Rubotty::Log.null
      )

      expect { broken.run(job_for(context)) }.not_to raise_error
      expect(audit.events.first).to include(action: "flag")
    end

    it "moves nothing where the deployment has no redirection rows to open" do
      quiet = described_class.new(
        registry: registry, scheduler: scheduler, adapters: {}, ephemeral: ephemeral,
        settings: settings, audit: audit, client: client, logger: Rubotty::Log.null
      )

      quiet.run(job_for(context))

      expect(audit.events.first).to include(action: "flag")
      expect(ephemeral.posts).to be_empty
    end
  end
end
