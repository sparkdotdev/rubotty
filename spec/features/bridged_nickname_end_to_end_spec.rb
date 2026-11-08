# frozen_string_literal: true

require "spec_helper"

# The whole way through: the write the people page performs, the snapshot a
# reload rebuilds, and the label the bridge puts on the copy it delivers. The
# unit specs held each half correct while the join between them dropped the
# nickname, so this one owns the join.
RSpec.describe "a bridged nickname from the people page to the relayed label", :control_plane do
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:log_io) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: log_io) }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }

  # A second community bridging its own telegram and discord pair, the shape an
  # operator gets by mapping channels on the dashboard.
  def add_community(models, slug:)
    now = Time.now
    community = models.community.create(slug: slug, name: slug, status: "active",
                                        settings: "{}", created_at: now, updated_at: now)
    room = models.room.create(community_id: community.id, room_key: "lounge",
                              display_name: "{}", created_at: now, updated_at: now)
    %w[telegram discord].each_with_index do |adapter_name, index|
      connection = models.platform_connection.create(
        community_id: community.id, adapter: adapter_name, account: adapter_name,
        external_id: "space-#{slug}-#{index}", created_at: now, updated_at: now
      )
      settings = adapter_name == "telegram" ? { "chat_id" => "-100#{index}" } : { "channel_id" => "77#{index}" }
      channel = models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        endpoint_key: "#{adapter_name}-lounge", adapter: adapter_name, account: adapter_name,
        route_key: settings.values.first, settings: JSON.dump(settings),
        receives: true, sends: true, relay: "{}", display_name: "{}",
        label: "lounge", created_at: now, updated_at: now
      )
      models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: now)
    end
    community
  end

  # Dashboard::App#save_dashboard_nickname, verbatim: find or mint the person
  # behind the observed account, then set the name for the target platform.
  def set_nickname(models, community, native_id:, nickname:, identity_adapter: "telegram",
                   target_adapter: "discord")
    nicknames = Rubotty::ControlPlane::BridgedNicknames.new(models: models)
    person = nicknames.person_for(
      community_id: community.id, adapter: identity_adapter, native_id: native_id,
      username: "sample_owner", display: "Alex R"
    )
    nicknames.set(community_id: community.id, person_id: person.id, adapter: target_adapter,
                  nickname: nickname, set_by: "alex")
  end

  # What ControlPlane::Registry#reload does, and what the pipeline then hands
  # each feature: the snapshot's community for the channel the message arrived on.
  def relay(snapshot, community_slug, native_id:, endpoint_key:)
    scope = snapshot.community(community_slug)
    origin = snapshot.topology.endpoint(endpoint_key)
    bridge = Rubotty::Features::Bridge.new(
      topology: snapshot.topology, adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: logger,
      # The deployment-wide union, exactly as Runtime#routing_people supplies it.
      people: snapshot.people
    )
    bridge.call(
      Rubotty::Features::Context.new(
        community: scope,
        message: message(origin, text: "hello", native_id: "m-#{native_id}",
                         author: author(native_id: native_id, username: "sample_owner",
                                        first_name: "Alex", last_name: "S"))
      )
    )
    adapter.delivered
  end

  def label_on(endpoint_id, delivered)
    delivered.reverse.find { |id, _| id == endpoint_id }&.last&.sender_label.to_s
  end

  it "shows the name the page saved on the platform it was saved for" do
    _db, models = seeded_sample
    community = models.community.where(slug: "sample").first
    expect(set_nickname(models, community, native_id: "80000012", nickname: "River").status).to eq(:set)

    snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models)
    delivered = relay(snapshot, "sample", native_id: "80000012", endpoint_key: "tg-general")

    # The chosen name leads and the handle it belongs to still follows: picking a
    # name says what to call somebody, never who they are.
    expect(label_on("dc-general", delivered)).to eq("River [sample_owner@fake]")
  end

  # The defect: a nickname belongs to one community's person, while the merged
  # directory keeps only the FIRST person holding a platform id. Another
  # community's row for the same telegram account answered in its place and
  # carried no nickname, so the label fell back with nothing said.
  it "is not lost to another community holding the same platform account" do
    _db, models = seeded_sample
    lounge = add_community(models, slug: "second")
    expect(set_nickname(models, lounge, native_id: "80000012", nickname: "River").status).to eq(:set)

    snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models)
    # Two communities claim the account, so the deployment-wide view now refuses
    # it rather than handing back whichever community sorted first.
    expect(snapshot.people.by_identity(:telegram, "80000012")).to be_nil

    delivered = relay(snapshot, "second", native_id: "80000012", endpoint_key: "telegram-lounge")

    expect(label_on("discord-lounge", delivered)).to include("River")
  end

  describe "a miss" do
    it "says which person was found and what they hold, rather than passing in silence" do
      _db, models = seeded_sample
      community = models.community.where(slug: "sample").first
      set_nickname(models, community, native_id: "80000012", nickname: "River",
                   identity_adapter: "telegram", target_adapter: "telegram")

      snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models)
      relay(snapshot, "sample", native_id: "80000012", endpoint_key: "tg-general")

      expect(log_io.string).to include("no bridged nickname: sample_owner holds none on discord")
      expect(log_io.string).to include("held: telegram")
    end

    it "says so plainly when the account belongs to nobody at all" do
      _db, models = seeded_sample
      snapshot = Rubotty::ControlPlane::SnapshotBuilder.build(models)

      relay(snapshot, "sample", native_id: "404404", endpoint_key: "tg-general")

      expect(log_io.string).to include("no bridged nickname: telegram 404404 matches no person")
    end
  end
end
