# frozen_string_literal: true

require "spec_helper"

# Redirecting a bridged run on a platform that cannot hand back its own
# history. Only Discord answers supports_backfill?, so elsewhere a run was
# rebuilt from an in-memory ring that never held a relayed message
# (Core::LoopGuard drops those first), moving only the platform-native half.
RSpec.describe "redirecting a bridged run", :control_plane do
  # A durable scheduler that keeps its jobs in a list, so the move can be driven
  # a tick at a time with nothing sleeping.
  class ListDurable
    Job = Struct.new(:kind, :run_at, :payload, keyword_init: true)

    def initialize
      @jobs = []
      @handlers = {}
    end

    attr_reader :jobs

    def register(kind, max_age: nil, priority: nil, &block)
      @handlers[kind.to_s] = block
      self
    end

    def schedule(kind:, run_at:, payload: {}, community: nil, recurrence: nil)
      @jobs << Job.new(kind: kind.to_s, run_at: run_at, payload: payload)
      @jobs.length
    end

    def cancel(kind:, community: nil, &predicate)
      before = @jobs.length
      @jobs.reject! { |job| job.kind == kind.to_s && predicate.call(job.payload) }
      before - @jobs.length
    end
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community_row) { models.community.where(slug: "sample").first }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new }
  let(:durable) { ListDurable.new }
  let(:window) { Rubotty::ControlPlane::RedirectionWindow.new(models: models) }
  let(:redirections) { Rubotty::ControlPlane::Redirections.new(models: models) }

  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }
  let(:snapshot) { registry.current }
  let(:community) { snapshot.community_by_id(community_row.id) }

  let(:operator) do
    Rubotty::Core::Moderation::Operator.new(
      name: "sample_owner", identities: { telegram: ["op1"] }, actions: [:redirect], rooms: :all
    )
  end
  let(:operators) { Rubotty::Core::Moderation::Directory.new([operator]) }

  # One RecordingAdapter per real (adapter, account) in the topology. None of
  # them can read its own history, which is the whole point.
  let(:adapter_map) do
    snapshot.topology.endpoints
            .reject { |e| %i[guest api].include?(e.adapter_name) }
            .each_with_object({}) do |e, map|
      map[[e.adapter_name, e.account]] ||= Fakes::RecordingAdapter.new(account: e.account)
    end
  end

  let(:route) do
    Rubotty::Core::Router.new(
      topology: snapshot.topology, adapters: adapter_map, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, registry: registry,
      redirection_window: window
    )
  end

  let(:feature) do
    Rubotty::Features::Redirection.new(
      topology: snapshot.topology, adapters: adapter_map, storage: storage,
      logger: Rubotty::Log.null, registry: registry, redirections: redirections,
      durable_scheduler: durable, window: window, loop_guard: loop_guard
    )
  end

  def endpoint_of(id) = snapshot.topology.endpoints.find { |e| e.id == id }

  def telegram = adapter_map[[:telegram, "telegram"]]

  def discord = adapter_map[[:discord, "discord"]]

  # Say something on one side of the bridge, through the real relay.
  def say(endpoint_id, text, native_id:, from: author(native_id: "u#{native_id}", username: "ada"))
    route.handle(message(endpoint_of(endpoint_id), text: text, native_id: native_id, author: from))
  end

  # The id a message posted on one endpoint ended up with on another, so the
  # operator's reply points at the copy they can actually see.
  def copy_of(native_id, on:, posted_on:)
    storage.counterparts(ref(posted_on, native_id), endpoint_id: on).first&.native_id
  end

  def context_for(message)
    Rubotty::Features::Context.new(
      message: message, community: community, config: {},
      logger: Rubotty::Log.null, operators: operators
    )
  end

  def op_author = author(native_id: "op1", username: "sample_owner")

  def redirect!(first:, target: "gaming", on: "tg-general")
    feature.call(
      context_for(
        message(endpoint_of(on), text: "/redirect #{target}", native_id: "cmd-1",
                                 author: op_author, reply_to: ref(on, first))
      )
    )
  end

  def end!(last:, on: "tg-general")
    feature.call(
      context_for(
        message(endpoint_of(on), text: "/end", native_id: "cmd-2",
                                 author: op_author, reply_to: ref(on, last))
      )
    )
  end

  def drain(limit: 60)
    limit.times do
      job = durable.jobs.shift
      break if job.nil?

      feature.step(id: job.payload[:redirection_id], community_id: job.payload[:community_id])
    end
  end

  def moved_into(endpoint_id)
    (telegram.delivered + discord.delivered)
      .select { |(id, msg)| id == endpoint_id && msg.chat? }
      .map { |(_, msg)| msg }
  end

  def last_reply
    (telegram.delivered + discord.delivered).map(&:last).reject(&:chat?).last.body.text
  end

  before { controls.enable(community: community_row, selector: "general", feature: "redirection") }

  describe "a run that came in from both sides of the bridge" do
    before do
      say("tg-general", "one", native_id: "t1")
      say("dc-general", "two", native_id: "c1", from: author(native_id: "u2", username: "grace"))
      say("dc-general", "three", native_id: "c2", from: author(native_id: "u2", username: "grace"))
    end

    it "keeps one row per message, whichever side of the bridge it arrived on" do
      kept = window.for_room(community_id: community_row.id, room_key: "general")

      expect(kept.map { |entry| entry.body.text }).to eq(%w[one two three])
      expect(kept.map(&:endpoint_id)).to eq(%w[tg-general dc-general dc-general])
    end

    # The operator is on Telegram, which cannot be asked for its own history, and
    # two of the three messages were said on Discord.
    it "moves the whole run, including the messages that came in from Discord" do
      redirect!(first: "t1")
      end!(last: copy_of("c2", on: "tg-general", posted_on: "dc-general"))
      drain

      expect(moved_into("tg-gaming").map { |msg| msg.body.text }).to eq(%w[one two three])
      expect(moved_into("dc-gaming").map { |msg| msg.body.text }).to eq(%w[one two three])
    end

    it "reposts each message under the author who actually wrote it" do
      redirect!(first: "t1")
      end!(last: copy_of("c2", on: "tg-general", posted_on: "dc-general"))
      drain

      expect(moved_into("tg-gaming").map { |msg| msg.sender_label.primary }).to eq(%w[ada grace grace])
    end

    # Deleting the run through the operator's own endpoint would ask Telegram to
    # delete a Discord id and leave the real message in place.
    it "deletes each original on the platform it was actually posted on" do
      redirect!(first: "t1")
      end!(last: copy_of("c2", on: "tg-general", posted_on: "dc-general"))
      drain

      expect(telegram.deleted.select { |(id, _)| id == "tg-general" }.map(&:last)).to include("t1")
      expect(discord.deleted.select { |(id, _)| id == "dc-general" }.map(&:last)).to include("c1", "c2")
    end

    it "records the move with the count it actually carried" do
      redirect!(first: "t1")
      end!(last: copy_of("c2", on: "tg-general", posted_on: "dc-general"))

      expect(models.redirection.first.message_count).to eq(3)
    end
  end

  describe "a room with the feature switched off" do
    before { controls.disable(community: community_row, selector: "general", feature: "redirection") }

    # An operator opts into the retention to get the move, so a room that has not
    # opted in holds nothing at all.
    it "keeps nothing whatsoever" do
      say("tg-general", "one", native_id: "t1")
      say("dc-general", "two", native_id: "c1")

      expect(models.redirection_window_message.count).to eq(0)
    end

    it "still keeps the room next door, which did opt in" do
      controls.enable(community: community_row, selector: "gaming", feature: "redirection")
      say("tg-general", "not kept", native_id: "t1")
      say("tg-gaming", "kept", native_id: "t2")

      expect(models.redirection_window_message.select_map(:body)).to eq(["kept"])
    end
  end

  describe "a message somebody deletes" do
    it "stops being kept, so a later move cannot bring it back" do
      say("tg-general", "one", native_id: "t1")
      say("tg-general", "regretted", native_id: "t2")
      route.handle(
        Rubotty::Core::Message.new(
          kind: :delete, origin: endpoint_of("tg-general"), ref: ref("tg-general", "t2")
        )
      )

      expect(window.for_room(community_id: community_row.id, room_key: "general").map { |e| e.body.text })
        .to eq(["one"])
    end
  end

  describe "when the record cannot cover the run" do
    it "says the room has nothing kept, naming both ways that happens" do
      redirect!(first: "t1")

      expect(last_reply).to include("nothing kept for this room")
      expect(last_reply).to include("only just enabled")
      expect(models.redirection.count).to eq(0)
    end

    it "says the first message predates the keeping when the run started before the toggle" do
      controls.disable(community: community_row, selector: "general", feature: "redirection")
      registry.reload
      say("tg-general", "before", native_id: "t1")
      controls.enable(community: community_row, selector: "general", feature: "redirection")
      registry.reload
      say("tg-general", "after", native_id: "t2")

      redirect!(first: "t1")

      expect(last_reply).to include("The first message of that run is not in what I keep")
      expect(last_reply).to include("posted before redirection was switched on here")
      expect(models.redirection.count).to eq(0)
    end

    it "refuses an unkept start before asking an operator to finish the run" do
      controls.disable(community: community_row, selector: "general", feature: "redirection")
      registry.reload
      say("tg-general", "before", native_id: "t1")
      controls.enable(community: community_row, selector: "general", feature: "redirection")
      registry.reload
      say("tg-general", "after", native_id: "t2")

      redirect!(first: "t1")

      expect(last_reply).to include("The first message of that run is not in what I keep")
      expect(feature.pending.size).to eq(0)
    end

    it "says the first message aged out when it is older than the window" do
      say("tg-general", "old", native_id: "t1")
      say("tg-general", "new", native_id: "t2")
      models.redirection_window_message
            .where(native_id: "t1")
            .update(created_at: Time.now - (Rubotty::ControlPlane::RedirectionWindow::TTL_SECONDS + 60))

      redirect!(first: "t1")

      expect(last_reply).to include("older than that")
      expect(models.redirection.count).to eq(0)
    end

    it "says which end it does not have when /end points at something it never kept" do
      say("tg-general", "one", native_id: "t1")

      redirect!(first: "t1")
      end!(last: "never-relayed")

      expect(last_reply).to include("don't have the message you said /end on")
      expect(models.redirection.count).to eq(0)
    end

    it "says so when the two ends are the wrong way round" do
      say("tg-general", "one", native_id: "t1")
      say("tg-general", "two", native_id: "t2")

      redirect!(first: "t2")
      end!(last: "t1")

      expect(last_reply).to include("wrong way round")
      expect(models.redirection.count).to eq(0)
    end
  end
end
