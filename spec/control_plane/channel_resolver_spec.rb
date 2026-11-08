# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::ChannelResolver, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: sample_model.accounts) }

  subject(:resolver) { described_class.new(registry) }

  describe "#endpoint_for, the value the adapter's endpoint_for closure returns" do
    it "resolves an exact Telegram forum topic to its endpoint" do
      endpoint = resolver.endpoint_for(:telegram, "telegram", "-1008000000001/142483")
      expect(endpoint).to be_a(Rubotty::Core::Endpoint)
      expect(endpoint.id).to eq("tg-gaming")
    end

    it "misses, rather than falling back to the General topic, for an unknown thread in a known chat" do
      # Handing back General's endpoint here would break the echo exclusion in
      # Room#targets_for, bouncing a relayed message back into the topic.
      expect(resolver.endpoint_for(:telegram, "telegram", "-1008000000001/999999")).to be_nil
    end

    it "resolves the General topic addressed by the bare chat_id" do
      expect(resolver.endpoint_for(:telegram, "telegram", "-1008000000001").id).to eq("tg-general")
    end

    it "resolves a Discord channel by its snowflake" do
      expect(resolver.endpoint_for(:discord, "discord", "800000000000000011").id).to eq("dc-general")
    end

    it "misses on a space the bot does not serve" do
      expect(resolver.endpoint_for(:telegram, "telegram", "-999")).to be_nil
    end

    it "misses on the right adapter but the wrong account (shared-token isolation)" do
      expect(resolver.endpoint_for(:telegram, "someone-elses-bot", "-1008000000001")).to be_nil
    end
  end

  # For an inbound address COARSER than a route key. A Telegram reaction names
  # its chat and never its topic, so the adapter has to weigh every endpoint in
  # that chat rather than ask for one address.
  describe "#endpoints_for" do
    it "hands back every route key this adapter and account can resolve" do
      keys = resolver.endpoints_for(:telegram, "telegram").map(&:first)
      expect(keys).to include("-1008000000001", "-1008000000001/142483")
    end

    it "pairs each key with the endpoint it resolves to" do
      pairs = resolver.endpoints_for(:telegram, "telegram").to_h
      expect(pairs["-1008000000001/142483"].id).to eq("tg-gaming")
      expect(pairs["-1008000000001"].id).to eq("tg-general")
    end

    it "leaves out another adapter's channels" do
      ids = resolver.endpoints_for(:telegram, "telegram").map { |_key, endpoint| endpoint.id }
      expect(ids).not_to include("dc-general")
    end

    it "leaves out the same adapter on another account, as shared-token isolation requires" do
      expect(resolver.endpoints_for(:telegram, "someone-elses-bot")).to be_empty
    end
  end

  # What Adapters::Irc::Adapter reads on every reconcile to rebuild its
  # HubRouter live: every channel sharing one physical (adapter, account)
  # connection, grouped by community AND route_key, so a hub group
  # ChannelMapper#add_hub_room wrote shows up here with no adapter restart.
  describe "#hub_groups_for" do
    def key_for(community, route_key)
      Rubotty::Adapters::Irc::HubRouter.key_for(community.id, route_key)
    end

    def irc_channel(endpoint_key:, route_key:, receives:, room_label:, account: "irc-hub", slug: "sample")
      community = models.community.where(slug: slug).first
      now = Time.now
      connection = models.platform_connection.where(adapter: "irc", account: account).first ||
                   models.platform_connection.create(
                     community_id: community.id, adapter: "irc", account: account,
                     external_id: endpoint_key, created_at: now, updated_at: now
                   )
      models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: "irc", account: account, route_key: route_key, endpoint_key: endpoint_key,
        label: endpoint_key, receives: receives, sends: true, relay: "{}", display_name: "{}",
        settings: JSON.generate(channel: route_key, room_label: room_label),
        created_at: now, updated_at: now
      )
    end

    let(:sample) { models.community.where(slug: "sample").first }

    it "groups every channel of one community sharing one route_key together, live" do
      irc_channel(endpoint_key: "irc-hub-gaming", route_key: "#sample", receives: true, room_label: "gaming")
      irc_channel(endpoint_key: "irc-hub-travel", route_key: "#sample", receives: false, room_label: "travel")
      registry.reload

      groups = resolver.hub_groups_for(:irc, "irc-hub")

      expect(groups[key_for(sample, "#sample")].map(&:id)).to contain_exactly("irc-hub-gaming", "irc-hub-travel")
    end

    it "answers a group of exactly one for an ordinary, unshared channel" do
      irc_channel(endpoint_key: "irc-solo", route_key: "#solo", receives: true, room_label: "solo")
      registry.reload

      expect(resolver.hub_groups_for(:irc, "irc-hub")[key_for(sample, "#solo")].map(&:id)).to eq(["irc-solo"])
    end

    it "leaves out another account's channels, as shared-token isolation requires" do
      irc_channel(endpoint_key: "irc-hub-gaming", route_key: "#sample", receives: true, room_label: "gaming")
      registry.reload

      expect(resolver.hub_groups_for(:irc, "someone-elses-bot")).to be_empty
    end

    # Issue #1789. Both communities map #general on the same shared account,
    # which is the shape a name like that invites. Grouped on route_key alone
    # this was ONE group of three, so the IRC listing command handed a member of
    # either tenant the other's room labels and a code to address them by.
    describe "two communities mapping the same channel on one account" do
      let(:second) do
        now = Time.now
        models.community.where(slug: "second").first ||
          models.community[models.community.insert(slug: "second", name: "SECOND", status: "active",
                                                   created_at: now, updated_at: now)]
      end

      # Only one channel per (adapter, account, route_key) may receive, which
      # migration 061 enforces, so the second tenant's rooms are outbound only.
      # Their labels were disclosed all the same.
      before do
        second
        irc_channel(endpoint_key: "sample-news", route_key: "#general", receives: true, room_label: "news")
        irc_channel(endpoint_key: "sample-games", route_key: "#general", receives: false, room_label: "games")
        irc_channel(endpoint_key: "second-plans", route_key: "#general", receives: false, room_label: "plans",
                    slug: "second")
        irc_channel(endpoint_key: "second-secret", route_key: "#general", receives: false, room_label: "secret",
                    slug: "second")
        registry.reload
      end

      it "builds one group per community rather than one spanning both" do
        groups = resolver.hub_groups_for(:irc, "irc-hub")
        expect(groups.keys).to include(key_for(sample, "#general"), key_for(second, "#general"))
      end

      it "keeps the other community's endpoints out of a community's group" do
        groups = resolver.hub_groups_for(:irc, "irc-hub")
        expect(groups[key_for(sample, "#general")].map(&:id)).to contain_exactly("sample-news", "sample-games")
        expect(groups[key_for(second, "#general")].map(&:id)).to contain_exactly("second-plans", "second-secret")
      end

      it "shows a listing that names only the asking community's rooms" do
        router = Rubotty::Adapters::Irc::HubRouter.new(
          channel_groups: resolver.hub_groups_for(:irc, "irc-hub")
        )
        listing = router.listing_text(sample.id, "#general")
        expect(listing).to eq("ga: games, ne: news")
        expect(listing).not_to match(/plans|secret/)
      end

      it "will not resolve the other community's short code to its endpoint" do
        router = Rubotty::Adapters::Irc::HubRouter.new(
          channel_groups: resolver.hub_groups_for(:irc, "irc-hub")
        )
        expect(router.resolve(sample.id, "#general", "!se hello").kind).to eq(:unknown_code)
      end
    end
  end

  describe "#resolve returns the owning channel" do
    it "carries the community id so the caller knows the owner" do
      channel = resolver.resolve(:discord, "discord", "8000000000000000003")
      expect(channel.endpoint_key).to eq("dc-gaming")
      expect(channel.community_id).to eq(registry.current.community("sample").id)
    end
  end

  describe "#route maps an inbound address to (community, channel)" do
    it "returns the owning community and its channel for a single community" do
      community, channel = resolver.route(:telegram, "telegram", "-1008000000001/142483")
      expect(community.slug).to eq("sample")
      expect(channel.endpoint_key).to eq("tg-gaming")
    end

    it "returns nil for an unmapped thread in a known chat rather than falling back to General" do
      expect(resolver.route(:telegram, "telegram", "-1008000000001/000000")).to be_nil
    end

    it "returns nil for an unclaimed space" do
      expect(resolver.route(:discord, "discord", "999888777")).to be_nil
    end
  end

  describe "reading the live snapshot" do
    it "reflects a control-plane change after the registry reloads" do
      # Thread 777 is an unmapped topic until the channel below exists.
      expect(resolver.endpoint_for(:telegram, "telegram", "-1008000000001/777")).to be_nil

      conn = models.platform_connection.where(adapter: "telegram").first
      community = models.community.where(slug: "sample").first
      now = Time.now
      models.channel.create(
        community_id: community.id, platform_connection_id: conn.id,
        adapter: "telegram", account: "telegram", route_key: "-1008000000001/777",
        endpoint_key: "tg-late", label: "late", receives: true, sends: true,
        relay: "{}", display_name: "{}",
        settings: '{"chat_id":"-1008000000001","thread_id":777}',
        created_at: now, updated_at: now
      )
      registry.reload

      expect(resolver.endpoint_for(:telegram, "telegram", "-1008000000001/777").id).to eq("tg-late")
    end
  end
end
