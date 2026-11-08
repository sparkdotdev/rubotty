# frozen_string_literal: true

require "spec_helper"

# The hard part of translation groups: a two room guard can pass and still
# loop once a third joins, since room A relays into B and C, and B's copy
# can relay back into A and C if mistaken for fresh. Proven by message count
# settling, not text equality, since the fake translator varies its output.
RSpec.describe "a three room translation group", :control_plane do
  include Builders

  # A durable scheduler that keeps its jobs in a list rather than running
  # anything itself, so a spec can drain it a job at a time with nothing
  # sleeping, the same double spec/features/redirection_spec.rb and
  # spec/integration/redirection_bridged_spec.rb already use for their own
  # durable-job features.
  class TranslationListDurable
    Job = Struct.new(:kind, :run_at, :payload, :community, keyword_init: true)

    def initialize
      @jobs = []
      @handlers = {}
    end

    attr_reader :jobs

    def register(kind, max_age: nil, priority: nil, &block)
      @handlers[kind.to_s] = block
      self
    end

    def schedule(kind:, run_at:, payload: {}, community: nil, recurrence: nil, discard_payload: false)
      @jobs << Job.new(kind: kind.to_s, run_at: run_at, payload: payload, community: community)
      @jobs.length
    end

    def cancel(kind:, community: nil, &predicate)
      before = @jobs.length
      @jobs.reject! { |job| job.kind == kind.to_s && predicate.call(job.payload) }
      before - @jobs.length
    end

    # Run every job currently queued, oldest first, including any a handler
    # enqueues while running: a job that (wrongly) queued a further hop would
    # otherwise never be caught by drain.
    def drain(limit: 200)
      ran = 0
      limit.times do
        job = @jobs.shift
        break if job.nil?

        @handlers[job.kind]&.call(job)
        ran += 1
      end
      ran
    end
  end

  # A stand-in for LibreTranslate that never returns the same text twice: it tags every call
  # with the target language and hands back something longer than what it was given. A guard
  # that compared translated text to the original, or to what it last saw, would never
  # converge against this; the real guard here does not look at text at all.
  class DriftingClient
    def initialize
      @calls = []
    end

    attr_reader :calls

    def translate(text, source:, target:)
      @calls << { text: text, source: source, target: target }
      "[#{target}] #{text} (via #{source})"
    end
  end

  let(:ep_a) { endpoint("room-a-ep", adapter: :fake, account: "acct-a", settings: { room_key: "room-a" }) }
  let(:ep_b) { endpoint("room-b-ep", adapter: :fake, account: "acct-b", settings: { room_key: "room-b" }) }
  let(:ep_c) { endpoint("room-c-ep", adapter: :fake, account: "acct-c", settings: { room_key: "room-c" }) }

  let(:room_a) { room("room-a", ep_a) }
  let(:room_b) { room("room-b", ep_b) }
  let(:room_c) { room("room-c", ep_c) }

  let(:group_topology) { Rubotty::Core::Topology.new([room_a, room_b, room_c]) }

  let(:adapter_a) { Fakes::RecordingAdapter.new(account: "acct-a") }
  let(:adapter_b) { Fakes::RecordingAdapter.new(account: "acct-b") }
  let(:adapter_c) { Fakes::RecordingAdapter.new(account: "acct-c") }

  let(:adapters) do
    { [:fake, "acct-a"] => adapter_a, [:fake, "acct-b"] => adapter_b, [:fake, "acct-c"] => adapter_c }
  end

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:durable) { TranslationListDurable.new }
  let(:client) { DriftingClient.new }

  let(:community) do
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: 1, slug: "loop", name: "Loop", status: "active", settings: {}, topology: group_topology,
      channels: [
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep_a, community_id: 1, route_key: "a"),
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep_b, community_id: 1, route_key: "b"),
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep_c, community_id: 1, route_key: "c")
      ],
      operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
      feature_settings: [
        Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
          room_key: "room-a", feature: "translation", enabled: true,
          config: { "language" => "en", "group" => "welcome" }
        ),
        Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
          room_key: "room-b", feature: "translation", enabled: true,
          config: { "language" => "pt", "group" => "welcome" }
        ),
        Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
          room_key: "room-c", feature: "translation", enabled: true,
          config: { "language" => "es", "group" => "welcome" }
        )
      ]
    )
  end

  let(:snapshot) { Rubotty::ControlPlane::Snapshot.new(communities: [community]) }
  let(:registry) { Struct.new(:current).new(snapshot) }

  def build_relay(loop_guard)
    Rubotty::Translation::Relay.new(
      scheduler: durable, storage: storage, topology: group_topology, adapters: adapters,
      loop_guard: loop_guard, logger: Rubotty::Log.null, client: client,
      segmenter: Rubotty::Translation::Segmenter.new
    )
  end

  def build_router(loop_guard, relay)
    Rubotty::Core::Router.new(
      topology: group_topology, adapters: adapters, storage: storage, loop_guard: loop_guard,
      logger: Rubotty::Log.null, registry: registry, translation_relay: relay
    )
  end

  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:relay) { build_relay(loop_guard) }
  let(:route) { build_router(loop_guard, relay) }

  def alice = author(native_id: "alice", username: "alice", first_name: "Alice")

  def bob = author(native_id: "bob", username: "bob", first_name: "Bob")

  def say(endpoint, text, native_id:, from:)
    route.handle(message(endpoint, text: text, native_id: native_id, author: from))
  end

  def total_delivered
    adapter_a.delivered.length + adapter_b.delivered.length + adapter_c.delivered.length
  end

  # The (endpoint, native id) Relay actually posted a copy under, read back
  # from the SAME durable message map Bridge itself would consult: this is
  # how a real gateway's own echo would be addressed too.
  def posted_ref(source_ref, endpoint_id)
    storage.counterparts(source_ref, endpoint_id: endpoint_id).first
  end

  # Feed back one of the bot's own posts exactly as a real gateway would: a fresh inbound
  # :chat event on the endpoint it landed on, its native id, and, the harder case, attributed
  # to the original human author rather than the bot's own account, the shape a Discord
  # webhook impersonation produces and self-authorship alone cannot recognise.
  def echo_of(ref, author_impersonated)
    message(Rubotty::Core::Endpoint.new(id: ref.endpoint_id, adapter_name: :fake, account: "irrelevant"),
            text: "echoed", native_id: ref.native_id, author: author_impersonated, kind: :chat)
  end

  it "translates one message into both other rooms of a three room group" do
    say(ep_a, "hello", native_id: "m1", from: alice)
    durable.drain

    expect(adapter_a.delivered.length).to eq(0)
    expect(adapter_b.delivered.length).to eq(1)
    expect(adapter_c.delivered.length).to eq(1)

    b_text = adapter_b.delivered.first.last.body.text
    c_text = adapter_c.delivered.first.last.body.text
    expect(b_text).to include("[pt] hello (via en)")
    expect(c_text).to include("[es] hello (via en)")
    # Attribution: the copy shows Alice, not the bot.
    expect(adapter_b.delivered.first.last.sender_label.to_s).to include("alice")
  end

  it "never re-translates a translated copy, in either direction, so the group settles" do
    say(ep_a, "hello", native_id: "m1", from: alice)
    durable.drain
    expect(total_delivered).to eq(2)
    expect(client.calls.length).to eq(2)

    source = ref(ep_a.id, "m1")
    b_ref = posted_ref(source, ep_b.id)
    c_ref = posted_ref(source, ep_c.id)
    expect(b_ref).not_to be_nil
    expect(c_ref).not_to be_nil

    # The gateway on room B and room C both report the bot's own post back, attributed to
    # Alice (impersonated), exactly the shape a Discord webhook relay produces. If either
    # were mistaken for new content it would queue two more translations, into the other
    # two rooms, and the group would never stop growing.
    route.handle(echo_of(b_ref, alice))
    route.handle(echo_of(c_ref, alice))
    durable.drain

    expect(durable.jobs).to be_empty
    expect(client.calls.length).to eq(2)
    expect(total_delivered).to eq(2)

    # Run the exact same two echoes through again. A guard with any memory
    # leak or any path that re-queues on a repeat would show it here.
    route.handle(echo_of(b_ref, alice))
    route.handle(echo_of(c_ref, alice))
    durable.drain

    expect(total_delivered).to eq(2)
    expect(client.calls.length).to eq(2)
  end

  it "still recognises its own copies after a restart, with no ledger to remember them" do
    say(ep_a, "hello", native_id: "m1", from: alice)
    durable.drain
    expect(total_delivered).to eq(2)

    source = ref(ep_a.id, "m1")
    b_ref = posted_ref(source, ep_b.id)
    c_ref = posted_ref(source, ep_c.id)

    # A fresh LoopGuard over the SAME storage: no in-memory ledger, no
    # remembered identities, exactly what a process restart leaves behind.
    # Only the durable message map survives, which is the point of dual
    # writing a translated copy's destination into it at creation time.
    restarted_guard = Rubotty::Core::LoopGuard.new(storage: storage)
    restarted_relay = build_relay(restarted_guard)
    restarted_route = build_router(restarted_guard, restarted_relay)

    restarted_route.handle(echo_of(b_ref, alice))
    restarted_route.handle(echo_of(c_ref, alice))
    durable.drain

    expect(durable.jobs).to be_empty
    expect(client.calls.length).to eq(2)
    expect(total_delivered).to eq(2)
  end

  it "keeps settling when a second room originates a message, three way and both directions" do
    say(ep_a, "hello", native_id: "m1", from: alice)
    durable.drain
    expect(total_delivered).to eq(2)

    # Bob, a genuinely different person, says something new in room B.
    say(ep_b, "bom dia", native_id: "m2", from: bob)
    durable.drain

    expect(adapter_a.delivered.length).to eq(1)
    expect(adapter_b.delivered.length).to eq(1)
    expect(adapter_c.delivered.length).to eq(2)
    expect(total_delivered).to eq(4)

    source_a = ref(ep_a.id, "m1")
    source_b = ref(ep_b.id, "m2")
    echoes = [
      echo_of(posted_ref(source_a, ep_b.id), alice), echo_of(posted_ref(source_a, ep_c.id), alice),
      echo_of(posted_ref(source_b, ep_a.id), bob), echo_of(posted_ref(source_b, ep_c.id), bob)
    ]
    echoes.each { |echo| route.handle(echo) }
    durable.drain

    expect(durable.jobs).to be_empty
    expect(total_delivered).to eq(4)
    expect(client.calls.length).to eq(4)
  end
end
