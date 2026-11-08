# frozen_string_literal: true

require "spec_helper"

# The feature-level contract only: call(context) fans out and halts, per kind. The relay
# logic itself is exercised through the Router that composes this feature.
RSpec.describe Rubotty::Features::Bridge do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  subject(:bridge) do
    described_class.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: loop_guard,
      logger: Rubotty::Log.null,
      ttl: 3600
    )
  end

  def context(message, config: {})
    Rubotty::Features::Context.new(message: message, config: config)
  end

  it "declares itself as the bridge feature, on by default, terminal for every relayable kind" do
    expect(described_class.feature_name).to eq("bridge")
    expect(described_class.default_enabled?).to be(true)
    expect(described_class.observes)
      .to include(:chat, :edit, :delete, :reaction_add, :reaction_remove, :reaction_sync)
  end

  # Every example elsewhere in this file calls #call directly, so it keeps passing
  # whatever the observes list says. These drive one real message per observed kind
  # through a real Pipeline, which is the only place the list is read.
  describe "every kind it observes, driven through the real pipeline" do
    let(:reacting) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }

    # The relay is on by code default, so the pipeline decides to run it with no
    # control plane behind it.
    let(:pipeline) do
      Rubotty::Features::Pipeline.new(
        features: [
          described_class.new(
            topology: topology(room("r", tg, dc)), adapters: Hash.new(reacting), storage: storage,
            loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
          )
        ],
        logger: Rubotty::Log.null
      )
    end

    # The copy of tg:5 already sitting on dc that an edit, a delete and a reaction
    # all reach for.
    def mapped!
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
    end

    # Somebody already holding the emoji, so a removal has an aggregate to move.
    def held!(actor: "u1")
      storage.add_reaction(ref("tg", "5"), reaction: thumbs, actor_id: actor)
    end

    def arrives(kind, text: "", **rest)
      pipeline.handle(message(tg, kind: kind, native_id: "5", text: text, **rest))
    end

    def anything_left_the_room
      reacting.delivered + reacting.edited + reacting.deleted + reacting.syncs
    end

    observes_kind :chat, "a message posted in one room reaches the other platform" do
      arrives(:chat, text: "hello")
      reacting.delivered_to("dc")
    end

    observes_kind :edit, "an edit reaches the copy already standing on the other platform" do
      mapped!
      arrives(:edit, text: "hello, fixed")
      reacting.edited
    end

    observes_kind :delete, "a removal takes the copy on the other platform down with it" do
      mapped!
      arrives(:delete)
      reacting.deleted
    end

    observes_kind :join, "the other platform is told somebody arrived" do
      arrives(:join)
      reacting.delivered_to("dc")
    end

    observes_kind :leave, "the other platform is told somebody left" do
      arrives(:leave)
      reacting.delivered_to("dc")
    end

    observes_kind :system, "a room event the platform reports carries across too" do
      arrives(:system, text: "the room was renamed")
      reacting.delivered_to("dc")
    end

    observes_kind :reaction_add, "an emoji somebody placed is mirrored onto the copy" do
      mapped!
      arrives(:reaction_add, reaction: thumbs)
      reacting.syncs
    end

    observes_kind :reaction_remove, "taking the last one back clears the mirror again" do
      mapped!
      held!
      arrives(:reaction_remove, reaction: thumbs)
      reacting.syncs
    end

    observes_kind :reaction_sync, "an anonymous count still moves the mirrored set" do
      mapped!
      arrives(:reaction_sync, reaction_set: [thumbs])
      reacting.syncs
    end

    observes_kind :reaction_clear, "a bulk clear takes the whole mirrored aggregate down" do
      mapped!
      held!
      arrives(:reaction_clear, reaction: thumbs)
      reacting.syncs
    end

    # The deliberate omission, and the only one: a press belongs to the card it sits
    # under, and the surface that owns the card counts it.
    ignores_kind :button_press, "a press on a card stays on the platform it was made on" do
      mapped!
      arrives(:button_press, button: Rubotty::Polls::VoteButtons.token_for(1))
      anything_left_the_room
    end

    covers_every_observed_kind
  end

  describe "redirection message-map retention" do
    let(:retained_room) { room("r", tg, dc) }
    let(:retained_community) do
      Struct.new(:enabled) do
        def room_key_of(_endpoint) = "r"

        def feature_enabled?(_endpoint, _feature) = enabled
      end.new(true)
    end

    let(:retained_bridge) do
      described_class.new(
        topology: topology(retained_room), adapters: Hash.new(adapter), storage: storage,
        loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, redirection_window: Object.new
      )
    end

    def mapped_expiry(enabled: true)
      retained_community.enabled = enabled
      receipt = Rubotty::Core::DeliveryReceipt.new(endpoint_id: dc.id, native_id: "copy")
      retained_bridge.send(:record, message(tg, native_id: "source"), receipt, retained_room, retained_community)
      storage.instance_variable_get(:@entries).last.expires_at
    end

    it "keeps cross-platform links for the retained redirection window" do
      before = Time.now

      expect(mapped_expiry).to be_within(1).of(before + Rubotty::ControlPlane::RedirectionWindow::TTL_SECONDS)
    end

    it "keeps the ordinary message-map lifetime when redirection is off" do
      before = Time.now

      expect(mapped_expiry(enabled: false)).to be_within(1).of(before + 3600)
    end
  end

  # Working out why a reaction never crossed took screenshots and a code read,
  # because every one of these returned nothing and said nothing on the way out.
  describe "saying why a reaction was dropped" do
    let(:logs) { StringIO.new }
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:reacting_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

    def loud_bridge(the_adapter = reacting_adapter, room_endpoints: [tg, dc])
      described_class.new(
        topology: topology(room("r", *room_endpoints)), adapters: Hash.new(the_adapter),
        storage: storage, loop_guard: loop_guard,
        logger: Rubotty::Log.build(level: "debug", io: logs), ttl: 3600
      )
    end

    def react(the_bridge, native_id: "5", actor: "alice", kind: :reaction_add, config: {})
      the_bridge.call(
        context(
          Rubotty::Core::Message.new(
            kind: kind, ref: ref("tg", native_id), origin: tg,
            author: author(native_id: actor), reaction: thumbs
          ),
          config: config
        )
      )
    end

    it "names the target that holds no copy of the reacted-to message" do
      react(loud_bridge, config: { reaction_notices: :native })
      expect(logs.string).to include("holds no copy of it")
      expect(logs.string).to include("dc")
    end

    it "names the target that has reaction relaying turned off" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      react(loud_bridge(room_endpoints: [tg, endpoint("dc", relay: { reactions: false })]))
      expect(logs.string).to include("reactions are off there")
    end

    it "says the target cannot hold a reaction at all" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      react(loud_bridge(Fakes::RecordingAdapter.new(own_id: "bot-1")))
      expect(logs.string).to include("cannot hold a reaction")
    end

    it "says when a redelivery lost the claim to another instance" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      the_bridge = loud_bridge
      react(the_bridge)
      react(the_bridge)
      expect(logs.string).to include("already relayed by another instance")
    end

    it "says when the aggregate did not move" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      the_bridge = loud_bridge
      react(the_bridge, actor: "alice", config: { reaction_notices: :native })
      react(the_bridge, actor: "bob", config: { reaction_notices: :native })
      expect(logs.string).to include("the aggregate did not move")
    end

    it "names the endpoint that belongs to no room" do
      the_bridge = described_class.new(
        topology: topology(room("r", dc)), adapters: Hash.new(reacting_adapter),
        storage: storage, loop_guard: loop_guard,
        logger: Rubotty::Log.build(level: "debug", io: logs), ttl: 3600
      )
      react(the_bridge)
      expect(logs.string).to include("endpoint tg is in no room")
    end

    it "says why a count-only update moved nothing" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      the_bridge = loud_bridge
      2.times do
        the_bridge.call(
          context(
            Rubotty::Core::Message.new(
              kind: :reaction_sync, ref: ref("tg", "5"), origin: tg, reaction_set: [thumbs]
            )
          )
        )
      end
      expect(logs.string).to include("reaction count on tg:5, the aggregate did not move")
    end
  end

  # The bridge records the mirror as placed for anything sync_reactions returns
  # without raising, and storage has already written the emoji as held, so an
  # adapter that swallows a 403 or a 429 leaves the aggregate believing in an
  # emoji the message does not carry.
  describe "a target that refuses the reaction" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:reacting_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

    let(:reacting_bridge) do
      described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(reacting_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
    end

    before { storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r") }

    def react
      reacting_bridge.call(
        context(
          Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "5"), origin: tg,
            author: author(native_id: "alice"), reaction: thumbs
          )
        )
      )
    end

    it "records the mirror as done when the call goes through" do
      expect(react.value.map(&:status)).to eq([:done])
    end

    it "records nothing when the platform refuses" do
      allow(reacting_adapter).to receive(:sync_reactions)
        .and_raise(Rubotty::PermissionError.new("Forbidden", adapter: :fake))
      expect(react.value).to be_empty
    end
  end

  it "fans a chat message out to the other endpoint and halts" do
    outcome = bridge.call(context(message(tg, text: "hi")))
    expect(adapter.delivered.map(&:first)).to eq(["dc"])
    expect(outcome).to be_halt
    expect(outcome.value.map(&:endpoint_id)).to eq(["dc"])
  end

  # A slash-command interaction is rebuilt as a Core::Message whose ref names no real posted
  # message, so relaying it would use an id the platform's REST API refuses.
  it "never relays a synthetic message (a slash-command interaction that fell through to it)" do
    outcome = bridge.call(context(message(tg, text: "/help", synthetic: true)))
    expect(adapter.delivered).to be_empty
    expect(outcome).to be_halt
    expect(outcome.value).to eq([])
  end

  it "propagates an edit across the copies it made" do
    bridge.call(context(message(tg, text: "hi", native_id: "5")))
    bridge.call(context(message(tg, text: "fixed", native_id: "5", kind: :edit)))
    expect(adapter.edited.map { |(id, native, _)| [id, native] }).to eq([%w[dc d1]])
  end

  it "propagates a delete across the copies it made and forgets the mapping" do
    bridge.call(context(message(tg, text: "hi", native_id: "5")))
    bridge.call(context(message(tg, text: "", native_id: "5", kind: :delete)))
    expect(adapter.deleted).to eq([%w[dc d1]])
    expect(storage.counterparts(ref("tg", "5"))).to be_empty
  end

  # Reaction state belongs to the map row it hangs off. Stamping it with a fresh
  # TTL at the moment somebody reacted let a late reaction outlive that row and
  # keep answering for a message the map had already forgotten.
  describe "how long reaction state lives" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }

    def reacts
      bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "5"), origin: tg,
            author: author(native_id: "alice"), reaction: thumbs
          )
        )
      )
    end

    it "expires a reaction with the map row it belongs to" do
      expiry = Time.now + 60
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r", expires_at: expiry)
      reacts
      storage.purge(now: expiry + 1)
      expect(storage.reactions_on(ref("tg", "5"))).to be_empty
    end

    it "falls back to its own TTL when the map holds no row to inherit from" do
      reacts
      storage.purge(now: Time.now + 120)
      expect(storage.reactions_on(ref("tg", "5"))).to eq([thumbs])
    end
  end

  # counterparts(ref) + origins(ref) only ever reaches one hop from wherever the delete
  # arrived: on the origin that already covers every copy, since counterparts of the origin
  # IS every copy, but on a copy a copy's own counterparts is empty, origins gives the
  # original, and the original's other copies were never asked for.
  describe "delete fan-out from a relayed copy, not the origin (#613)" do
    let(:mx) { endpoint("mx") }

    subject(:three_way_bridge) do
      described_class.new(
        topology: topology(room("r", tg, dc, mx)), adapters: Hash.new(adapter), storage: storage,
        loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
    end

    it "removes the sibling copy too when the delete arrives on one relayed copy" do
      three_way_bridge.call(context(message(tg, text: "hi", native_id: "5")))
      copies = storage.counterparts(ref("tg", "5"))
      dc_copy = copies.find { |candidate| candidate.endpoint_id == "dc" }.native_id
      adapter.deleted.clear

      three_way_bridge.call(context(message(dc, text: "", native_id: dc_copy, kind: :delete)))

      expect(adapter.deleted.map(&:first)).to include("tg").and include("mx")
    end

    it "still deletes only once when the origin later echoes its own removal back" do
      three_way_bridge.call(context(message(tg, text: "hi", native_id: "5")))
      copies = storage.counterparts(ref("tg", "5"))
      dc_copy = copies.find { |candidate| candidate.endpoint_id == "dc" }.native_id
      adapter.deleted.clear

      three_way_bridge.call(context(message(dc, text: "", native_id: dc_copy, kind: :delete)))
      three_way_bridge.call(context(message(tg, text: "", native_id: "5", kind: :delete)))

      expect(adapter.deleted.count { |(id, _)| id == "mx" }).to eq(1)
    end

    # A reaction is stored keyed on whichever ref it actually arrived on
    # (Bridge#handle_reaction uses message.ref directly), so a reaction left on a
    # non-origin copy sits under that copy's own ref, not the origin's (issue #1573).
    it "clears reaction_state on every copy, not only on the ref the delete arrived on" do
      three_way_bridge.call(context(message(tg, text: "hi", native_id: "5")))
      copies = storage.counterparts(ref("tg", "5"))
      dc_ref = copies.find { |candidate| candidate.endpoint_id == "dc" }
      mx_ref = copies.find { |candidate| candidate.endpoint_id == "mx" }
      storage.add_reaction(dc_ref, reaction: Rubotty::Core::Reaction.new(emoji: "👍"), actor_id: "u1")

      three_way_bridge.call(context(message(tg, text: "", native_id: "5", kind: :delete)))

      expect(storage.reactions_on(dc_ref)).to be_empty
      expect(storage.reactions_on(mx_ref)).to be_empty
      expect(storage.reactions_on(ref("tg", "5"))).to be_empty
    end
  end

  # The reaction counterpart of the delete fan-out above: from one copy, the other
  # copy is only reachable back through the original.
  describe "a reaction on one relayed copy in a room of three" do
    let(:mx) { endpoint("mx") }
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:reacting_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

    subject(:three_way_bridge) do
      described_class.new(
        topology: topology(room("r", tg, dc, mx)), adapters: Hash.new(reacting_adapter), storage: storage,
        loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
    end

    before do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "copy-dc"), room_id: "r")
      storage.record(source: ref("tg", "5"), destination: ref("mx", "copy-mx"), room_id: "r")
    end

    def react_on_dc_copy(kind = :reaction_add, config: { reaction_notices: :both })
      three_way_bridge.call(
        context(
          Rubotty::Core::Message.new(
            kind: kind, ref: ref("dc", "copy-dc"), origin: dc,
            author: author(native_id: "kanit", username: "kanit", first_name: nil), reaction: thumbs
          ),
          config: config
        )
      )
    end

    def syncs_onto(endpoint_id)
      reacting_adapter.syncs.select { |sync| sync[:endpoint_id] == endpoint_id }
    end

    it "places the emoji on the sibling copy as well as on the original" do
      react_on_dc_copy

      expect(syncs_onto("tg").map { |sync| sync[:native_id] }).to eq(["5"])
      expect(syncs_onto("mx").map { |sync| sync[:native_id] }).to eq(["copy-mx"])
      expect(syncs_onto("mx").last[:desired]).to eq([thumbs])
    end

    it "threads the notice on the third endpoint to its own copy" do
      react_on_dc_copy

      onto_mx = reacting_adapter.delivered_to("mx")
      expect(onto_mx.map { |msg| msg.body.text }).to eq(["kanit@fake reacted 👍"])
      expect(onto_mx.last.reply_to).to eq(ref("mx", "copy-mx"))
    end

    it "takes the emoji back off the sibling copy when the reaction is removed" do
      react_on_dc_copy
      react_on_dc_copy(:reaction_remove)

      expect(syncs_onto("mx").last).to include(native_id: "copy-mx", desired: [], previous: [thumbs])
    end

    it "does not count back an emoji it mirrored onto the sibling copy itself" do
      react_on_dc_copy(config: { reaction_notices: :native })
      placed = reacting_adapter.syncs.size

      three_way_bridge.call(
        context(
          Rubotty::Core::Message.new(
            kind: :reaction_sync, ref: ref("mx", "copy-mx"), origin: mx, reaction_set: [thumbs]
          ),
          config: { reaction_notices: :native }
        )
      )

      expect(reacting_adapter.syncs.size).to eq(placed)
    end
  end

  it "reads the message from the context, not from a constructor argument" do
    bridge.call(context(message(tg, text: "one", native_id: "1")))
    bridge.call(context(message(tg, text: "two", native_id: "2")))
    expect(adapter.delivered.size).to eq(2)
  end

  # A zero-downtime deploy briefly runs two containers on one bot token, and a gateway RESUME
  # can redeliver an event, so an atomic claim in shared storage makes every relay exactly-once.
  describe "idempotent relay (#74)" do
    it "relays a source message only once when it arrives twice" do
      msg = message(tg, text: "hi", native_id: "9")
      # The second call stands in for an overlapping container or a gateway redelivery.
      bridge.call(context(msg))
      bridge.call(context(msg))
      expect(adapter.delivered.map(&:first)).to eq(["dc"])
    end

    it "fans out to every target exactly once across a redelivery" do
      third = endpoint("irc")
      wide = described_class.new(
        topology: topology(room("r", tg, dc, third)),
        adapters: Hash.new(adapter), storage: storage, loop_guard: loop_guard,
        logger: Rubotty::Log.null, ttl: 3600
      )
      msg = message(tg, text: "hi", native_id: "9")
      wide.call(context(msg))
      wide.call(context(msg))
      expect(adapter.delivered.map(&:first)).to contain_exactly("dc", "irc")
    end

    it "delivers only once when two instances relay the same message at once" do
      msg = message(tg, text: "hi", native_id: "77")
      gate = Queue.new
      threads = Array.new(8) { Thread.new { gate.pop; bridge.call(context(msg)) } }
      8.times { gate << :go }
      threads.each(&:join)
      expect(adapter.delivered.count { |(id, _)| id == "dc" }).to eq(1)
    end

    it "propagates an edit once when the same edit arrives twice" do
      bridge.call(context(message(tg, text: "hi", native_id: "5")))
      edit = message(tg, text: "fixed", native_id: "5", kind: :edit)
      bridge.call(context(edit))
      bridge.call(context(edit))
      expect(adapter.edited.size).to eq(1)
    end

    it "still propagates a second, genuinely different edit of one message" do
      bridge.call(context(message(tg, text: "hi", native_id: "5")))
      bridge.call(context(message(tg, text: "fixed", native_id: "5", kind: :edit)))
      bridge.call(context(message(tg, text: "final", native_id: "5", kind: :edit)))
      expect(adapter.edited.size).to eq(2)
    end

    # The claim key is a digest of the text, so a revert reuses an earlier
    # edit's own key. Without releasing that earlier claim as each new edit
    # wins its own, the revert would find it still held for the full
    # relay_claim_ttl and silently drop instead of propagating (#1550).
    it "still propagates an edit that reverts a message back to its earlier text" do
      bridge.call(context(message(tg, text: "hi", native_id: "5")))
      bridge.call(context(message(tg, text: "A", native_id: "5", kind: :edit)))
      bridge.call(context(message(tg, text: "B", native_id: "5", kind: :edit)))
      bridge.call(context(message(tg, text: "A", native_id: "5", kind: :edit)))
      expect(adapter.edited.map { |(_, _, msg)| msg.body.text }).to eq(%w[A B A])
    end

    it "propagates a delete once when it arrives twice" do
      bridge.call(context(message(tg, text: "hi", native_id: "5")))
      del = message(tg, text: "", native_id: "5", kind: :delete)
      bridge.call(context(del))
      bridge.call(context(del))
      expect(adapter.deleted).to eq([%w[dc d1]])
    end
  end

  # A hub message naming a room by its short code targets that room's endpoints instead of
  # the default room's, leaving ordinary routing untouched.
  describe "hub_target_room_id override (#231)" do
    # Real hub-mode shape: one hub-side endpoint per bridged room, all addressing the same
    # physical channel, and only the default room's receives.
    let(:irc_hub_default) { endpoint("irc-hub-default") }
    let(:irc_hub_travel) { endpoint("irc-hub-travel", receives: false) }
    let(:gaming_a) { endpoint("gaming-a") }
    let(:gaming_b) { endpoint("gaming-b") }
    let(:travel_a) { endpoint("travel-a") }

    subject(:hub_bridge) do
      described_class.new(
        topology: topology(room("default", tg, irc_hub_default), room("gaming", gaming_a, gaming_b),
                           room("travel", travel_a, irc_hub_travel)),
        adapters: Hash.new(adapter), storage: storage, loop_guard: loop_guard,
        logger: Rubotty::Log.null, ttl: 3600
      )
    end

    it "targets the named room's endpoints, not the origin's own default room" do
      msg = message(irc_hub_default, text: "hello", hub_target_room_id: "gaming")
      outcome = hub_bridge.call(context(msg))
      expect(outcome.value.map(&:endpoint_id)).to contain_exactly("gaming-a", "gaming-b")
    end

    it "leaves ordinary (no code) routing exactly as it was" do
      msg = message(irc_hub_default, text: "hello")
      outcome = hub_bridge.call(context(msg))
      expect(outcome.value.map(&:endpoint_id)).to eq(["tg"])
    end

    it "falls back to ordinary routing for an id that no longer resolves to a room" do
      msg = message(irc_hub_default, text: "hello", hub_target_room_id: "no-such-room")
      outcome = hub_bridge.call(context(msg))
      expect(outcome.value.map(&:endpoint_id)).to eq(["tg"])
    end

    it "resolves via the id of an endpoint the room contains, not only a literal room id" do
      # A real hub adapter knows its own endpoint ids, so membership of the room has to be
      # enough to resolve it even where Topology#rooms_for would not return that room.
      msg = message(
        irc_hub_default, text: "hello", hub_target_room_id: irc_hub_travel.id,
        hub_exclude_endpoint_ids: [irc_hub_travel.id]
      )
      outcome = hub_bridge.call(context(msg))
      expect(outcome.value.map(&:endpoint_id)).to eq(["travel-a"])
    end

    # Core::Room#id is unique only within a community, so resolving against the global
    # topology could fan a message addressed to "gaming" into a stranger's room. The
    # rooms carry the community themselves now, so the double answers only its id.
    describe "a room key both communities use (#1788)" do
      let(:own_gaming_a) { endpoint("own-gaming-a", community_id: 1) }
      let(:other_gaming_a) { endpoint("other-gaming-a", community_id: 2) }
      let(:own_gaming) { room("gaming", own_gaming_a, community_id: 1) }
      let(:other_gaming) { room("gaming", other_gaming_a, community_id: 2) }
      let(:default_room) { room("default", tg, irc_hub_default, community_id: 1) }

      let(:colliding_bridge) do
        described_class.new(
          topology: topology(default_room, own_gaming, other_gaming),
          adapters: Hash.new(adapter), storage: storage, loop_guard: loop_guard,
          logger: Rubotty::Log.null, ttl: 3600
        )
      end

      def hub_outcome(community_id, target: "gaming")
        msg = message(irc_hub_default, text: "hello", hub_target_room_id: target)
        colliding_bridge.call(
          Rubotty::Features::Context.new(message: msg, community: double("community", id: community_id))
        )
      end

      it "resolves a same-named room within the message's own community, not any matching one globally" do
        expect(hub_outcome(1).value.map(&:endpoint_id)).to eq(["own-gaming-a"])
      end

      it "answers the other community its own room for the identical key" do
        expect(hub_outcome(2).value.map(&:endpoint_id)).to eq(["other-gaming-a"])
      end

      # A room resolves by a member endpoint id as well as by key, and that
      # search reads the same narrowed pool.
      it "will not resolve a stranger's room by one of its endpoint ids either" do
        expect(hub_outcome(1, target: "other-gaming-a").value.map(&:endpoint_id)).to eq(["tg"])
      end
    end

    it "never echoes back into the same physical channel through that room's own hub endpoint" do
      # irc_hub_travel shares the physical channel the message arrived on, so without the
      # exclusion the copy lands back in front of the sender.
      msg = message(
        irc_hub_default, text: "hello", hub_target_room_id: "travel",
        hub_exclude_endpoint_ids: [irc_hub_travel.id]
      )
      outcome = hub_bridge.call(context(msg))
      expect(outcome.value.map(&:endpoint_id)).to eq(["travel-a"])
    end
  end

  # A message living inside a thread degrades to a short text notice on a target platform
  # that cannot represent the thread, and stays off until an operator opts a scope in.
  describe "thread degradation notice (#40, #593)" do
    let(:thread) { Rubotty::Core::ThreadRef.new(native_id: "77", name: "release chat") }
    let(:reply) do
      message(tg, text: "yes", native_id: "9", reply_to: ref("tg", "5"), thread: thread)
    end

    # An adapter whose platform can represent a thread, to prove the notice is withheld there.
    let(:threading_adapter) do
      Class.new(Fakes::RecordingAdapter) do
        def capabilities
          @capabilities ||= Rubotty::Adapters::Capabilities.new(
            edits: true, deletes: true, replies: true, threads: true
          )
        end
      end.new(own_id: "bot-1")
    end

    def enabled_context(message)
      Rubotty::Features::Context.new(message: message, config: { thread_reply_notices: true })
    end

    def delivered_notice(the_adapter = adapter)
      the_adapter.delivered.last.last.thread_notice
    end

    it "adds the notice when opted in and the target cannot represent the thread" do
      bridge.call(enabled_context(reply))
      expect(delivered_notice).to eq('replied inside the thread "release chat"')
    end

    it "stays dormant by default, adding no notice" do
      bridge.call(context(reply))
      expect(delivered_notice).to be_nil
    end

    it "adds no notice when the target platform can represent the thread" do
      threading_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(threading_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      threading_bridge.call(enabled_context(reply))
      expect(delivered_notice(threading_adapter)).to be_nil
    end

    it "adds no notice for a reply that is not inside a thread" do
      flat = message(tg, text: "yes", native_id: "9", reply_to: ref("tg", "5"))
      bridge.call(enabled_context(flat))
      expect(delivered_notice).to be_nil
    end

    it "adds the notice for an ordinary message typed into a thread, with no reply pointer" do
      non_reply = message(tg, text: "yes", native_id: "9", thread: thread)
      bridge.call(enabled_context(non_reply))
      expect(delivered_notice).to eq('replied inside the thread "release chat"')
    end

    # The live case: a thread started on Discord, an ordinary message posted in it, and a
    # target that cannot hold a thread at all.
    it "names the thread and whoever started it, tagged with the origin platform" do
      discord_adapter = Class.new(Fakes::RecordingAdapter) do
        def origin_label(_endpoint = nil) = "discord"
      end.new(own_id: "bot-1")
      discord_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(discord_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      started = Rubotty::Core::ThreadRef.new(native_id: "77", name: "Test.", creator: "owner_handle")

      discord_bridge.call(enabled_context(message(tg, text: "Thread test.", native_id: "9", thread: started)))

      expect(discord_adapter.capabilities_for(dc).threads?).to be(false)
      expect(delivered_notice(discord_adapter))
        .to eq('(Reply inside thread "Test." created by owner_handle@discord.)')
    end

    it "falls back to the shorter line when the platform never said who started the thread" do
      anonymous = message(tg, text: "yes", native_id: "9", thread: thread)
      bridge.call(enabled_context(anonymous))
      expect(delivered_notice).not_to include("created by")
    end

    it "says 'a thread' when the source platform gave no thread name" do
      unnamed = message(tg, text: "yes", native_id: "9", reply_to: ref("tg", "5"),
                            thread: Rubotty::Core::ThreadRef.new(native_id: "77"))
      bridge.call(enabled_context(unnamed))
      expect(delivered_notice).to eq("replied inside a thread")
    end

    it "says 'a thread' for a nameless thread even when its starter is known" do
      nameless = message(tg, text: "yes", native_id: "9",
                             thread: Rubotty::Core::ThreadRef.new(native_id: "77", creator: "owner_handle"))
      bridge.call(enabled_context(nameless))
      expect(delivered_notice).to eq("replied inside a thread")
    end
  end

  # A reaction placed on a platform that cannot hold one used to vanish outright: relayed
  # nowhere, with nothing to tell anyone it happened. reaction_notices gives an operator a
  # text fallback, on by default alongside the native emoji: nobody loses a reaction's
  # meaning just because their platform cannot hold it.
  describe "reaction status-line notices (#488)" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }
    let(:reacting_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

    # A reaction can only be mirrored onto a message actually relayed.
    before { storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r") }

    # A distinct username per actor and no separate display name, so the rendered
    # label is the plain "handle@platform" shape with no bracketed alias.
    def reactor(id) = author(native_id: id, username: id, first_name: nil)

    def react(kind, reaction, actor, config: {})
      bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: kind, ref: ref("tg", "5"), origin: tg, author: reactor(actor), reaction: reaction
          ),
          config: config
        )
      )
    end

    def delivered_notices(the_adapter = adapter, endpoint_id: "dc")
      the_adapter.delivered.select { |(id, _)| id == endpoint_id }.map(&:last)
    end

    def notices(the_adapter = adapter)
      delivered_notices(the_adapter).map { |msg| msg.body.text }
    end

    it "posts the notice by default, since a target that cannot hold the emoji would " \
       "otherwise lose the reaction entirely" do
      react(:reaction_add, thumbs, "alice")
      expect(notices).to eq(["alice@fake reacted 👍"])
    end

    it "stays dormant under explicit native mode: no emoji (the target cannot hold one) and no notice" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :native })
      expect(notices).to be_empty
    end

    it "posts the status line under notice mode on a target with no reaction support" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :notice })
      expect(notices).to eq(["alice@fake reacted 👍"])
    end

    it "places the real emoji and adds no notice under explicit native mode" do
      reacting_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(reacting_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      reacting_bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "5"), origin: tg, author: reactor("alice"), reaction: thumbs
          ),
          config: { reaction_notices: :native }
        )
      )
      expect(reacting_adapter.syncs.size).to eq(1)
      expect(notices(reacting_adapter)).to be_empty
    end

    it "defaults to both, so an unconfigured scope still posts the notice a native-only target would miss" do
      reacting_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(reacting_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      reacting_bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "5"), origin: tg, author: reactor("alice"), reaction: thumbs
          )
        )
      )
      expect(reacting_adapter.syncs.size).to eq(1)
      expect(notices(reacting_adapter)).to eq(["alice@fake reacted 👍"])
    end

    it "places the real emoji AND posts the notice on a capable target under both" do
      reacting_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(reacting_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      reacting_bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "5"), origin: tg, author: reactor("alice"), reaction: thumbs
          ),
          config: { reaction_notices: :both }
        )
      )
      expect(reacting_adapter.syncs.size).to eq(1)
      expect(notices(reacting_adapter)).to eq(["alice@fake reacted 👍"])
    end

    it "gets nothing at all for a target that has reaction relaying turned off, whatever the mode" do
      quiet = endpoint("dc", relay: { reactions: false })
      quiet_bridge = described_class.new(
        topology: topology(room("r", tg, quiet)), adapters: Hash.new(adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      quiet_bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "5"), origin: tg, author: reactor("alice"), reaction: thumbs
          ),
          config: { reaction_notices: :both }
        )
      )
      expect(adapter.delivered).to be_empty
    end

    # A line reading "alice un-reacted" is noise nobody asked for; the add's own line
    # is taken back instead, which is what a reader of the channel wants.
    it "never posts a notice for a reaction being removed, even under notice or both" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :notice })
      react(:reaction_remove, thumbs, "alice", config: { reaction_notices: :notice })
      expect(notices.size).to eq(1)
    end

    # Watched live in the same room within a minute: the emoji came off and the sentence
    # announcing it stayed put, and swapping one emoji for another said nothing at all,
    # because the claim the first add took was never handed back.
    describe "a reaction taken off again" do
      # Its own message, so the line posted about it cannot be mistaken for the copy of the
      # message being reacted to. The fake numbers what it delivers, so the line is d1.
      before { storage.record(source: ref("tg", "7"), destination: ref("dc", "copy-7"), room_id: "r") }

      def react_again(kind, reaction, actor)
        bridge.call(
          Rubotty::Features::Context.new(
            message: Rubotty::Core::Message.new(
              kind: kind, ref: ref("tg", "7"), origin: tg, author: reactor(actor), reaction: reaction
            ),
            config: { reaction_notices: :notice }
          )
        )
      end

      it "takes the line back once the emoji it announced is gone" do
        react_again(:reaction_add, thumbs, "alice")
        react_again(:reaction_remove, thumbs, "alice")
        expect(adapter.deleted).to eq([["dc", "d1"]])
      end

      it "hears the same person again when they take one emoji off and put another on" do
        react_again(:reaction_add, thumbs, "alice")
        react_again(:reaction_remove, thumbs, "alice")
        react_again(:reaction_add, party, "alice")
        expect(notices).to eq(["alice@fake reacted 👍", "alice@fake reacted 🎉"])
      end

      it "narrows the line down to what they still hold rather than deleting it" do
        react_again(:reaction_add, thumbs, "alice")
        react_again(:reaction_add, party, "alice")
        react_again(:reaction_remove, thumbs, "alice")
        expect(adapter.edited.map { |(_, _, msg)| msg.body.text }).to eq(["alice@fake reacted 🎉"])
        expect(adapter.deleted).to be_empty
      end

      # The anti-burst rule survives: the claim only goes back once they hold nothing at all.
      it "still charges one line to somebody who never lets go of the message" do
        react_again(:reaction_add, thumbs, "alice")
        react_again(:reaction_add, party, "alice")
        react_again(:reaction_remove, thumbs, "alice")
        react_again(:reaction_add, thumbs, "alice")
        expect(notices).to eq(["alice@fake reacted 👍"])
      end

      it "leaves another person's line alone when one of them un-reacts" do
        react_again(:reaction_add, thumbs, "alice")
        react_again(:reaction_add, party, "bob")
        react_again(:reaction_remove, thumbs, "alice")
        expect(adapter.deleted).to eq([["dc", "d1"]])
        expect(notices).to eq(["alice@fake reacted 👍", "bob@fake reacted 🎉"])
      end
    end

    # Noise control is per person per message. The old rule asked whether anybody had reacted
    # yet, which silenced everyone after the first reacter and read from the other platform
    # as though reaction relaying had stopped working.
    it "posts one notice per person, so a second reacter is still heard" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :notice })
      react(:reaction_add, party, "bob", config: { reaction_notices: :notice })
      expect(notices).to eq(["alice@fake reacted 👍", "bob@fake reacted 🎉"])
    end

    # The aggregate set is unchanged when the second person picks the same emoji, which is
    # what the native mirror keys off, so the line has to be decided separately from it.
    it "hears the second person even when they pick an emoji somebody already placed" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :notice })
      react(:reaction_add, thumbs, "bob", config: { reaction_notices: :notice })
      expect(notices).to eq(["alice@fake reacted 👍", "bob@fake reacted 👍"])
    end

    it "leaves the emoji alone when the second person changes nothing about the set" do
      reacting_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(reacting_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      %w[alice bob].each do |name|
        reacting_bridge.call(
          Rubotty::Features::Context.new(
            message: Rubotty::Core::Message.new(
              kind: :reaction_add, ref: ref("tg", "5"), origin: tg, author: reactor(name),
              reaction: thumbs
            ),
            config: { reaction_notices: :both }
          )
        )
      end
      expect(reacting_adapter.syncs.size).to eq(1)
      expect(notices(reacting_adapter).size).to eq(2)
    end

    it "posts one notice however many emoji one person piles onto the same message" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :notice })
      react(:reaction_add, party, "alice", config: { reaction_notices: :notice })
      expect(notices).to eq(["alice@fake reacted 👍"])
    end

    it "counts a person separately on each message they react to" do
      storage.record(source: ref("tg", "6"), destination: ref("dc", "d2"), room_id: "r")
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :notice })
      bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "6"), origin: tg, author: reactor("alice"),
            reaction: thumbs
          ),
          config: { reaction_notices: :notice }
        )
      )
      expect(notices.size).to eq(2)
    end

    # A loose "somebody reacted" line in a busy channel says nothing about which message
    # earned it, so the line replies to the target's own copy of that message.
    it "replies to the target's copy of the message that was reacted to" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :notice })
      expect(delivered_notices.last.reply_to).to eq(ref("dc", "d1"))
    end

    # A message relayed before the map entry expired still sits in the channel, so the line is
    # worth more than the reply pointer it cannot resolve.
    it "still posts the line, loose, when no copy of the reacted-to message is known" do
      unmapped = Rubotty::Core::Message.new(
        kind: :reaction_add, ref: ref("tg", "99"), origin: tg, author: reactor("alice"),
        reaction: thumbs
      )
      bridge.call(Rubotty::Features::Context.new(message: unmapped, config: { reaction_notices: :notice }))
      expect(notices).to eq(["alice@fake reacted 👍"])
      expect(delivered_notices.last.reply_to).to be_nil
    end

    # The exact sequence watched live in SAMPLE: a reaction from Telegram put a line on Discord,
    # and reacting back from Discord put nothing on Telegram at all, which read as one
    # direction being dead. Both lines land now, each replying to its own side's copy.
    it "carries a reaction each way between two platforms, each line replying to its own copy" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :both })
      bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("dc", "d1"), origin: dc, author: reactor("bob"),
            reaction: party
          ),
          config: { reaction_notices: :both }
        )
      )
      onto_discord = delivered_notices(adapter, endpoint_id: "dc")
      onto_telegram = delivered_notices(adapter, endpoint_id: "tg")
      expect(onto_discord.map { |msg| msg.body.text }).to eq(["alice@fake reacted 👍"])
      expect(onto_discord.last.reply_to).to eq(ref("dc", "d1"))
      expect(onto_telegram.map { |msg| msg.body.text }).to eq(["bob@fake reacted 🎉"])
      expect(onto_telegram.last.reply_to).to eq(ref("tg", "5"))
    end

    it "tolerates a string form of the mode, the way other bridge config keys do" do
      react(:reaction_add, thumbs, "alice", config: { "reaction_notices" => "notice" })
      expect(notices).to eq(["alice@fake reacted 👍"])
    end

    it "falls back to both for an unrecognised mode rather than raising" do
      react(:reaction_add, thumbs, "alice", config: { reaction_notices: :bogus })
      expect(notices).to eq(["alice@fake reacted 👍"])
    end

    # A count-only update names nobody, so there is no handle to put in the line.
    # Silence would be the worse answer: the reaction did happen.
    describe "a reaction the platform attributes to nobody" do
      def counted(*reactions, config: {})
        bridge.call(
          Rubotty::Features::Context.new(
            message: Rubotty::Core::Message.new(
              kind: :reaction_sync, ref: ref("tg", "5"), origin: tg, reaction_set: reactions
            ),
            config: config
          )
        )
      end

      it "posts a line naming the platform and the emoji, and no handle" do
        counted(thumbs, config: { reaction_notices: :notice })
        expect(notices).to eq(["somebody on fake reacted 👍"])
      end

      it "gives each newly counted emoji its own line" do
        counted(thumbs, party, config: { reaction_notices: :notice })
        expect(notices).to eq(["somebody on fake reacted 👍", "somebody on fake reacted 🎉"])
      end

      # The count is a snapshot that arrives again and again, so a repeat of an
      # emoji already announced must not earn a second line.
      it "says nothing twice for an emoji already announced" do
        counted(thumbs, config: { reaction_notices: :notice })
        counted(thumbs, party, config: { reaction_notices: :notice })
        expect(notices).to eq(["somebody on fake reacted 👍", "somebody on fake reacted 🎉"])
      end

      it "replies to the target's copy of the message that was reacted to" do
        counted(thumbs, config: { reaction_notices: :notice })
        expect(delivered_notices.last.reply_to).to eq(ref("dc", "d1"))
      end

      # The same release the attributed path was missing: the emoji is the holder here, so
      # the line goes when the count stops carrying it and the claim goes with it.
      it "takes the line back for an emoji the count no longer carries" do
        counted(thumbs, config: { reaction_notices: :notice })
        counted(config: { reaction_notices: :notice })
        expect(adapter.deleted).to eq([["dc", "d1"]])
      end

      it "announces the emoji again when a later count carries it once more" do
        counted(thumbs, config: { reaction_notices: :notice })
        counted(config: { reaction_notices: :notice })
        counted(thumbs, config: { reaction_notices: :notice })
        expect(notices).to eq(["somebody on fake reacted 👍", "somebody on fake reacted 👍"])
      end

      it "posts the notice by default, exactly as an attributed one does" do
        counted(thumbs)
        expect(notices).to eq(["somebody on fake reacted 👍"])
      end

      it "stays quiet under explicit native mode, exactly as an attributed one does" do
        counted(thumbs, config: { reaction_notices: :native })
        expect(notices).to be_empty
      end
    end

    # A bulk clear only ever takes emoji away, so it earns no line under any
    # mode: "somebody un-reacted" reads exactly as unwanted as the per-actor
    # remove already exempted above.
    describe "a bulk clear naming no author (#671)" do
      def cleared(reaction: nil, config: {})
        reacting_bridge.call(
          Rubotty::Features::Context.new(
            message: Rubotty::Core::Message.new(
              kind: :reaction_clear, ref: ref("tg", "5"), origin: tg, reaction: reaction
            ),
            config: config
          )
        )
      end

      def reacting_bridge
        described_class.new(
          topology: topology(room("r", tg, dc)), adapters: Hash.new(reacting_adapter),
          storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
        )
      end

      it "takes the whole aggregate down for one emoji, named actors included" do
        react(:reaction_add, thumbs, "alice")
        react(:reaction_add, party, "alice")

        cleared(reaction: thumbs)

        expect(reacting_adapter.syncs.last[:desired].map(&:emoji)).to eq(["🎉"])
      end

      it "places no notice even under both, since a clear only ever removes" do
        react(:reaction_add, thumbs, "alice")

        cleared(reaction: thumbs, config: { reaction_notices: :both })

        expect(notices(reacting_adapter)).to be_empty
      end
    end

    # XMPP (edits: false, deletes: true) hits exactly this branch: amend_notice
    # deletes the whole line whenever it cannot edit it down, whether or not the
    # actor still holds a reaction. The claim has to go back with it either way,
    # or a later add from the same actor finds it already held and posts nothing (#1549).
    describe "a delete-only target that cannot narrow the line down" do
      let(:delete_only_adapter) do
        Class.new(Fakes::RecordingAdapter) do
          def capabilities
            @capabilities ||= Rubotty::Adapters::Capabilities.new(edits: false, deletes: true, replies: true)
          end
        end.new(own_id: "bot-1")
      end

      def delete_only_bridge
        described_class.new(
          topology: topology(room("r", tg, dc)), adapters: Hash.new(delete_only_adapter),
          storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
        )
      end

      def react_delete_only(kind, reaction, actor)
        delete_only_bridge.call(
          Rubotty::Features::Context.new(
            message: Rubotty::Core::Message.new(
              kind: kind, ref: ref("tg", "5"), origin: tg, author: reactor(actor), reaction: reaction
            ),
            config: { reaction_notices: :notice }
          )
        )
      end

      it "deletes the whole line and releases the claim even though a reaction remains" do
        react_delete_only(:reaction_add, thumbs, "alice")
        react_delete_only(:reaction_add, party, "alice")
        react_delete_only(:reaction_remove, thumbs, "alice")

        expect(delete_only_adapter.deleted).to eq([["dc", "d1"]])

        # If the claim from the first add were still held, this second add would
        # find claim_event already false and post nothing at all.
        react_delete_only(:reaction_add, thumbs, "alice")
        expect(notices(delete_only_adapter)).to eq(["alice@fake reacted 👍", "alice@fake reacted 👍"])
      end
    end
  end

  # A custom emoji's id names an asset on one platform's own library, so handing it to the
  # target's native sync unfiltered used to let the adapter swallow the failure while
  # Bridge marked the mirror done anyway. custom_reactions? now actually gates the attempt.
  describe "a custom emoji reaction crossing to a different platform (#757)" do
    let(:parrot) { Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot") }
    let(:telegram_origin) { endpoint("tg", adapter: :telegram) }
    let(:discord_target) { endpoint("dc", adapter: :discord) }
    let(:reacting_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
    let(:logs) { StringIO.new }

    def foreign_bridge
      described_class.new(
        topology: topology(room("r", telegram_origin, discord_target)),
        adapters: Hash.new(reacting_adapter), storage: storage, loop_guard: loop_guard,
        logger: Rubotty::Log.build(level: "debug", io: logs), ttl: 3600
      )
    end

    before { storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r") }

    def react(config: {})
      foreign_bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg", "5"), origin: telegram_origin,
            author: author(native_id: "alice", username: "alice", first_name: nil),
            reaction: parrot
          ),
          config: config
        )
      )
    end

    it "never hands the foreign custom emoji to the target's native sync" do
      react
      expect(reacting_adapter.syncs).to be_empty
    end

    it "logs why, instead of nothing anywhere saying so" do
      react
      expect(logs.string).to include(":parrot:").and include("cannot cross to dc")
    end

    it "still shows something when an operator has asked for reaction notices" do
      react(config: { reaction_notices: :notice })
      notice = reacting_adapter.delivered_to("dc").last
      # origin_platform_label reads the adapter INSTANCE's own name, which the test
      # double fixes at "fake" regardless of which endpoint.adapter_name routed here.
      expect(notice.body.text).to eq("alice@fake reacted :parrot:")
    end

    it "keeps placing a custom emoji natively when it stays on its own platform" do
      same_platform_bridge = described_class.new(
        topology: topology(room("r", endpoint("tg1", adapter: :telegram), endpoint("tg2", adapter: :telegram))),
        adapters: Hash.new(reacting_adapter), storage: storage, loop_guard: loop_guard,
        logger: Rubotty::Log.null, ttl: 3600
      )
      storage.record(source: ref("tg1", "5"), destination: ref("tg2", "d1"), room_id: "r")

      same_platform_bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(
            kind: :reaction_add, ref: ref("tg1", "5"), origin: endpoint("tg1", adapter: :telegram),
            author: author(native_id: "alice"), reaction: parrot
          )
        )
      )
      expect(reacting_adapter.syncs.last[:desired]).to eq([parrot])
    end
  end

  # Reactions already degrade to a text-notice fallback on a target that cannot hold one
  # natively (see reaction_notices above). An edit or a delete had nothing like it: the
  # original just stayed exactly as it was, with nobody told why.
  describe "edit and delete fallback notices for a target with no native support (#759)" do
    let(:non_editing_adapter) do
      Class.new(Fakes::RecordingAdapter) do
        def capabilities
          @capabilities ||= Rubotty::Adapters::Capabilities.new(edits: false, deletes: false, replies: true)
        end
      end.new(own_id: "bot-1")
    end

    def notice_bridge
      described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(non_editing_adapter),
        storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
    end

    def actor(id) = author(native_id: id, username: id, first_name: nil)

    before { storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r") }

    describe "an edit crossing to a target that cannot edit natively" do
      def edit(config: {})
        notice_bridge.call(
          Rubotty::Features::Context.new(
            message: Rubotty::Core::Message.new(
              kind: :edit, ref: ref("tg", "5"), origin: tg, author: actor("alice"),
              body: Rubotty::Core::RichText.plain("fixed")
            ),
            config: config
          )
        )
      end

      it "stays silent by default, unlike the reaction fallback which now defaults on" do
        edit
        expect(non_editing_adapter.delivered).to be_empty
      end

      it "posts a fallback line naming who edited, replying to the target's own copy" do
        edit(config: { edit_notices: true })
        notice = non_editing_adapter.delivered_to("dc").last
        expect(notice.body.text).to eq("alice@fake edited their message")
        expect(notice.reply_to).to eq(ref("dc", "d1"))
      end
    end

    describe "a delete crossing to a target that cannot delete natively" do
      def delete_msg(config: {})
        notice_bridge.call(
          Rubotty::Features::Context.new(
            message: Rubotty::Core::Message.new(
              kind: :delete, ref: ref("tg", "5"), origin: tg, author: actor("alice")
            ),
            config: config
          )
        )
      end

      it "stays silent by default, leaving the original standing with no notice" do
        delete_msg
        expect(non_editing_adapter.delivered).to be_empty
      end

      it "posts a fallback line naming who deleted, replying to the target's own copy" do
        delete_msg(config: { delete_notices: true })
        notice = non_editing_adapter.delivered_to("dc").last
        expect(notice.body.text).to eq("alice@fake deleted their message")
        expect(notice.reply_to).to eq(ref("dc", "d1"))
      end
    end
  end
  # A paced backfill relay hands a message over and returns, so the sends happen later on
  # the room's own worker. These reports are how the sweep finds out what a copy actually
  # came to, and what rate a platform will take.
  describe "reporting to a paced relay" do
    let(:elapsed) { [0.0] }
    let(:outcomes) do
      Rubotty::Core::RelayOutcomes.new(logger: Rubotty::Log.null, monotonic: -> { elapsed.first })
    end
    let(:attempts) { 3 }

    subject(:bridge) do
      described_class.new(
        topology: topology(room("r", tg, dc)),
        adapters: Hash.new(adapter),
        storage: storage,
        loop_guard: loop_guard,
        logger: Rubotty::Log.null,
        ttl: 3600,
        retry_policy: Rubotty::Core::RetryPolicy.new(attempts: attempts, sleeper: ->(_seconds) {}),
        relay_outcomes: outcomes
      )
    end

    it "reports what a platform asked for on the FIRST refusal, before any retry waits it out" do
      outcomes.watch(ref("tg", "5"))
      adapter.fail_next(Rubotty::RateLimitedError.new("Too Many Requests", adapter: :fake, retry_after: 27))

      bridge.call(context(message(tg, text: "hi", native_id: "5")))

      expect(outcomes.rate_limit_for("dc", since: 0.0)).to eq(27.0)
    end

    it "reports the copy as delivered when a retry finally lands it" do
      outcomes.watch(ref("tg", "5"))
      adapter.fail_next(Rubotty::RateLimitedError.new("Too Many Requests", adapter: :fake, retry_after: 1))

      bridge.call(context(message(tg, text: "hi", native_id: "5")))

      expect(outcomes.reconcile([ref("tg", "5")]).lost).to eq(0)
    end

    context "when a platform refuses the copy on every attempt there is" do
      let(:attempts) { 2 }

      before do
        allow(adapter).to receive(:deliver)
          .and_raise(Rubotty::RateLimitedError.new("Too Many Requests", adapter: :fake, retry_after: 27))
      end

      it "reports it, so the sweep takes it out of its count instead of reporting a handover" do
        outcomes.watch(ref("tg", "5"))

        bridge.call(context(message(tg, text: "hi", native_id: "5")))

        result = outcomes.reconcile([ref("tg", "5")])
        expect(result.lost).to eq(1)
        expect(result.losses.first).to include("tg:5 to dc", "Too Many Requests")
      end
    end

    it "records nothing at all for live traffic no sweep asked it to follow" do
      bridge.call(context(message(tg, text: "hi", native_id: "5")))

      expect(outcomes.reconcile([ref("tg", "5")]).lost).to eq(0)
      expect(outcomes.rate_limit_for("dc", since: 0.0)).to be_nil
    end

    # The mirror of the line above, and the reason EndpointHealth exists: what
    # a sweep never asked about still has to be counted somewhere, or a
    # platform refusing every post leaves no trace at all.
    describe "the delivery health every live send is counted in" do
      let(:health) { Rubotty::Core::EndpointHealth.new }

      subject(:bridge) do
        described_class.new(
          topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
          loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600,
          retry_policy: Rubotty::Core::RetryPolicy.new(attempts: 2, sleeper: ->(_seconds) {}),
          endpoint_health: health
        )
      end

      it "counts a live delivery no sweep is watching" do
        bridge.call(context(message(tg, text: "hi", native_id: "5")))

        row = health.report.find { |entry| entry["endpoint_id"] == "dc" }
        expect(row["sent"]).to eq(1)
        expect(health.failures("dc")).to eq(0)
      end

      it "counts a destination that spent every attempt, with the error that stopped it" do
        allow(adapter).to receive(:deliver)
          .and_raise(Rubotty::RateLimitedError.new("Too Many Requests", adapter: :fake, retry_after: 27))

        bridge.call(context(message(tg, text: "hi", native_id: "5")))

        expect(health.failures("dc")).to eq(1)
        expect(health.report.first["last_error"]).to include("Too Many Requests")
      end

      it "times the whole retried delivery rather than one attempt of it" do
        bridge.call(context(message(tg, text: "hi", native_id: "5")))

        row = health.report.find { |entry| entry["endpoint_id"] == "dc" }
        expect(row["latency"].sum { |bucket| bucket["count"] }).to eq(1)
      end
    end

    # A nil receipt used to be swallowed exactly like NOT_APPLICABLE below, so
    # an upload that silently produced nothing left no trace anywhere an
    # operator could find it.
    context "when the adapter attempted the send and came back with no receipt at all" do
      before { allow(adapter).to receive(:deliver).and_return(nil) }

      it "reports it as abandoned rather than counting the copy as delivered" do
        outcomes.watch(ref("tg", "5"))

        bridge.call(context(message(tg, text: "hi", native_id: "5")))

        result = outcomes.reconcile([ref("tg", "5")])
        expect(result.lost).to eq(1)
        expect(result.losses.first).to include("tg:5 to dc")
      end

      it "logs the miss even for live traffic no sweep is watching" do
        lines = []
        logger = instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil)
        allow(logger).to receive(:error) { |&block| lines << block.call }
        logging_bridge = described_class.new(
          topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
          loop_guard: loop_guard, logger: logger, ttl: 3600,
          retry_policy: Rubotty::Core::RetryPolicy.new(attempts: attempts, sleeper: ->(_seconds) {})
        )

        logging_bridge.call(context(message(tg, text: "hi", native_id: "5")))

        expect(lines.join("\n")).to include("dc")
      end
    end

    # Adapters::Guest::Adapter#deliver returns this routinely, whenever no
    # guest is watching the room, and that is not a loss: it must never be
    # mistaken for the abandoned case just above.
    it "does not report or log when the adapter says the delivery does not apply" do
      outcomes.watch(ref("tg", "5"))
      allow(adapter).to receive(:deliver).and_return(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)

      bridge.call(context(message(tg, text: "hi", native_id: "5")))

      expect(outcomes.reconcile([ref("tg", "5")]).lost).to eq(0)
    end
  end

  # A mute was only ever a request to the platform, so nothing stopped the
  # bridge relaying a muted member everywhere else regardless.
  describe "an actively muted author" do
    let(:db) do
      db = Sequel.sqlite
      Rubotty::ControlPlane::Migrator.run(db)
      db
    end
    let(:warnings_service) do
      Rubotty::Core::Warnings::Service.new(
        store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
        scheduler: Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s", logger: Rubotty::Log.null
        ),
        topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
        logger: Rubotty::Log.null
      )
    end
    let(:muted_bridge) do
      described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
        loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, warnings: warnings_service
      )
    end
    let(:community) do
      Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "sample", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg, dc)]), channels: [],
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: []
      )
    end
    let(:offender) { author(native_id: "u9", username: "troll") }

    def muted_context(message)
      Rubotty::Features::Context.new(message: message, community: community)
    end

    before do
      warnings_service.sanction(community: community, subject: offender, origin: tg, action: :mute, duration: 3600)
    end

    it "drops the message silently, without relaying it to the other endpoint" do
      outcome = muted_bridge.call(muted_context(message(tg, text: "hi", author: offender)))
      expect(adapter.delivered).to be_empty
      expect(outcome).to be_halt
    end

    it "deletes the message at its origin" do
      muted_bridge.call(muted_context(message(tg, text: "hi", native_id: "5", author: offender)))
      expect(adapter.deleted).to include(%w[tg 5])
    end

    it "still relays an author who is not muted" do
      clean_author = author(native_id: "u1", username: "ada")
      muted_bridge.call(muted_context(message(tg, text: "hi", author: clean_author)))
      expect(adapter.delivered.map(&:first)).to eq(["dc"])
    end

    # Posted before the mute took effect, then edited after: the edit must not
    # smuggle the muted author's content through on a copy that already exists.
    it "drops an edit from the now-muted author instead of propagating it" do
      bridge.call(context(message(tg, text: "hi", native_id: "77", author: offender)))
      adapter.edited.clear

      outcome = muted_bridge.call(muted_context(message(tg, text: "fixed", native_id: "77",
                                                         author: offender, kind: :edit)))

      expect(adapter.edited).to be_empty
      expect(outcome).to be_halt
    end

    # The gate is checked after the relay claim precisely so this holds: two
    # instances racing the same message must not each delete it and DM twice.
    it "drops and DMs only once when the same message is seen twice, as if by two instances" do
      dm_adapter = Fakes::RecordingAdapter.new(own_id: "bot-1", admin_dm: true)
      dm_service = Rubotty::Core::Warnings::Service.new(
        store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
        scheduler: Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s", logger: Rubotty::Log.null
        ),
        topology: topology(room("r", tg, dc)), adapters: Hash.new(dm_adapter), storage: storage,
        logger: Rubotty::Log.null
      )
      dm_service.sanction(community: community, subject: offender, origin: tg, action: :mute, duration: 3600)
      dm_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(dm_adapter), storage: storage,
        loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, warnings: dm_service
      )
      dms_before_relay = dm_adapter.dms_sent.size # the mute itself already sent one

      msg = message(tg, text: "hi", native_id: "77", author: offender)
      2.times { dm_bridge.call(muted_context(msg)) }

      expect(dm_adapter.deleted.count { |(id, native)| id == "tg" && native == "77" }).to eq(1)
      expect(dm_adapter.dms_sent.size - dms_before_relay).to eq(1)
    end
  end

  # Every existing echo defence lives on the adapter and can all miss at
  # once, so this backstop does not try to recognise anything about the
  # message: it just refuses to keep posting to an endpoint once
  # bridge-authored traffic to it gets implausibly fast.
  describe "the post rate breaker" do
    let(:limit) { Rubotty::Core::LoopGuard::POST_RATE_LIMIT }

    it "stops posting to an endpoint once a burst crosses the ceiling, and logs it loudly" do
      lines = []
      logger = instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil)
      allow(logger).to receive(:error) { |&block| lines << block.call }
      breaking_bridge = described_class.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
        loop_guard: loop_guard, logger: logger, ttl: 3600
      )

      (limit + 5).times do |i|
        breaking_bridge.call(context(message(tg, text: "hi", native_id: "burst-#{i}", author: author(bot: true))))
      end

      expect(adapter.delivered_to("dc").size).to eq(limit)
      expect(lines.join("\n")).to include("dc")
    end
  end
end
