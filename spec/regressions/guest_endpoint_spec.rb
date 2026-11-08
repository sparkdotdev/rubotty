# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rubotty/guest_portal"
require "rack/test"
require "json"

# Guest access turned on from the dashboard, the Guests tab showing it on, and
# yet no guest:<room> endpoint and nothing reaching the guest. Nothing here is
# hand built: the dashboard's own POST writes the row, the real SnapshotBuilder
# reads it back, and the real Runtime, portal and router carry the message.
RSpec.describe "guest access from the dashboard reaches the bot", :control_plane do
  let(:config) { sample_model }
  let(:secret) { "open-sesame" }

  # One store shared by the bot, the dashboard and the guest portal, as the three
  # processes share it in production: two migration regimes on one connection.
  let(:store) do
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end
  let(:db) { store.db }
  let(:models) { Rubotty::ControlPlane.models(db) }
  let(:community) { models.community.where(slug: "sample").first }

  let(:dashboard_deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:dashboard) do
    Rubotty::Dashboard::App.assemble(
      deps: dashboard_deps,
      env: { "DASHBOARD_SECRET" => secret, "GUEST_PORTAL_URL" => "https://guest.example" }
    )
  end
  let(:portal_deps) { Rubotty::GuestPortal::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:portal) { Rubotty::GuestPortal::App.assemble(deps: portal_deps, env: {}) }

  # A signed-in admin session against the real dashboard app.
  def admin
    @admin ||= begin
      session = Rack::Test::Session.new(Rack::MockSession.new(dashboard))
      session.post("/login", secret: secret)
      session
    end
  end

  def guest_browser = Rack::Test::Session.new(Rack::MockSession.new(portal))

  # Turn guest access on or off through the dashboard's own route, so the feature
  # name, the scope and the enabled flag are whatever that route really writes.
  def set_guest_access(room:, allowed:, who_can_invite: "operators")
    admin.post("/communities/sample/guests/access",
               room: room, allowed: allowed, who_can_invite: who_can_invite)
  end

  # Issue a guest link through the dashboard's own route and recover the raw
  # token from the one-time flash, the only place it ever exists.
  def issue_guest_link(room:, nickname: "Sam", ttl_hours: "2")
    admin.post("/communities/sample/guests", room: room, nickname: nickname, ttl_hours: ttl_hours)
    admin.last_request.env["rack.session"][:guest_link].to_s.split("/").last
  end

  # A booted runtime over the same store. Building twice is a restart: the second
  # build rebuilds the snapshot from the database.
  def boot(logger: Rubotty::Log.null)
    Rubotty::Core::Runtime.new(
      config: config, logger: logger, storage: store, env: ControlPlaneHelpers::CONFIG_ENV
    ).build
  end

  def endpoint_ids(topology) = topology.endpoints.map(&:id)

  # The guest endpoint key is built from the room's database id, since room_key is
  # unique only within a community. Tests still think in "general"/"gaming".
  def guest_key_for(room_key, in_community: community)
    room = models.room.where(community_id: in_community.id, room_key: room_key).first
    Rubotty::Adapters::Guest.endpoint_key_for(room.id)
  end

  before { boot } # the first boot seeds the control plane from the config

  describe "the dashboard's write and the SnapshotBuilder's read" do
    it "synthesises the room's guest endpoint from what the dashboard POST wrote" do
      set_guest_access(room: "general", allowed: "on")

      snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models, accounts: {})
      expect(endpoint_ids(snapshot.topology)).to include(guest_key_for("general"))
    end

    it "agrees with the Guests tab: every room the panel shows as allowed has an endpoint" do
      set_guest_access(room: "general", allowed: "on")
      set_guest_access(room: "gaming", allowed: "on", who_can_invite: "everyone")

      snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models, accounts: {})
      allowed = models.room.where(community_id: community.id).all.select do |room|
        dashboard_deps.guest_invites.room_policy(community: community, room: room)[:allowed]
      end

      expect(allowed.map(&:room_key)).to contain_exactly("general", "gaming")
      allowed.each do |room|
        expect(endpoint_ids(snapshot.topology)).to include(Rubotty::Adapters::Guest.endpoint_key_for(room.id))
      end
    end

    it "gives the guest endpoint the room's scope and a real channel to resolve config through" do
      set_guest_access(room: "general", allowed: "on")
      room = models.room.where(community_id: community.id, room_key: "general").first

      snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models, accounts: {})
      endpoint = snapshot.topology.endpoint(guest_key_for("general"))
      expect(endpoint.adapter_name).to eq(:guest)
      expect(endpoint.settings[:room_id]).to eq(room.id)
      expect(endpoint.settings[:community_id]).to eq(community.id)
      expect(endpoint.settings[:channel_endpoint_key]).to eq("tg-general")
    end

    it "leaves every other room alone: enabling one room is not enabling them all" do
      set_guest_access(room: "general", allowed: "on")

      snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models, accounts: {})
      guest_keys = endpoint_ids(snapshot.topology).grep(/\Aguest:/)
      expect(guest_keys).to eq([guest_key_for("general")])
    end

    it "synthesises nothing at all until an operator turns guest access on" do
      snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models, accounts: {})
      expect(endpoint_ids(snapshot.topology).grep(/\Aguest:/)).to be_empty
    end

    # A revoked room must stop admitting guests without waiting for a deploy.
    it "removes the guest endpoint again when the dashboard turns access off" do
      set_guest_access(room: "general", allowed: "on")
      expect(endpoint_ids(Rubotty::ControlPlane::SnapshotBuilder.build(models).topology))
        .to include(guest_key_for("general"))

      set_guest_access(room: "general", allowed: "off")
      expect(endpoint_ids(Rubotty::ControlPlane::SnapshotBuilder.build(models).topology))
        .not_to include(guest_key_for("general"))
    end

    # who_can_invite is a second FeatureControls call right after the enable, so a
    # config merge that clobbered the enabled flag would look exactly like the bug.
    it "keeps the feature enabled while also storing who_can_invite" do
      set_guest_access(room: "general", allowed: "on", who_can_invite: "everyone")

      room = models.room.where(community_id: community.id, room_key: "general").first
      row = models.feature_setting.where(community_id: community.id, room_id: room.id,
                                         feature: "guest_portal").first
      expect(row.json_value(:config)).to eq("who_can_invite" => "everyone")

      policy = dashboard_deps.guest_invites.room_policy(community: community, room: room)
      expect(policy).to eq(allowed: true, who_can_invite: "everyone")
      expect(Rubotty::ControlPlane::SnapshotBuilder.build(models).topology.endpoint(guest_key_for("general")))
        .not_to be_nil
    end
  end

  describe "a booted runtime" do
    it "routes on a topology that carries the guest endpoint" do
      set_guest_access(room: "general", allowed: "on")

      runtime = boot
      expect(endpoint_ids(runtime.registry.current.topology)).to include(guest_key_for("general"))
      expect(endpoint_ids(runtime.router.topology)).to include(guest_key_for("general"))
      expect(runtime.adapters).to have_key([Rubotty::Adapters::Guest::NAME, Rubotty::Adapters::Guest::ACCOUNT])
    end

    # The boot summary renders config.rooms, the static YAML topology, where a
    # guest endpoint has never existed: it is synthesised into the snapshot alone.
    # "16 endpoints, no guest:" in that line was the false lead the bug was filed
    # on, and is evidence of nothing.
    it "is a snapshot property, and never visible in the config-derived summary" do
      set_guest_access(room: "general", allowed: "on")
      runtime = boot

      expect(endpoint_ids(runtime.registry.current.topology)).to include(guest_key_for("general"))
      expect(config.summary).to include("16 endpoint(s)")
      expect(config.summary).not_to include("guest:")
    end
  end

  describe "the guest chain over the real components" do
    let(:runtime) { boot }
    let(:telegram) { Fakes::RecordingAdapter.new(account: "telegram") }
    let(:discord) { Fakes::RecordingAdapter.new(account: "discord") }

    # The bot as it runs, with only the two platform clients swapped for
    # recorders: the same router, dispatcher, guest adapter and topology.
    def running_bot
      runtime.adapters[[:telegram, "telegram"]] = telegram
      runtime.adapters[[:discord, "discord"]] = discord
      runtime.dispatcher.start
      runtime
    end

    def platform_message(topology, endpoint_key, text, native_id)
      endpoint = topology.endpoint(endpoint_key)
      Rubotty::Core::Message.new(
        kind: :chat, ref: Rubotty::Core::MessageRef.new(endpoint.id, native_id), origin: endpoint,
        author: Rubotty::Core::Author.new(username: "ada"),
        body: Rubotty::Core::RichText.plain(text),
        sender_label: Rubotty::Core::SenderLabel.new(username: "ada", platform: endpoint.adapter_name.to_s)
      )
    end

    before { set_guest_access(room: "general", allowed: "on") }

    after { runtime.dispatcher.stop }

    it "carries a guest's send to BOTH platforms bridged into the room" do
      token = issue_guest_link(room: "general")
      bot = running_bot

      browser = guest_browser
      browser.get("/g/#{token}")
      browser.post("/g/#{token}/messages", body: "hello everyone")
      expect(browser.last_response.status).to eq(201)

      bot.adapters[[Rubotty::Adapters::Guest::NAME, Rubotty::Adapters::Guest::ACCOUNT]].receive_pending
      bot.dispatcher.drain

      expect(telegram.delivered_to("tg-general").map { |m| m.body.text }).to eq(["hello everyone"])
      expect(discord.delivered_to("dc-general").map { |m| m.body.text }).to eq(["hello everyone"])
      expect(telegram.delivered_to("tg-general").first.sender_label.to_s).to eq("Sam@guest-user")
    end

    it "merges both platforms into the feed the guest's own browser reads" do
      token = issue_guest_link(room: "general")
      bot = running_bot

      browser = guest_browser
      browser.get("/g/#{token}") # pins the join cursor, so nothing before now

      bot.dispatcher.call(platform_message(bot.router.topology, "tg-general", "hi from telegram", "10"))
      bot.dispatcher.call(platform_message(bot.router.topology, "dc-general", "hi from discord", "11"))
      bot.dispatcher.drain

      browser.get("/g/#{token}/messages.json?since=0")
      bodies = JSON.parse(browser.last_response.body)["messages"].map { |m| m["body"] }
      expect(bodies).to eq(["hi from telegram", "hi from discord"])

      # Additive: the guest joins alongside the ordinary cross-platform relay.
      expect(telegram.delivered_to("tg-general").map { |m| m.body.text }).to eq(["hi from discord"])
      expect(discord.delivered_to("dc-general").map { |m| m.body.text }).to eq(["hi from telegram"])
    end
  end

  # In the window between a dashboard write and the bot's next reload, the relay
  # stamped a guest send before it looked for the room's guest endpoint, so the
  # send was consumed and gone: a stamped row never comes back from #pending_out,
  # and no reload or restart could recover it.
  describe "a guest send made while the snapshot is behind the database" do
    let(:feed) { Rubotty::ControlPlane::GuestFeed.new(models: models) }

    # A registry built before guest access is turned on and never reloaded: what a
    # running bot is still routing with while the database already admits guests.
    def stale_registry
      registry = Rubotty::ControlPlane::Registry.build(models: models, accounts: {})
      expect(endpoint_ids(registry.current.topology)).not_to include(guest_key_for("general"))
      registry
    end

    def guest_adapter(registry, dispatcher)
      Rubotty::Adapters::Guest::Adapter.new(
        dispatcher: dispatcher, feed: feed,
        invites: Rubotty::ControlPlane::GuestInvites.new(models: models),
        models: models, registry: registry, logger: Rubotty::Log.null
      )
    end

    it "waits for the endpoint instead of swallowing the send" do
      registry = stale_registry
      set_guest_access(room: "general", allowed: "on")
      token = issue_guest_link(room: "general")

      browser = guest_browser
      browser.get("/g/#{token}")
      browser.post("/g/#{token}/messages", body: "anyone there?")

      dispatcher = Fakes::RecordingDispatcher.new
      adapter = guest_adapter(registry, dispatcher)

      adapter.receive_pending
      expect(dispatcher.messages).to be_empty
      expect(feed.pending_out.map(&:body)).to eq(["anyone there?"])

      # The snapshot catches up (a reload, or a restart) and the send lands.
      registry.reload
      adapter.receive_pending
      expect(dispatcher.messages.map { |m| m.body.text }).to eq(["anyone there?"])
      expect(feed.pending_out).to be_empty
    end

    it "still retires a send whose session has died, so nothing queues forever" do
      registry = stale_registry
      set_guest_access(room: "general", allowed: "on")
      token = issue_guest_link(room: "general")

      browser = guest_browser
      browser.get("/g/#{token}")
      browser.post("/g/#{token}/messages", body: "too late")

      invite = models.guest_invite.where(community_id: community.id).order(:id).last
      Rubotty::ControlPlane::GuestInvites.new(models: models).revoke(invite: invite)

      dispatcher = Fakes::RecordingDispatcher.new
      guest_adapter(registry, dispatcher).receive_pending

      expect(dispatcher.messages).to be_empty
      expect(feed.pending_out).to be_empty
    end
  end

  # The Guests tab's "allowed" pill and the SnapshotBuilder's decision to
  # synthesise an endpoint resolve the same feature_settings rows through two
  # separately maintained readers, so "panel says on, bot behaves as off" is the
  # two disagreeing. Asserted across every scope shape the writers can produce.
  describe "the Guests tab and the snapshot never disagree" do
    def panel_allows?(room_key)
      room = models.room.where(community_id: community.id, room_key: room_key).first
      dashboard_deps.guest_invites.room_policy(community: community, room: room)[:allowed]
    end

    def snapshot_admits?(room_key)
      topology = Rubotty::ControlPlane::SnapshotBuilder.build(models).topology
      !topology.endpoint(guest_key_for(room_key)).nil?
    end

    it "agrees on a room the panel turned on" do
      set_guest_access(room: "general", allowed: "on")
      expect(panel_allows?("general")).to be(true)
      expect(snapshot_admits?("general")).to be(true)
    end

    it "agrees on a room nobody has touched" do
      expect(panel_allows?("gaming")).to be(false)
      expect(snapshot_admits?("gaming")).to be(false)
    end

    it "agrees on a room the panel turned back off" do
      set_guest_access(room: "general", allowed: "on")
      set_guest_access(room: "general", allowed: "off")
      expect(panel_allows?("general")).to be(false)
      expect(snapshot_admits?("general")).to be(false)
    end

    # The community-wide default row (room_id NULL) the CLI's `all` scope writes:
    # both readers have to inherit it the same way, including for a room with no
    # row of its own.
    it "agrees on every room when the community default is what is enabled" do
      Rubotty::ControlPlane::FeatureControls.new(models: models)
                                            .enable(community: community, selector: "all",
                                                    feature: "guest_portal")
      models.room.where(community_id: community.id).all.each do |room|
        expect(panel_allows?(room.room_key)).to be(true)
        expect(snapshot_admits?(room.room_key)).to be(true)
      end
    end

    # A room row overriding an enabled community default back to off: the one
    # shape where "inherit" and "override" can be resolved in different orders.
    it "agrees when a room overrides an enabled community default back to off" do
      controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
      controls.enable(community: community, selector: "all", feature: "guest_portal")
      set_guest_access(room: "general", allowed: "off")

      expect(panel_allows?("general")).to be(false)
      expect(snapshot_admits?("general")).to be(false)
      expect(panel_allows?("gaming")).to be(true)
      expect(snapshot_admits?("gaming")).to be(true)
    end
  end
end
