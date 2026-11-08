# frozen_string_literal: true

require "spec_helper"

# The guest portal in both directions over the real Router and Bridge. A guest
# send takes the ordinary inbound path, so the moderation features that screen a
# member's message screen it too, and a message relayed from any endpoint of the
# room lands in the one room-scoped feed the guest reads.
RSpec.describe "guest portal through the pipeline", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community) { models.community.where(slug: "sample").first }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new }

  # A RecordingAdapter for every real (adapter, account) in the topology. Only
  # the room -> guest tests need a live guest adapter, and they add it themselves.
  def adapters(snapshot)
    snapshot.topology.endpoints.reject { |e| e.adapter_name == :guest }.each_with_object({}) do |e, map|
      map[[e.adapter_name, e.account]] ||= Fakes::RecordingAdapter.new(account: e.account)
    end
  end

  def router(snapshot, adapter_map)
    Rubotty::Core::Router.new(
      topology: snapshot.topology, adapters: adapter_map, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, registry: registry
    )
  end

  # A guest send as the guest adapter emits it, from the room's one guest
  # endpoint (one per room rather than one per channel).
  def guest_send(snapshot, text, native_id)
    room = models.room.where(community_id: community.id, room_key: "general").first
    endpoint = snapshot.topology.endpoint(Rubotty::Adapters::Guest.endpoint_key_for(room.id))
    Rubotty::Core::Message.new(
      kind: :chat, ref: Rubotty::Core::MessageRef.new(endpoint.id, native_id), origin: endpoint,
      author: Rubotty::Core::Author.new(native_id: "guest-1", display_name: "Sam"),
      body: Rubotty::Core::RichText.plain(text),
      sender_label: Rubotty::Core::SenderLabel.guest(nickname: "Sam")
    )
  end

  before { controls.enable(community: community, selector: "general", feature: "guest_portal") }

  describe "guest -> room: fans out to every platform bridged into the room" do
    it "fans a clean guest send out to every real endpoint of the room, marked as a guest" do
      snapshot = registry.current
      map = adapters(snapshot)
      router(snapshot, map).handle(guest_send(snapshot, "hello everyone", "1"))

      tg = map[[:telegram, "telegram"]].delivered_to("tg-general")
      dc = map[[:discord, "discord"]].delivered_to("dc-general")
      expect(tg.map { |m| m.body.text }).to eq(["hello everyone"])
      expect(dc.map { |m| m.body.text }).to eq(["hello everyone"])
      expect(tg.first.sender_label.to_s).to eq("Sam@guest-user")
      expect(dc.first.sender_label.to_s).to eq("Sam@guest-user")
    end

    it "screens a guest send through the word filter, so it never reaches any platform" do
      controls.enable(community: community, selector: "general", feature: "word_filter")
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "entries", value: '["badword"]')
      snapshot = registry.current
      map = adapters(snapshot)
      route = router(snapshot, map)

      route.handle(guest_send(snapshot, "this contains badword here", "1"))
      expect(map[[:telegram, "telegram"]].delivered_to("tg-general")).to be_empty
      expect(map[[:discord, "discord"]].delivered_to("dc-general")).to be_empty

      # A clean send still gets through, so it was the filter that stopped the other one.
      route.handle(guest_send(snapshot, "a friendly hello", "2"))
      expect(map[[:telegram, "telegram"]].delivered_to("tg-general").map { |m| m.body.text }).to eq(["a friendly hello"])
    end
  end

  # A real guest adapter wired against the control plane, so the write lands in
  # guest_messages and GuestFeed#for_guest reads it back.
  describe "room -> guest: every platform relays into ONE room-scoped feed (issue #156)" do
    let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models) }
    let(:feed) { Rubotty::ControlPlane::GuestFeed.new(models: models) }
    let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

    let(:guest_adapter) do
      Rubotty::Adapters::Guest::Adapter.new(
        dispatcher: Fakes::RecordingDispatcher.new, feed: feed, invites: invites,
        models: models, registry: registry, logger: Rubotty::Log.null
      )
    end

    # The real endpoints plus the real guest adapter, so the bridge fans out to
    # it the same way it does to Telegram or Discord.
    def adapters_with_guest(snapshot)
      map = snapshot.topology.endpoints.reject { |e| e.adapter_name == :guest }.each_with_object({}) do |e, m|
        m[[e.adapter_name, e.account]] ||= Fakes::RecordingAdapter.new(account: e.account)
      end
      map[[Rubotty::Adapters::Guest::NAME, Rubotty::Adapters::Guest::ACCOUNT]] = guest_adapter
      map
    end

    def platform_message(snapshot, endpoint_key, text, native_id)
      endpoint = snapshot.topology.endpoint(endpoint_key)
      Rubotty::Core::Message.new(
        kind: :chat, ref: Rubotty::Core::MessageRef.new(endpoint.id, native_id), origin: endpoint,
        author: Rubotty::Core::Author.new(username: "ada"),
        body: Rubotty::Core::RichText.plain(text),
        sender_label: Rubotty::Core::SenderLabel.new(username: "ada", platform: endpoint.adapter_name.to_s)
      )
    end

    it "merges a message from telegram and a message from discord into one feed a guest reads" do
      invite = invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600).invite
      invites.record_join(invite: invite, cursor: feed.latest_id(room_id: room.id))

      snapshot = registry.current
      map = adapters_with_guest(snapshot)
      route = router(snapshot, map)

      route.handle(platform_message(snapshot, "tg-general", "hi from telegram", "10"))
      route.handle(platform_message(snapshot, "dc-general", "hi from discord", "11"))

      bodies = feed.for_guest(invite: invite.refresh, since: 0).map(&:body)
      expect(bodies).to eq(["hi from telegram", "hi from discord"])

      # The merge is additive: the guest joins as a third participant alongside
      # the ordinary cross-platform bridge.
      tg = map[[:telegram, "telegram"]].delivered_to("tg-general").map { |m| m.body.text }
      dc = map[[:discord, "discord"]].delivered_to("dc-general").map { |m| m.body.text }
      expect(tg).to eq(["hi from discord"])
      expect(dc).to eq(["hi from telegram"])
    end

    it "writes nothing into the feed when no guest is live in the room" do
      snapshot = registry.current
      map = adapters_with_guest(snapshot)
      router(snapshot, map).handle(platform_message(snapshot, "tg-general", "nobody home", "12"))

      expect(models.guest_message.where(direction: "in").count).to eq(0)
    end
  end
end
