# frozen_string_literal: true

require "spec_helper"

# A bot meeting a guild for the first time pends it for review and enumerates
# its channels in the same breath, but the connection those channels would be
# recorded against does not exist until an administrator approves the space.
# The first listing was thrown away and nothing re-enumerated until reconnect.
RSpec.describe "channels sighted before a space was approved", :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:guild_id) { "8000000000000000008" }

  let(:client) do
    FluxerFakes::Client.new(
      guilds: [{ "id" => guild_id, "name" => "Example Gaming Community" }],
      guild_channels: {
        guild_id => [
          FluxerFakes.channel_data(id: "10", name: "general"),
          FluxerFakes.channel_data(id: "11", name: "Text Channels", type: 4),
          FluxerFakes.channel_data(id: "13", name: "announcements")
        ]
      }
    )
  end

  let(:discovery) { Rubotty::ControlPlane::ChannelDiscovery.new(models: models, logger: Rubotty::Log.null) }

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "bot",
      logger: Rubotty::Log.null
    )
  end

  let(:adapters) { {} }

  let(:pending_spaces) do
    Rubotty::ControlPlane::PendingSpaces.new(
      models: models, authorization: Rubotty::ControlPlane::AuthorizationDirectory.new(models: models),
      scheduler: scheduler, adapters: adapters, logger: Rubotty::Log.null
    )
  end

  subject(:adapter) do
    Rubotty::Adapters::Fluxer::Adapter.new(
      account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: [],
      discovery: discovery, pending_spaces: pending_spaces
    ).replace_client(client).replace_gateway(FluxerFakes::Gateway.new)
  end

  # The bot signs in, lists the guild's channels, and pends the guild, all before
  # anybody has approved anything.
  def connect!
    adapters[[:fluxer, "fx"]] = adapter
    adapter.handle_event(FluxerFakes.ready)
    adapter.handle_event(FluxerFakes.guild_created(id: guild_id, name: nil, member_count: 2))
    models.pending_space.where(adapter: "fluxer", external_id: guild_id).first
  end

  def discovered_channels
    models.channel.where(adapter: "fluxer", account: "fx").order(:route_key).all
  end

  it "records nothing at connect, since the space has no connection to record against" do
    row = connect!

    expect(row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
    expect(discovered_channels).to be_empty
  end

  it "records the channels once the space is approved, which is the sighting that was lost" do
    row = connect!

    result = pending_spaces.approve(id: row.id, admin: "dashboard:administrator",
                                    new_community_name: "Example Gaming Community")

    expect(result.status).to eq(:approved)
    expect(discovered_channels.map(&:route_key)).to eq(%w[10 13])
    connection = models.platform_connection.where(adapter: "fluxer", external_id: guild_id).first
    expect(discovered_channels.map(&:platform_connection_id).uniq).to eq([connection.id])
    expect(discovered_channels.map(&:community_id).uniq).to eq([result.community.id])
  end

  it "records them dormant, so an approval bridges nothing on its own" do
    row = connect!
    pending_spaces.approve(id: row.id, admin: "test", new_community_name: "Example Gaming Community")

    ids = discovered_channels.map(&:id)
    expect(models.room_channel.where(channel_id: ids).count).to eq(0)
  end

  # The board lives in the dashboard, which holds no adapter, so the sweep is a
  # durable job the bot process picks up.
  context "when the approval is made where no adapter lives" do
    let(:dashboard) do
      Rubotty::ControlPlane::PendingSpaces.new(
        models: models, authorization: Rubotty::ControlPlane::AuthorizationDirectory.new(models: models),
        scheduler: scheduler, adapters: {}, logger: Rubotty::Log.null
      )
    end

    it "hands the sweep to the bot process rather than losing the channels again" do
      row = connect!
      dashboard.approve(id: row.id, admin: "dashboard:administrator",
                        new_community_name: "Example Gaming Community")
      expect(discovered_channels).to be_empty

      scheduler.register(Rubotty::ControlPlane::PendingSpaces::ENUMERATE_KIND) { |job| pending_spaces.enumerate(job) }
      scheduler.run_due

      expect(discovered_channels.map(&:route_key)).to eq(%w[10 13])
    end
  end

  # The GUILD_CREATE frame carried a nil name, so the card read as an unnamed
  # space and the approval created a connection with a blank label.
  it "names the space from the REST listing, so the board and the label are not blank" do
    row = connect!
    expect(row.name).to eq("Example Gaming Community")

    pending_spaces.approve(id: row.id, admin: "test", new_community_name: "Example Gaming Community")

    connection = models.platform_connection.where(adapter: "fluxer", external_id: guild_id).first
    expect(connection.label).to eq("Example Gaming Community")
  end

  # The guild already on the deployment was approved with a blank label, so only
  # a later join can fill one in.
  it "backfills a connection that was already approved with no label at all" do
    now = Time.now
    community = models.community.create(slug: "sample", name: "SAMPLE", status: "active",
                                        created_at: now, updated_at: now)
    connection = models.platform_connection.create(
      community_id: community.id, adapter: "fluxer", account: "fx", external_id: guild_id,
      label: nil, created_at: now, updated_at: now
    )

    connect!

    expect(connection.refresh.label).to eq("Example Gaming Community")
  end
end
