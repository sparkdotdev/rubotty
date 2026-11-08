# frozen_string_literal: true

require "spec_helper"

# The in-chat face of the operator flow, driven against the real seeded SAMPLE control plane
# so request, notify, approve, grant and live recognition all run for real.
RSpec.describe Rubotty::Features::OperatorRequests, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:flow) do
    Rubotty::ControlPlane::OperatorFlow.new(models: models, registry: registry, logger: Rubotty::Log.null)
  end
  # registry: registry so a controls.set write reloads the snapshot #run reads
  # context.community from, the same way the dashboard does.
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  # One fake adapter serves every endpoint, so every post is captured on the same recorder.
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      operator_flow: flow, ephemeral: ephemeral
    )
  end

  # The gaming room's telegram endpoint, where commands are typed.
  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  # A non-operator newcomer on Telegram.
  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New", last_name: "Bie")
  end

  # The seeded bootstrap operator on Telegram (sample_owner).
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  # A fresh Context off the current snapshot, so a reload between calls is picked up.
  def run(text, author:, config: {}, native_id: "m#{rand(100_000)}")
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key("tg-gaming")
    msg = message(origin, text: text, native_id: native_id, author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: config))
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  describe "the feature contract" do
    it "names itself, is off by code default, and observes only chat" do
      expect(described_class.feature_name).to eq("operator_requests")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "refuses rather than relays a recognised /operator without a control plane" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "/operator request")))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/operator")
    end

    it "still lets an unrecognised message continue with no control plane at all" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "ignores an ordinary message, letting it continue down the pipeline" do
      expect(run("just chatting about the game", author: newcomer)).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "requesting in a community channel" do
    it "creates a pending request for the channel's community and acknowledges it" do
      outcome = run("/operator request", author: newcomer)

      expect(outcome).to be_halt # swallowed, never relayed as content
      pending = flow.pending(community_id: registry.current.community("sample").id)
      expect(pending.size).to eq(1)
      expect(pending.first.requester_native_id).to eq("999888")
      expect(ack_on("tg-gaming")).to match(/request .*is in/i)
    end

    it "records the requester's identity: platform, id and handle" do
      run("/operator request", author: newcomer)
      request = flow.pending(community_id: registry.current.community("sample").id).first
      expect(request.adapter).to eq("telegram")
      expect(request.requester_native_id).to eq("999888")
      expect(request.requester_username).to eq("newbie")
    end

    it "treats a bare /operator as a request" do
      run("/operator", author: newcomer)
      expect(flow.pending(community_id: registry.current.community("sample").id).size).to eq(1)
    end

    # Discord reserves a leading "/" for its native slash-command UI, so "!" has to work too.
    it "recognises the operator command under the alternate ! prefix as well as /" do
      outcome = run("!operator request", author: newcomer)
      expect(outcome).to be_halt
      expect(flow.pending(community_id: registry.current.community("sample").id).size).to eq(1)
    end

    it "leaves an unknown prefixed token alone, so the bridge relays it" do
      outcome = run("!operatorish musings", author: newcomer)
      expect(outcome).to be_continue
      expect(flow.pending(community_id: registry.current.community("sample").id)).to be_empty
    end

    it "honours a community's restricted prefix set: with only /, ! is not the operator command" do
      controls.set(community: registry.current.community("sample"), selector: "all", feature: "commands",
                   key: "prefixes", value: ["/"])
      outcome = run("!operator request", author: newcomer)
      expect(outcome).to be_continue
      expect(flow.pending(community_id: registry.current.community("sample").id)).to be_empty
    end

    it "deduplicates a repeat request and says so" do
      run("/operator request", author: newcomer)
      run("/operator request", author: newcomer)
      expect(flow.pending(community_id: registry.current.community("sample").id).size).to eq(1)
      expect(ack_on("tg-gaming")).to match(/already have a pending/i)
    end

    it "tells an existing operator there is nothing to request" do
      run("/operator request", author: boss)
      expect(ack_on("tg-gaming")).to match(/already an operator/i)
      expect(flow.pending(community_id: registry.current.community("sample").id)).to be_empty
    end
  end

  describe "notifying existing operators" do
    it "posts the request to the configured operator channel with how to act" do
      run("/operator request", author: newcomer, config: { notify_room: "general" })

      posted = adapter.delivered_to("tg-general").map { |m| m.body.text }
      expect(posted.last).to match(/New operator request #\d+ from/)
      expect(posted.last).to match(%r{/operator approve \d+})
      # Both endpoints of the operator room are notified.
      expect(adapter.delivered_to("dc-general")).not_to be_empty
    end

    it "still records the request and stays silent to the room when no operator channel is set" do
      run("/operator request", author: newcomer)
      expect(adapter.delivered_to("tg-general")).to be_empty
      expect(flow.pending(community_id: registry.current.community("sample").id).size).to eq(1)
    end
  end

  # A slash command gets an ephemeral answer and takes its own invocation with
  # it. /operator replied and left the typed command sitting in the channel.
  describe "clearing up after itself" do
    let(:base) { Time.now }
    let(:clock) { -> { @now ||= base } }
    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }

    def advance(seconds) = (@now = (@now || base) + seconds)

    subject(:feature) do
      described_class.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        operator_flow: flow, ephemeral: ephemeral, cleanup: scheduler
      )
    end

    after { scheduler.stop }

    it "removes the invocation together with the reply it produced" do
      run("/operator request", author: newcomer, config: { ack_ttl_seconds: 5 }, native_id: "typed-1")

      advance(5)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-gaming typed-1])
    end

    it "leaves the invocation where the scope asked to keep it" do
      run("/operator request", author: newcomer, native_id: "typed-2",
          config: { ack_ttl_seconds: 5, delete_command_message: false })

      advance(5)
      scheduler.run_due

      expect(adapter.deleted).not_to include(%w[tg-gaming typed-2])
    end

    # The refusal path answers too, and it is the one a stranger sees most.
    it "clears up after a refused subcommand as well as an accepted one" do
      run("/operator approve 1", author: newcomer, config: { ack_ttl_seconds: 5 }, native_id: "typed-3")

      advance(5)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-gaming typed-3])
    end

    it "reads its window from the same key every other command feature uses" do
      run("/operator request", author: newcomer, config: { ack_ttl_seconds: 0 }, native_id: "typed-4")

      expect(scheduler.pending).to eq(0)
      expect(ack_on("tg-gaming")).to match(/operator request/i)
    end
  end

  # A new-request notice is a job an operator still has to do, not an answer to
  # something somebody just typed, so it gets a far longer horizon than an ack.
  describe "how long the operator notice lives" do
    let(:posts) { [] }
    let(:ephemeral) do
      Class.new do
        def initialize(log) = @log = log

        def post(**kwargs)
          @log << kwargs
          Object.new.tap { |group| def group.any? = false }
        end
      end.new(posts)
    end

    def notice = posts.find { |post| post[:body].text.include?("New operator request") }

    it "posts it with a week's horizon by default rather than none at all" do
      run("/operator request", author: newcomer, config: { notify_room: "general" })

      expect(notice[:delete_after]).to eq(described_class::DEFAULT_NOTIFY_TTL_SECONDS)
    end

    it "honours a scope that wants it gone sooner" do
      run("/operator request", author: newcomer, config: { notify_room: "general", notify_ttl_seconds: 3600 })

      expect(notice[:delete_after]).to eq(3600)
    end
  end

  describe "approving a request" do
    def pending_id = flow.pending(community_id: registry.current.community("sample").id).first.id

    before { run("/operator request", author: newcomer) }

    it "grants the operator when an existing operator approves, and acknowledges it" do
      outcome = run("/operator approve #{pending_id}", author: boss)
      expect(outcome).to be_halt
      expect(ack_on("tg-gaming")).to match(/Approved request/i)
      expect(flow.resolve_operator(community_id: registry.current.community("sample").id,
                                   adapter: "telegram", native_id: "999888")).to be_truthy
    end

    it "recognises the newly-granted operator LIVE, with no restart (the Snapshot swapped)" do
      # Before approval the directory does not know them.
      expect(registry.current.community("sample").operators.resolve(:telegram, "999888")).to be_nil

      run("/operator approve #{pending_id}", author: boss)

      # The next message resolves against the reloaded snapshot.
      operator = registry.current.community("sample").operators.resolve(:telegram, "999888")
      expect(operator).not_to be_nil
      expect(operator.may?(:delete, "gaming", community_id: registry.current.community("sample").id)).to be(true)
    end

    it "lets the freshly-granted operator immediately approve the next request" do
      run("/operator approve #{pending_id}", author: boss)
      # A second newcomer requests; the just-promoted operator approves them.
      second = Rubotty::Core::Author.new(native_id: "777", username: "second")
      run("/operator request", author: second)
      new_id = flow.pending(community_id: registry.current.community("sample").id).first.id

      run("/operator approve #{new_id}", author: newcomer) # newcomer is now an operator
      expect(flow.resolve_operator(community_id: registry.current.community("sample").id,
                                   adapter: "telegram", native_id: "777")).to be_truthy
    end

    # Telegram will not let a bot open a private chat with somebody who has
    # never opened one with it, so an operator granted in a group can hold the
    # role and hear nothing. The grant is the one moment they are certainly
    # reading, so it is where they are told.
    describe "whether the new operator can actually be reached" do
      let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1", admin_dm: true) }

      def identity
        operator = flow.resolve_operator(community_id: registry.current.community("sample").id,
                                         adapter: "telegram", native_id: "999888")
        models.person_identity.where(person_id: operator.person_id, adapter: "telegram").first
      end

      it "welcomes a reachable one privately, and adds nothing to the channel" do
        run("/operator approve #{pending_id}", author: boss)

        expect(adapter.dms_sent.last[:native_id]).to eq("999888")
        expect(adapter.dms_sent.last[:text]).to match(/now an operator of/i)
        expect(ack_on("tg-gaming")).not_to match(%r{/start})
      end

      it "tells the channel what the new operator has to do when the DM is refused" do
        allow(adapter).to receive(:send_admin_dm).and_return(nil)

        run("/operator approve #{pending_id}", author: boss)

        expect(ack_on("tg-gaming")).to match(/Approved request/i)
        expect(ack_on("tg-gaming")).to match(%r{private chat with me and send /start})
      end

      it "remembers the refusal, so the dashboard says so too" do
        allow(adapter).to receive(:send_admin_dm).and_return(nil)
        run("/operator approve #{pending_id}", author: boss)

        expect(identity.dm_refused_at).not_to be_nil
      end

      # The row is committed before this runs and nothing here may undo it.
      it "grants the operator anyway when the welcome DM blows up" do
        allow(adapter).to receive(:send_admin_dm).and_raise(StandardError, "network gone")

        run("/operator approve #{pending_id}", author: boss)

        expect(flow.resolve_operator(community_id: registry.current.community("sample").id,
                                     adapter: "telegram", native_id: "999888")).to be_truthy
        expect(ack_on("tg-gaming")).to match(/Approved request/i)
      end

      # A platform with no DM at all says nothing about the person, so nagging
      # them about a private chat would be nonsense.
      it "says nothing extra where the platform has no DM to refuse" do
        allow(adapter).to receive(:supports_admin_dm?).and_return(false)

        run("/operator approve #{pending_id}", author: boss)

        expect(ack_on("tg-gaming")).not_to match(%r{/start})
      end
    end
  end

  describe "denying a request" do
    def pending_id = flow.pending(community_id: registry.current.community("sample").id).first.id

    before { run("/operator request", author: newcomer) }

    it "marks it denied and grants nobody" do
      run("/operator deny #{pending_id}", author: boss)
      expect(models.operator_request.where(state: "denied").count).to eq(1)
      expect(flow.resolve_operator(community_id: registry.current.community("sample").id,
                                   adapter: "telegram", native_id: "999888")).to be_nil
    end
  end

  describe "permission enforcement" do
    before { run("/operator request", author: newcomer) }

    def pending_id = flow.pending(community_id: registry.current.community("sample").id).first.id

    it "answers a non-operator's approve with the requirement, and grants nothing" do
      id = pending_id
      adapter.delivered.clear # drop the request acknowledgement from the before block
      stranger = Rubotty::Core::Author.new(native_id: "5150", username: "rando")
      outcome = run("/operator approve #{id}", author: stranger)

      expect(outcome).to be_halt
      expect(ack_on("tg-gaming")).to match(/operator standing/i)
      expect(models.operator_request[id].state).to eq("pending")
      expect(flow.resolve_operator(community_id: registry.current.community("sample").id,
                                   adapter: "telegram", native_id: "999888")).to be_nil
    end

    it "does not let the requester approve their own request" do
      id = pending_id
      run("/operator approve #{id}", author: newcomer)
      expect(models.operator_request[id].state).to eq("pending")
    end
  end

  describe "listing pending requests" do
    it "shows an operator the open requests" do
      run("/operator request", author: newcomer)
      run("/operator list", author: boss)
      expect(ack_on("tg-gaming")).to match(/Pending operator requests/i)
      expect(ack_on("tg-gaming")).to match(/999888|newbie/)
    end

    it "tells a non-operator they may not list, without naming who is one" do
      run("/operator request", author: newcomer)
      adapter.delivered.clear
      run("/operator list", author: Rubotty::Core::Author.new(native_id: "5150", username: "rando"))
      expect(ack_on("tg-gaming")).to match(/operator standing/i)
      expect(ack_on("tg-gaming")).not_to match(/sample_owner|newbie/i)
    end
  end

  # sample_owner's DB row is the seeded bootstrap operator, so approving
  # through it proves nothing about the deployment-configured floor. owner_handle is baked
  # into the floor too (config/protected_operators.yml) but carries no row
  # anywhere in SAMPLE, the shape the reported deployment actually had.
  describe "a deployment-configured operator with no explicit row of their own" do
    def floor_owner
      Rubotty::Core::Author.new(native_id: "70099", username: "owner_handle")
    end

    def pending_id = flow.pending(community_id: registry.current.community("sample").id).first.id

    before { run("/operator request", author: newcomer) }

    it "lets them approve a pending request" do
      outcome = run("/operator approve #{pending_id}", author: floor_owner)
      expect(outcome).to be_halt
      expect(ack_on("tg-gaming")).to match(/Approved request/i)
      expect(flow.resolve_operator(community_id: registry.current.community("sample").id,
                                   adapter: "telegram", native_id: "999888")).to be_truthy
    end

    it "lets them list pending requests" do
      outcome = run("/operator list", author: floor_owner)
      expect(outcome).to be_halt
      expect(ack_on("tg-gaming")).to match(/Pending operator requests/i)
    end
  end
end
