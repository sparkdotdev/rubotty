# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# Posting through the REST API and watching a room live, over the real
# pipeline. An API post is screened by the same moderation features that
# screen a member's message, with no shortcut to each endpoint. The bridge
# writes one buffer row per room at fan-out, and the stream route reads it back.
RSpec.describe "the REST API through the pipeline", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new }
  let(:messages) { Rubotty::ControlPlane::ApiMessages.new(models: models) }
  let(:buffer) { Rubotty::ControlPlane::LiveRoomFeed.new(models: models) }

  let(:key) do
    Rubotty::ControlPlane::ApiKeys.new(models: models)
                                 .issue(scope: "developer", community: community, label: "ops console").key_row
  end

  # A RecordingAdapter for every real (adapter, account) in the topology. Neither
  # synthetic endpoint needs one: nothing is delivered to the API endpoint (it
  # does not send) and no guest is live.
  def adapters(snapshot)
    snapshot.topology.endpoints
            .reject { |e| %i[guest api].include?(e.adapter_name) }
            .each_with_object({}) { |e, map| map[[e.adapter_name, e.account]] ||= Fakes::RecordingAdapter.new(account: e.account) }
  end

  def router(snapshot, adapter_map, live_feed: nil)
    Rubotty::Core::Router.new(
      topology: snapshot.topology, adapters: adapter_map, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, registry: registry,
      live_feed: live_feed
    )
  end

  # A real API adapter whose dispatcher is the router itself, driven by calling
  # #receive_pending directly so no thread is involved.
  def api_adapter(route)
    Rubotty::Adapters::Api::Adapter.new(
      dispatcher: ->(message) { route.handle(message) },
      messages: messages, models: models, registry: registry, logger: Rubotty::Log.null
    )
  end

  def post!(text)
    messages.enqueue(community: community, room: room, key: key, body: text)
  end

  describe "an API post reaches every platform bridged into the room" do
    it "fans out to every real endpoint, tagged as the credential that sent it" do
      snapshot = registry.current
      map = adapters(snapshot)
      post!("deploy finished at 14:02")
      api_adapter(router(snapshot, map)).receive_pending

      tg = map[[:telegram, "telegram"]].delivered_to("tg-general")
      dc = map[[:discord, "discord"]].delivered_to("dc-general")
      expect(tg.map { |m| m.body.text }).to eq(["deploy finished at 14:02"])
      expect(dc.map { |m| m.body.text }).to eq(["deploy finished at 14:02"])
      expect(tg.first.sender_label.to_s).to eq("ops console@api-client")
      expect(dc.first.sender_label.to_s).to eq("ops console@api-client")
    end

    # Posting from one of the room's own endpoints would exclude that endpoint
    # from the fan-out, since the bridge never relays a message back to its
    # origin. The synthetic API endpoint is what makes every channel a target.
    it "reaches the room's first channel too, not every channel except that one" do
      snapshot = registry.current
      map = adapters(snapshot)
      post!("hello")
      api_adapter(router(snapshot, map)).receive_pending

      reached = map.values.flat_map { |adapter| adapter.delivered.map(&:first) }
      expect(reached).to contain_exactly("tg-general", "dc-general")
    end

    it "takes the queued row as it emits, so a second pass does not post it twice" do
      snapshot = registry.current
      map = adapters(snapshot)
      post!("once only")
      adapter = api_adapter(router(snapshot, map))

      adapter.receive_pending
      adapter.receive_pending

      expect(map[[:telegram, "telegram"]].delivered_to("tg-general").size).to eq(1)
      expect(models.api_pending_message.count).to eq(0)
    end
  end

  describe "an API post is moderated exactly like a member's message" do
    it "is screened by the word filter, so it never reaches any platform" do
      controls.enable(community: community, selector: "general", feature: "word_filter")
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "entries", value: '["badword"]')
      snapshot = registry.current
      map = adapters(snapshot)
      route = router(snapshot, map)
      adapter = api_adapter(route)

      post!("this contains badword here")
      adapter.receive_pending
      expect(map[[:telegram, "telegram"]].delivered_to("tg-general")).to be_empty
      expect(map[[:discord, "discord"]].delivered_to("dc-general")).to be_empty

      # A clean post still gets through, so it was the filter that stopped the other one.
      post!("a friendly hello")
      adapter.receive_pending
      expect(map[[:telegram, "telegram"]].delivered_to("tg-general").map { |m| m.body.text })
        .to eq(["a friendly hello"])
    end
  end

  # Post through the API, relay through the bot, read it back off the API's own
  # stream route, with only the platform adapters faked.
  describe "what the room saw comes back out of the live stream" do
    let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
    let(:app) { Rubotty::Api::App.assemble(deps: deps, env: { "API_SSE_MAX_PASSES" => "1" }) }
    let(:token) do
      Rubotty::ControlPlane::ApiKeys.new(models: models)
                                   .issue(scope: "developer", community: community, label: "watcher").token
    end

    it "buffers one row per room at fan-out and serves it to a subscriber" do
      snapshot = registry.current
      route = router(snapshot, adapters(snapshot), live_feed: buffer)
      post!("watch this land")
      api_adapter(route).receive_pending

      get "/communities/sample/rooms/general/stream", { since: 0 }, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

      expect(last_response.body).to include("watch this land")
      # One row for the ROOM, not one per platform it reached.
      expect(models.live_room_message.where(community_id: community.id, room_key: "general").count).to eq(1)
    end

    it "buffers nothing for a message the word filter screened, since the room never saw it" do
      controls.enable(community: community, selector: "general", feature: "word_filter")
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "entries", value: '["badword"]')
      snapshot = registry.current
      route = router(snapshot, adapters(snapshot), live_feed: buffer)
      post!("badword in here")
      api_adapter(route).receive_pending

      expect(models.live_room_message.count).to eq(0)
    end
  end
end
