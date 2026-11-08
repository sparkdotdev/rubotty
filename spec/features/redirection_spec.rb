# frozen_string_literal: true

require "spec_helper"

# Moving a run of messages into the room it should have been in, in the order it was said.
# No original is deleted until every repost has landed, so a half-finished move loses nothing.
RSpec.describe Rubotty::Features::Redirection, :control_plane do
  # A durable scheduler keeping its jobs in a list, so a spec can drive the move a tick at a time.
  class FakeDurable
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

  # The snapshot seam the feature reads rooms and per-scope config through, with only the
  # two methods it actually calls.
  FakeCommunity = Struct.new(:id, :rooms, :operators, keyword_init: true) do
    def feature_config(_scope, _feature) = {}
  end

  FakeSnapshot = Struct.new(:communities) do
    def community_by_id(id) = communities.find { |community| community.id == id }
  end

  FakeRegistry = Struct.new(:current)

  let(:adapter) { Fakes::RecordingAdapter.new }
  let(:adapters) { Hash.new(adapter) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:durable) { FakeDurable.new }

  let(:source) { endpoint("source", settings: { room_key: "a" }) }
  let(:target) { endpoint("target", settings: { room_key: "b" }) }
  let(:source_room) { room("wrong-room", source) }
  let(:target_room) { room("right-room", target, label: "right-room") }

  let(:operator) do
    Rubotty::Core::Moderation::Operator.new(
      name: "sample_owner", identities: { fake: ["op1"] }, actions: [:redirect], rooms: :all
    )
  end

  let(:operators) { Rubotty::Core::Moderation::Directory.new([operator]) }

  let(:community) { FakeCommunity.new(id: community_id, rooms: [source_room, target_room], operators: operators) }
  let(:registry) { FakeRegistry.new(FakeSnapshot.new([community])) }

  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:community_id) { seed_community("sample").id }
  let(:redirections) { Rubotty::ControlPlane::Redirections.new(models: models) }

  let(:feature) do
    described_class.new(
      topology: topology(source_room, target_room), adapters: adapters, storage: storage,
      logger: Rubotty::Log.null, registry: registry, redirections: redirections,
      durable_scheduler: durable
    )
  end

  def seed_community(slug)
    models.community.create(slug: slug, name: slug.upcase, status: "active", settings: "{}",
                            created_at: Time.now, updated_at: Time.now)
  end

  # The scope's own directory is what a permission check reads, so an override
  # replaces the community's rather than sitting beside it.
  def context_for(message, community_override = community, operators_override = nil)
    scope = operators_override.nil? ? community_override : with_directory(community_override, operators_override)
    Rubotty::Features::Context.new(
      message: message, community: scope, config: {}, logger: Rubotty::Log.null
    )
  end

  def with_directory(scope, directory)
    FakeCommunity.new(id: scope.id, rooms: scope.rooms, operators: directory)
  end

  def op_author = author(native_id: "op1", username: "sample_owner")

  # Walk the run past the feature as the pipeline would, so the window /end reads back is
  # the one the feature built for itself.
  def watch(*texts, from: 10)
    texts.each_with_index do |text, index|
      feature.call(context_for(message(source, text: text, native_id: (from + index).to_s)))
    end
  end

  def redirect!(target_name: "right-room", first: "10", author: op_author)
    feature.call(
      context_for(
        message(source, text: "/redirect #{target_name}", native_id: "90",
                       author: author, reply_to: ref(source.id, first))
      )
    )
  end

  def end!(last: "12", author: op_author)
    feature.call(
      context_for(
        message(source, text: "/end", native_id: "91", author: author, reply_to: ref(source.id, last))
      )
    )
  end

  # The last thing the bot said anywhere, which for a refusal is the refusal itself.
  def last_said = adapter.delivered.last.last.body.text

  # Every repost and closing line that landed on the target, in order.
  def posted_to_target
    adapter.delivered.select { |(id, _)| id == target.id }.map(&:last)
  end

  def reposts = posted_to_target.select(&:chat?).map { |message| message.body.text }

  def deleted_from_source = adapter.deleted.select { |(id, _)| id == source.id }.map(&:last)

  # Drain the move one scheduled step at a time. Nothing sleeps: the pacing is the run_at
  # the feature stamps on each job, asserted separately.
  def drain(limit: 50)
    steps = []
    limit.times do
      job = durable.jobs.shift
      break if job.nil?

      steps << feature.step(id: job.payload[:redirection_id], community_id: job.payload[:community_id])
    end
    steps
  end

  describe "starting a move" do
    it "marks the run and waits for /end" do
      watch("one", "two", "three")
      redirect!

      expect(feature.pending.peek(community_id: community_id, endpoint_id: source.id, actor_id: "op1"))
        .not_to be_nil
    end

    it "swallows the command rather than relaying it" do
      watch("one")

      expect(redirect!).to be_halt
    end

    it "refuses a target that is not a room in this community" do
      watch("one")
      redirect!(target_name: "somewhere-else")

      expect(feature.pending.size).to eq(0)
      expect(adapter.delivered.last.last.body.text).to include("can't find a room")
    end

    it "refuses a run that is not marked with a reply" do
      watch("one")
      feature.call(context_for(message(source, text: "/redirect right-room", native_id: "90", author: op_author)))

      expect(feature.pending.size).to eq(0)
      expect(adapter.delivered.last.last.body.text).to include("Reply to the first message")
    end
  end

  describe "the operator gate" do
    let(:bystander) { author(native_id: "nobody", username: "sam") }

    it "tells somebody with no standing that they may not, rather than saying nothing" do
      watch("one")

      expect(redirect!(author: bystander)).to be_halt
      expect(last_said).to include("don't have permission")
      expect(feature.pending.size).to eq(0)
    end

    # The whole point of the wording: a stranger learns they may not act and nothing
    # else, so probing with a name is worth no more than probing without one.
    it "says the same thing whether or not the room the stranger named exists" do
      watch("one")
      redirect!(author: bystander, target_name: "right-room")
      real = last_said
      redirect!(author: bystander, target_name: "no-such-room")

      expect(last_said).to eq(real)
    end

    it "refuses an operator whose grant does not cover redirection" do
      limited = Rubotty::Core::Moderation::Operator.new(
        name: "limited", identities: { fake: ["op1"] }, actions: [:delete], rooms: :all
      )
      directory = Rubotty::Core::Moderation::Directory.new([limited])
      watch("one")

      feature.call(
        context_for(
          message(source, text: "/redirect right-room", native_id: "90",
                          author: op_author, reply_to: ref(source.id, "10")),
          community, directory
        )
      )

      expect(last_said).to include("redirect grant")
      expect(feature.pending.size).to eq(0)
    end

    it "recognises an operator who exists only on the deployment-configured floor" do
      watch("one")
      # No explicit operators at all, which is the shape the reported deployment had.
      floor_only = Rubotty::Core::Moderation::Directory.new([])
      telegram_source = endpoint("source", adapter: :telegram, settings: { room_key: "a" })

      feature.call(
        context_for(
          message(telegram_source, text: "/redirect right-room", native_id: "90",
                                   author: author(native_id: "77", username: "sample_owner"),
                                   reply_to: ref(telegram_source.id, "10")),
          community, floor_only
        )
      )

      expect(last_said).not_to include("permission")
    end

    it "says the channel is not in a room instead of refusing an operator who may act" do
      watch("one")
      loose = endpoint("unmapped", settings: { room_key: "z" })

      feature.call(
        context_for(
          message(loose, text: "/redirect right-room", native_id: "90",
                         author: op_author, reply_to: ref(loose.id, "10"))
        )
      )

      expect(last_said).to include("isn't in a room yet")
    end

    it "says the control plane is unreachable rather than reading as a refusal" do
      watch("one")
      registry.current = nil

      redirect!

      expect(last_said).to include("can't reach the control plane")
    end

    # An exception means the bot is broken; a refusal implies it is working, so the two
    # must never look the same.
    it "says something broke when the lookup raises, and does not call it a refusal" do
      watch("one")
      exploding = Class.new do
        def resolve(*, **) = raise("directory is on fire")
        def empty? = false
      end.new

      feature.call(
        context_for(
          message(source, text: "/redirect right-room", native_id: "90",
                          author: op_author, reply_to: ref(source.id, "10")),
          community, exploding
        )
      )

      expect(last_said).to include("Something broke")
      expect(last_said).not_to include("permission")
    end

    it "refuses a member's /end and !end alike" do
      ["/end", "!end"].each_with_index do |command, index|
        outcome = feature.call(
          context_for(message(source, text: command, native_id: "5#{index}", author: bystander))
        )

        expect(outcome).to be_halt
        expect(last_said).to eq("Only an operator can finish a redirection.")
      end
    end

    it "refuses an operator whose grant does not reach this room" do
      elsewhere = Rubotty::Core::Moderation::Operator.new(
        name: "elsewhere", identities: { fake: ["op1"] }, actions: [:redirect], rooms: ["some-other-room"]
      )
      watch("one")
      before = adapter.delivered.length

      feature.call(
        context_for(
          message(source, text: "/redirect right-room", native_id: "90",
                          author: op_author, reply_to: ref(source.id, "10")),
          community, Rubotty::Core::Moderation::Directory.new([elsewhere])
        )
      )

      expect(adapter.delivered.length).to be > before
      expect(last_said).to include("redirect grant")
    end
  end

  # A message that drew half a dozen marks used to arrive in the new room
  # looking like nobody responded to it: the reactions stayed on the original,
  # which the redirect then deleted (#1945).
  describe "carrying reactions across" do
    let(:adapter) { Fakes::ReactingAdapter.new }

    def react(native_id, emoji, actor_id: "u1")
      storage.add_reaction(ref(source.id, native_id),
                           reaction: Rubotty::Core::Reaction.new(emoji: emoji), actor_id: actor_id)
    end

    def carried
      adapter.syncs.select { |sync| sync[:endpoint_id] == target.id }
    end

    it "puts the marks from the original onto the copy" do
      watch("one")
      react("10", "🎉")
      redirect!
      end!(last: "10")
      drain

      expect(carried.first[:desired].map(&:emoji)).to eq(["🎉"])
    end

    # The bot holds one mark for everybody, so the count and the names cannot
    # cross. Every distinct reaction still travels, and each adapter's own
    # ceiling decides how many of them it keeps.
    it "carries every distinct reaction, whoever left it" do
      watch("one")
      react("10", "🎉", actor_id: "u1")
      react("10", "👀", actor_id: "u2")
      react("10", "🎉", actor_id: "u3")
      redirect!
      end!(last: "10")
      drain

      expect(carried.first[:desired].map(&:emoji)).to eq(["🎉", "👀"])
    end

    it "syncs against nothing, since the copy is new and holds no marks yet" do
      watch("one")
      react("10", "🎉")
      redirect!
      end!(last: "10")
      drain

      expect(carried.first[:previous]).to eq([])
    end

    it "asks for no sync at all on a message nobody reacted to" do
      watch("one")
      redirect!
      end!(last: "10")
      drain

      expect(carried).to be_empty
    end

    # The redirect has already moved the message by the time this runs, so a
    # platform refusing the mark must not undo that.
    it "still moves the message when placing the marks raises" do
      watch("one")
      react("10", "🎉")
      allow(adapter).to receive(:sync_reactions).and_raise(RuntimeError, "no reactions today")
      redirect!
      end!(last: "10")
      drain

      expect(reposts).to include(a_string_including("one"))
    end
  end

  describe "multi-tenant safety" do
    it "never finds a room that belongs to another community" do
      other_room = room("their-room", endpoint("theirs", settings: { room_key: "c" }))
      other = FakeCommunity.new(id: seed_community("other").id, rooms: [other_room], operators: operators)
      registry.current = FakeSnapshot.new([community, other])
      watch("one")

      redirect!(target_name: "their-room")

      expect(feature.pending.size).to eq(0)
      expect(adapter.delivered.last.last.body.text).to include("can't find a room")
    end

    it "will not step a move on behalf of a community that does not own it" do
      watch("one", "two", "three")
      redirect!
      end!
      job = durable.jobs.first

      expect(feature.step(id: job.payload[:redirection_id], community_id: seed_community("other").id))
        .to eq(:gone)
    end
  end

  describe "closing the window" do
    it "refuses when the first message is not in the window it can see" do
      watch("one", "two", "three")
      redirect!(first: "5")
      end!

      expect(models.redirection.count).to eq(0)
      expect(adapter.delivered.last.last.body.text).to include("I don't have that run")
    end

    it "says nothing is waiting when /end arrives on its own" do
      watch("one")
      end!

      expect(adapter.delivered.last.last.body.text).to include("Nothing here is waiting")
    end

    it "records the move with the operator, both ends and the count" do
      watch("one", "two", "three", "four")
      redirect!
      end!(last: "13")
      row = models.redirection.first

      expect(row.operator).to eq("sample_owner")
      expect(row.source_endpoint_id).to eq("source")
      expect(row.target_room_id).to eq("right-room")
      expect(row.message_count).to eq(4)
      expect(row.community_id).to eq(community_id)
    end
  end

  describe "the move itself" do
    before do
      watch("one", "two", "three")
      redirect!
      end!
    end

    it "reposts the run into the target room in the order it was said" do
      drain

      expect(reposts).to eq(%w[one two three])
    end

    it "deletes nothing from the source until every repost has landed" do
      order = []
      drain.each_with_index do |outcome, index|
        order << [outcome, reposts.length, deleted_from_source.length] if index < 20
      end
      first_delete = order.index { |(outcome, _, _)| outcome == :deleted }

      expect(first_delete).not_to be_nil
      expect(order[first_delete][1]).to eq(3)
    end

    it "then removes each original, one at a time, in the same order" do
      drain

      expect(deleted_from_source).to eq(%w[10 11 12])
    end

    it "signs the run off in the target room, in italics, once the reposts are in" do
      drain
      closing = posted_to_target.reject(&:chat?).last

      expect(closing.body.text).to eq("(Moved from #source by @sample_owner.)")
      expect(closing.body.spans.map(&:kind)).to eq([:italic])
    end

    # A room named in plain text is one the reader has to go and find, which is
    # the whole difference between a sign-off and a way back.
    it "makes the source room's name a link where the platform publishes one" do
      linking = adapter
      def linking.room_permalink(endpoint) = "https://example.test/#{endpoint.id}"
      drain
      closing = posted_to_target.reject(&:chat?).last
      link = closing.body.spans.find { |span| span.kind == :link }

      expect(link.attributes[:url]).to eq("https://example.test/source")
      expect(closing.body.text[link.begin_index...link.end_index]).to eq("#source")
    end

    it "paces itself at a second a step rather than posting the run at once" do
      first = durable.jobs.first.run_at
      drain(limit: 1)

      expect(durable.jobs.first.run_at - first).to be_within(0.5).of(1.0)
    end

    it "keeps exactly one pending step, so a recovered job cannot double the pace" do
      drain(limit: 1)

      expect(durable.jobs.length).to eq(1)
    end

    it "finishes by dropping the plan and keeping the record" do
      drain
      row = models.redirection.first

      expect(row.status).to eq("done")
      expect(row.plan).to be_nil
      expect(row.message_count).to eq(3)
    end
  end

  describe "a move that goes wrong half way through the reposts" do
    before do
      watch("one", "two", "three")
      redirect!
      end!
    end

    it "leaves every original in place rather than deleting what it could not repost" do
      drain(limit: 1)
      allow(adapter).to receive(:deliver).and_raise(Rubotty::AdapterError.new("down", adapter: :fake))
      job = durable.jobs.shift

      expect { feature.step(id: job.payload[:redirection_id], community_id: job.payload[:community_id]) }
        .to raise_error(Rubotty::Error)
      expect(deleted_from_source).to be_empty
      expect(models.redirection.first.status).to eq("posting")
    end
  end

  describe "what it carries" do
    it "keeps the author on each repost, so the platform can wear their face" do
      feature.call(
        context_for(message(source, text: "hello", native_id: "10", author: author(username: "ada")))
      )
      feature.call(
        context_for(message(source, text: "there", native_id: "11", author: author(username: "grace")))
      )
      redirect!
      end!(last: "11")
      drain

      # The same Core::SenderLabel shape every relayed message carries, so each platform
      # renders it the way it already does.
      expect(posted_to_target.select(&:chat?).map { |m| m.sender_label })
        .to all(be_a(Rubotty::Core::SenderLabel))
      expect(posted_to_target.select(&:chat?).map { |m| m.sender_label.primary })
        .to eq(%w[ada grace])
    end

    it "keeps the styling as spans rather than as one platform's markup" do
      feature.call(
        context_for(message(source, text: rich("bold word", span(:bold, 0, 4)), native_id: "10"))
      )
      redirect!
      end!(last: "10")
      drain
      moved = posted_to_target.find(&:chat?)

      expect(moved.body.text).to eq("bold word")
      expect(moved.body.spans.map { |s| [s.kind, s.begin_index, s.end_index] }).to eq([[:bold, 0, 4]])
    end
  end

  describe "resuming after a restart" do
    it "re-arms a move that was left in flight with no job behind it" do
      watch("one", "two")
      redirect!
      end!(last: "11")
      durable.jobs.clear

      expect(feature.resume_all).to eq(1)
      expect(durable.jobs.length).to eq(1)
    end

    it "leaves a finished move alone" do
      watch("one", "two")
      redirect!
      end!(last: "11")
      drain

      expect(feature.resume_all).to eq(0)
    end
  end

  describe "without the services it needs" do
    let(:feature) do
      described_class.new(
        topology: topology(source_room, target_room), adapters: adapters, storage: storage,
        logger: Rubotty::Log.null, registry: registry, redirections: nil, durable_scheduler: durable
      )
    end

    it "says so rather than starting a move it cannot finish" do
      watch("one")
      redirect!

      expect(adapter.delivered.last.last.body.text).to include("no control plane")
      expect(feature.pending.size).to eq(0)
    end
  end
  # A move must not die with the one message it cannot carry. A photo whose link
  # Telegram would no longer fetch ended a real move half way, leaving the run
  # copied into the target and every original still sitting in the source.
  describe "a message the target will not take" do
    # Refuses one message for good, the way a file the far side cannot fetch
    # does, rather than the one-shot fail_next the other specs here want.
    class RedirectionRefusingAdapter < Fakes::RecordingAdapter
      attr_accessor :refuse

      def deliver(message, endpoint)
        return nil if refuse && message.body.text.include?(refuse)

        super
      end
    end

    class RecordingOperatorAlerts
      attr_reader :sent

      def initialize = @sent = []

      def notify_operators!(community_id:, text:)
        @sent << { community_id: community_id, text: text }
        nil
      end
    end

    let(:adapter) { RedirectionRefusingAdapter.new.tap { |fake| fake.refuse = "two" } }
    let(:alerts) { RecordingOperatorAlerts.new }
    let(:feature) do
      described_class.new(
        topology: topology(source_room, target_room), adapters: adapters, storage: storage,
        logger: Rubotty::Log.null, registry: registry, redirections: redirections,
        durable_scheduler: durable, admin_notifier: alerts
      )
    end

    # As #drain, but every tick is the last the scheduler would give it, which
    # is when a step stops raising and starts skipping.
    def drain_spent(limit: 50)
      limit.times do
        job = durable.jobs.shift
        break if job.nil?

        feature.step(id: job.payload[:redirection_id], community_id: job.payload[:community_id],
                     last_attempt: true)
      end
    end

    def start_move
      watch("one", "two", "three")
      redirect!
      end!
    end

    # The ladder exists for a rate limit or a blip, and spending it is what
    # tells a message that will never land from one that just has not yet.
    it "raises while the retry ladder still has rungs, rather than skipping at once" do
      start_move

      expect { drain }.to raise_error(Rubotty::Features::Redirection::Unrelayable)
    end

    it "skips the one it cannot take and moves the rest" do
      start_move
      drain_spent

      expect(reposts).to include("one", "three")
      expect(reposts).not_to include("two")
    end

    # Nothing was reposted to take its place, so the original is the only copy
    # of that message anywhere and deleting it would destroy rather than move it.
    it "leaves the skipped original where it is, and still takes the others" do
      start_move
      drain_spent

      expect(deleted_from_source).to include("10", "12")
      expect(deleted_from_source).not_to include("11")
    end

    it "tells the operators which message stayed behind" do
      start_move
      drain_spent

      expect(alerts.sent.length).to eq(1)
      expect(alerts.sent.first[:community_id]).to eq(community_id)
      expect(alerts.sent.first[:text]).to include("11")
      expect(alerts.sent.first[:text]).to include("right-room")
    end

    it "carries on to the end rather than stalling on the skip" do
      start_move
      drain_spent

      row = redirections.recent(community_id: community_id).first
      expect(redirections.live(id: row.id, community_id: community_id)).to be_nil
    end
  end

  # Telegram hands out a getFile link good for about an hour and then will not
  # fetch it back, so a move replaying one fails with "failed to get HTTP URL
  # content". The file_id beside it never expires and needs no fetch.
  describe "an attachment moving within one platform" do
    let(:file) do
      Rubotty::Core::Attachment.new(kind: :photo, url: "https://api.telegram.test/file/bot9/x.jpg",
                                    native_ref: "AgACAgQAAx0", filename: "x.jpg")
    end

    def move_with_attachment
      feature.call(context_for(message(source, text: "look", native_id: "10", attachments: [file])))
      redirect!
      end!(last: "10")
      drain
    end

    it "sends the platform's own reference instead of a link it would have to fetch" do
      move_with_attachment

      sent = posted_to_target.find { |posted| posted.attachments.any? }
      expect(sent.attachments.first.native_ref).to eq("AgACAgQAAx0")
      expect(sent.attachments.first.url).to be_nil
    end

    # A file_id means nothing to the platform on the other side of a crossing,
    # so there the link is still the only thing that can carry the file.
    context "when the move crosses platforms" do
      let(:target) { endpoint("target", adapter: :elsewhere, settings: { room_key: "b" }) }

      it "keeps the link, which is all the far side can fetch" do
        move_with_attachment

        sent = posted_to_target.find { |posted| posted.attachments.any? }
        expect(sent.attachments.first.url).to eq("https://api.telegram.test/file/bot9/x.jpg")
      end
    end
  end
end
