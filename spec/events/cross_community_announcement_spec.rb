# frozen_string_literal: true

require "spec_helper"

# Issue #1767, reproduced from the production rows. What crossed was the
# outbound native mirror, which answered a room whose own guild it could not
# resolve with the first guild the ACCOUNT knew of, and Discord echoed the
# scheduled event back from there as if it had always belonged to that tenant.
RSpec.describe "an event never reaches another community" do
  let(:client) { DiscordFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }

  # Both communities bridge Discord through ONE account, which is the live
  # shape: alpha is built first and so holds the lower id, making it the guild
  # the old fallback picked for everybody.
  let(:alpha_dc) do
    endpoint("alpha-dc", adapter: :discord, account: "dc",
             settings: { channel_id: "1111" }, community_id: 1)
  end
  let(:beta_dc) do
    endpoint("beta-dc", adapter: :discord, account: "dc",
             settings: { channel_id: "2222" }, community_id: 2)
  end

  subject(:adapter) do
    Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [alpha_dc, beta_dc]
    ).replace_client(client)
  end

  def event_row(overrides = {})
    {
      id: 1, community_id: 2, room_id: 20, title: "AOE3", description: nil,
      timezone: "UTC", kind: "gaming", game_title: nil, server_address: nil, url: nil,
      rsvp_mode: "full", status: "scheduled", reminder_intervals: nil, native_refs: "{}",
      created_by: "discord:owner_handle", starts_at: Time.utc(2026, 8, 24, 15, 30, 0), ends_at: nil
    }.merge(overrides)
  end

  def beta_event(overrides = {}) = Rubotty::Events::Event.new(event_row(overrides))

  describe "the fixture itself" do
    it "really does give both communities a room under the same key" do
      snapshot = colliding_snapshot

      keys = snapshot.communities.flat_map { |community| community.rooms.map(&:id) }
      expect(keys).to eq(%w[general general])
    end

    it "still tells the two rooms apart by their unique id" do
      unique = colliding_snapshot.communities.flat_map { |c| c.rooms.map(&:unique_id) }
      expect(unique).to eq(["1:general", "2:general"])
    end

    it "tags every endpoint with the community that owns it" do
      owners = colliding_snapshot.communities.flat_map { |c| c.rooms.flat_map(&:endpoints) }
                                 .to_h { |ep| [ep.id, ep.community_id] }
      expect(owners).to eq("alpha-telegram" => 1, "alpha-discord" => 1,
                           "beta-telegram" => 2, "beta-discord" => 2)
    end

    it "seeds the same collision as real rows, under the one unique index that allows it" do
      _db, models, seeded = colliding_control_plane

      rooms = models.room.order(:id).select_map(%i[community_id room_key])
      expect(rooms).to eq([[seeded[:alpha][:community_id], "general"],
                           [seeded[:beta][:community_id], "general"]])
    end
  end

  describe "the outbound native mirror" do
    # Both guilds are visible to the gateway: the ordinary case, where each
    # endpoint resolves its own guild and nothing has to fall back.
    before do
      client.channel("1111").server = DiscordFakes::Server.new(id: "guild-alpha", name: "ALPHA")
      client.channel("2222").server = DiscordFakes::Server.new(id: "guild-beta", name: "BETA")
    end

    it "creates beta's event in beta's guild" do
      adapter.create_scheduled_event(beta_event, beta_dc)

      expect(client.created_scheduled_events.first[:guild_id]).to eq("guild-beta")
    end

    it "creates alpha's event in alpha's guild, so the other case is not a coincidence" do
      adapter.create_scheduled_event(beta_event(community_id: 1), alpha_dc)

      expect(client.created_scheduled_events.first[:guild_id]).to eq("guild-alpha")
    end

    # The bug itself. With beta's own channel unreadable, the adapter used to
    # answer with alpha's guild, and that single substitution is the whole leak.
    context "when the room's own guild cannot be resolved off the gateway" do
      before { client.channel("2222").server = nil }

      it "posts nothing at all rather than into the other community's guild" do
        expect(adapter.create_scheduled_event(beta_event, beta_dc)).to be_nil
        expect(client.created_scheduled_events).to be_empty
      end

      it "does not update another community's scheduled event either" do
        adapter.update_scheduled_event("42", beta_event, beta_dc)

        expect(client.updated_scheduled_events).to be_empty
      end

      it "does not delete out of another community's guild" do
        adapter.delete_scheduled_event("42", beta_dc)

        expect(client.deleted_scheduled_events).to be_empty
      end

      it "reads no RSVP roster out of another community's guild" do
        expect(adapter.read_native_rsvps("42", beta_dc)).to be_empty
      end
    end

    # A second endpoint of the SAME community is a legitimate fallback, because
    # the guild it names is one this tenant genuinely bridges.
    context "when another room of the same community can still resolve the guild" do
      let(:beta_second) do
        endpoint("beta-dc-2", adapter: :discord, account: "dc",
                 settings: { channel_id: "3333" }, community_id: 2)
      end

      subject(:adapter) do
        Rubotty::Adapters::Discord::Adapter.new(
          account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null,
          endpoints: [alpha_dc, beta_dc, beta_second]
        ).replace_client(client)
      end

      before do
        client.channel("2222").server = nil
        client.channel("3333").server = DiscordFakes::Server.new(id: "guild-beta", name: "BETA")
      end

      it "falls back inside the community rather than skipping the mirror" do
        adapter.create_scheduled_event(beta_event, beta_dc)

        expect(client.created_scheduled_events.first[:guild_id]).to eq("guild-beta")
      end
    end

    # The signature change: the unsafe call can no longer be written.
    it "refuses a native call made with no endpoint to scope it by" do
      expect { adapter.create_scheduled_event(beta_event, nil) }
        .to raise_error(Rubotty::AdapterError, /needs the room's own endpoint/)
    end
  end

  # The second latch. Even if some future path hands over a guild the community
  # does not bridge, the call is refused rather than made.
  describe "the delivery-point assertion" do
    before do
      client.channel("1111").server = DiscordFakes::Server.new(id: "guild-alpha", name: "ALPHA")
      client.channel("2222").server = DiscordFakes::Server.new(id: "guild-alpha", name: "ALPHA")
    end

    it "refuses when the guild resolved for beta's endpoint serves no beta room" do
      logs = StringIO.new
      loud = Rubotty::Adapters::Discord::Adapter.new(
        account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.build(level: "info", io: logs),
        endpoints: [alpha_dc]
      ).replace_client(client)

      expect(loud.create_scheduled_event(beta_event, beta_dc)).to be_nil
      expect(logs.string).to match(/REFUSED a native scheduled-event call for beta-dc against guild guild-alpha/)
    end
  end
end
