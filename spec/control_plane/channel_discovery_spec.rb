# frozen_string_literal: true

require "spec_helper"

# The live-gateway half of channel discovery: what feeds the mapping wizard real
# channels, records them dormant, and resolves a Discord guild's seed sentinel.
RSpec.describe Rubotty::ControlPlane::ChannelDiscovery, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:discord_connection) { models.platform_connection.where(adapter: "discord").first }
  let(:telegram_connection) { models.platform_connection.where(adapter: "telegram").first }

  # A Discord channel id is globally unique, so this route_key identifies the
  # seeded guild on its own.
  let(:seeded_discord_channel) { models.channel.where(adapter: "discord").order(:id).first }

  let(:store) do
    Class.new do
      def initialize = @h = {}

      def get_state(key)
        row = @h[key]
        return nil if row.nil?
        return nil if row[:expires_at] && row[:expires_at] <= Time.now

        row[:value]
      end

      def put_state(key, value, expires_at: nil) = @h[key] = { value: value, expires_at: expires_at }
    end.new
  end

  # The prompt medium is not this class's concern, so only the community and
  # descriptor are asserted.
  let(:notifier) do
    Class.new do
      attr_reader :prompts

      def initialize = @prompts = []

      def prompt(community:, descriptor:) = @prompts << { community: community, descriptor: descriptor }
    end.new
  end

  let(:watch) { Rubotty::ControlPlane::NewChannelWatch.new(models: models, store: store) }

  subject(:discovery) do
    described_class.new(models: models, watch: watch, notifier: notifier, logger: Rubotty::Log.null)
  end

  def enable_alerts(ignore: [])
    settings = community.json_value(:settings)
    settings["new_channel_alerts"] = { "enabled" => true, "ignore" => ignore }
    community.update(settings: JSON.generate(settings))
  end

  def disable_alerts
    settings = community.json_value(:settings)
    settings["new_channel_alerts"] = { "enabled" => false }
    community.update(settings: JSON.generate(settings))
  end

  describe "#recognize_guild (the Discord never-leave guarantee, #35)" do
    it "resolves the seed sentinel from a seeded channel and returns the connection" do
      result = discovery.recognize_guild(
        account: "discord", guild_id: "70707070", channel_ids: [seeded_discord_channel.route_key]
      )

      expect(result.id).to eq(discord_connection.id)
      expect(discord_connection.reload.external_id).to eq("70707070")
    end

    it "recognises a guild by ANY of its channels, even amongst unknown ones" do
      result = discovery.recognize_guild(
        account: "discord", guild_id: "70707070",
        channel_ids: ["999000111", seeded_discord_channel.route_key, "222333444"]
      )
      expect(result).not_to be_nil
      expect(discord_connection.reload.external_id).to eq("70707070")
    end

    it "returns nil for a guild that owns no seeded channel (a genuine stranger)" do
      result = discovery.recognize_guild(
        account: "discord", guild_id: "555", channel_ids: %w[123 456]
      )
      expect(result).to be_nil
      # The seeded connection is untouched, so a later boot still resolves it.
      expect(discord_connection.reload.external_id).to eq("unresolved:sample")
    end

    it "keeps a guild already resolved to this id without rewriting it" do
      discord_connection.update(external_id: "70707070")
      result = discovery.recognize_guild(
        account: "discord", guild_id: "70707070", channel_ids: [seeded_discord_channel.route_key]
      )
      expect(result.id).to eq(discord_connection.id)
    end
  end

  describe "#inventory (bulk enumeration, #38)" do
    before { discord_connection.update(external_id: "70707070") }

    it "records enumerated channels that are not yet rows, and skips the seeded ones" do
      channels = [
        { id: seeded_discord_channel.route_key, name: "already-seeded" },
        { id: "900001", name: "announcements" },
        { id: "900002", name: "off-topic" }
      ]
      recorded = discovery.inventory(adapter: :discord, account: "discord", external_id: "70707070",
                                     channels: channels)

      expect(recorded).to eq(2)
      new_row = models.channel.where(adapter: "discord", route_key: "900001").first
      expect(new_row.label).to eq("announcements")
      expect(new_row.community_id).to eq(community.id)
      expect(new_row.platform_connection_id).to eq(discord_connection.id)
      expect(new_row.json_value(:settings)).to eq("channel_id" => "900001")
    end

    it "is idempotent: a second sweep records nothing new" do
      channels = [{ id: "900003", name: "help" }]
      expect(discovery.inventory(adapter: :discord, account: "discord", external_id: "70707070",
                                 channels: channels)).to eq(1)
      expect(discovery.inventory(adapter: :discord, account: "discord", external_id: "70707070",
                                 channels: channels)).to eq(0)
    end

    it "records a dormant channel: it joins no room, so nothing bridges until mapped" do
      discovery.inventory(adapter: :discord, account: "discord", external_id: "70707070",
                          channels: [{ id: "900004", name: "quiet" }])
      row = models.channel.where(route_key: "900004").first
      expect(models.room_channel.where(channel_id: row.id).count).to eq(0)
    end

    it "does nothing for a space no connection owns" do
      expect(discovery.inventory(adapter: :discord, account: "discord", external_id: "does-not-exist",
                                 channels: [{ id: "900005", name: "x" }])).to eq(0)
    end

    # A space still awaiting approval owns no connection, so its whole listing
    # goes in the bin. The warning is the only trace that it happened.
    it "names the adapter, the account and the space when it drops a listing" do
      lines = []
      logger = instance_double(Logger, info: nil)
      allow(logger).to receive(:warn) { |&block| lines << block.call }
      described_class.new(models: models, watch: watch, logger: logger).inventory(
        adapter: :fluxer, account: "fx", external_id: "8000000000000000008",
        channels: [{ id: "10", name: "general" }, { id: "13", name: "announcements" }]
      )

      expect(lines.join("\n")).to include("fluxer", "fx", "8000000000000000008", "2")
    end

    it "says nothing about an empty listing, which dropped nothing" do
      logger = instance_double(Logger, info: nil, warn: nil)
      described_class.new(models: models, watch: watch, logger: logger).inventory(
        adapter: :fluxer, account: "fx", external_id: "8000000000000000008", channels: []
      )

      expect(logger).not_to have_received(:warn)
    end

    # SAMPLE seeds no Stoat connection, so one is created directly here.
    it "addresses a discovered Stoat channel the same way as Discord: a bare channel_id" do
      now = Time.now
      connection = models.platform_connection.create(
        community_id: community.id, adapter: "stoat", account: "st",
        external_id: "SRV1", created_at: now, updated_at: now
      )
      discovery.inventory(adapter: :stoat, account: "st", external_id: "SRV1",
                          channels: [{ id: "CHAN01", name: "general" }])

      row = models.channel.where(adapter: "stoat", route_key: "CHAN01").first
      expect(row.platform_connection_id).to eq(connection.id)
      expect(row.json_value(:settings)).to eq("channel_id" => "CHAN01")
    end

    # Matrix fed no branch in the old addressing case statement, so a
    # discovered room got an empty settings hash where room_id is required,
    # and every send, edit, delete, ban and unban went out with a nil room id.
    describe "addressing a discovered Matrix room (issue #616)" do
      let(:matrix_connection) do
        now = Time.now
        models.platform_connection.create(
          community_id: community.id, adapter: "matrix", account: "mx",
          external_id: "mx", created_at: now, updated_at: now
        )
      end

      it "addresses it with room_id, not an empty hash" do
        matrix_connection
        discovery.inventory(adapter: :matrix, account: "mx", external_id: "mx",
                            channels: [{ id: "!abc123:example.org", name: "general" }])

        row = models.channel.where(adapter: "matrix", route_key: "!abc123:example.org").first
        expect(row.platform_connection_id).to eq(matrix_connection.id)
        expect(row.json_value(:settings)).to eq("room_id" => "!abc123:example.org")
      end

      it "keeps settings[:room_id] once mapped into a room and rebuilt into a real Snapshot" do
        matrix_connection
        discovery.inventory(adapter: :matrix, account: "mx", external_id: "mx",
                            channels: [{ id: "!abc123:example.org", name: "general" }])
        channel = models.channel.where(adapter: "matrix", route_key: "!abc123:example.org").first
        now = Time.now
        room = models.room.create(community_id: community.id, room_key: "matrix-room",
                                  label: "Matrix Room", created_at: now, updated_at: now)
        models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: now)

        snapshot = Rubotty::ControlPlane::Registry.build(models: models, accounts: sample_model.accounts).current
        endpoint = snapshot.community("sample").topology.endpoint(channel.endpoint_key)

        expect(endpoint).not_to be_nil
        expect(endpoint.settings[:room_id]).to eq("!abc123:example.org")
      end
    end
  end

  describe "#unmapped" do
    it "finds every channel outside a room, regardless of how it was first recorded" do
      now = Time.now
      channel = models.channel.create(
        community_id: community.id, platform_connection_id: telegram_connection.id,
        adapter: "telegram", account: telegram_connection.account, route_key: "-100999/7",
        endpoint_key: "provisioned:telegram:telegram:-100999/7", label: "Provisioned topic",
        receives: true, sends: true, relay: "{}", display_name: "{}",
        settings: JSON.generate(chat_id: "-100999", thread_id: 7),
        created_at: now, updated_at: now
      )

      expect(discovery.unmapped(community)).to include(channel)
    end
  end

  describe "#saw (incremental sighting, #39)" do
    def new_topic(route_key: "#{telegram_connection.external_id}/9999", name: "new-topic")
      {
        adapter: "telegram", account: telegram_connection.account,
        external_id: telegram_connection.external_id, route_key: route_key, name: name
      }
    end

    it "records the channel and notifies the operators when the watch prompts" do
      enable_alerts
      decision = discovery.saw(new_topic)

      expect(decision.prompt?).to be(true)
      row = models.channel.where(adapter: "telegram", route_key: "#{telegram_connection.external_id}/9999").first
      expect(row.label).to eq("new-topic")
      expect(row.json_value(:settings)).to eq(
        "chat_id" => telegram_connection.external_id, "thread_id" => 9999
      )
      expect(notifier.prompts.size).to eq(1)
      expect(notifier.prompts.first[:community].id).to eq(community.id)
      expect(notifier.prompts.first[:descriptor][:route_key]).to eq("#{telegram_connection.external_id}/9999")
    end

    it "stays silent and records nothing when the watch ignores (community opted out)" do
      disable_alerts
      decision = discovery.saw(new_topic)
      expect(decision.ignore?).to be(true)
      expect(models.channel.where(route_key: "#{telegram_connection.external_id}/9999").first).to be_nil
      expect(notifier.prompts).to be_empty
    end

    it "prompts and records only once, however chatty the topic is" do
      enable_alerts
      expect(discovery.saw(new_topic).prompt?).to be(true)
      second = discovery.saw(new_topic)
      expect(second.ignore?).to be(true)
      expect(notifier.prompts.size).to eq(1)
      expect(models.channel.where(route_key: "#{telegram_connection.external_id}/9999").count).to eq(1)
    end

    it "does not fail when no notifier is wired: it still records the channel" do
      quiet = described_class.new(models: models, watch: watch)
      enable_alerts
      expect(quiet.saw(new_topic).prompt?).to be(true)
      expect(models.channel.where(route_key: "#{telegram_connection.external_id}/9999").count).to eq(1)
    end

    # A Telegram topic's name rides only on its creation or rename service
    # message, so the sighting that trips the watch often carries no name.
    it "backfills a still-blank label once a later sighting has a name to offer" do
      enable_alerts
      discovery.saw(new_topic(name: nil))
      row = models.channel.where(route_key: "#{telegram_connection.external_id}/9999").first
      expect(row.label).to be_nil

      decision = discovery.saw(new_topic(name: "Lisbon Meetup"))

      expect(decision.ignore?).to be(true)
      expect(row.reload.label).to eq("Lisbon Meetup")
      expect(notifier.prompts.size).to eq(1)
    end

    it "never overwrites an already-known label with a later, different one" do
      enable_alerts
      discovery.saw(new_topic(name: "first-name"))
      discovery.saw(new_topic(name: "renamed-elsewhere"))

      row = models.channel.where(route_key: "#{telegram_connection.external_id}/9999").first
      expect(row.label).to eq("first-name")
    end
  end

  # Always takes effect, since the watch's de-noising is there to filter passive
  # sightings rather than a direct request.
  describe "#identify" do
    def descriptor(name: "Lisbon Meetup", route_key: "#{telegram_connection.external_id}/8888")
      { adapter: "telegram", account: "telegram", external_id: telegram_connection.external_id,
        route_key: route_key, name: name }
    end

    it "creates a new row immediately (not suggested) for an operator, bypassing de-noising entirely" do
      # No enable_alerts, so this shows the path is not gated on them.
      channel = discovery.identify(descriptor: descriptor, operator: true)

      expect(channel.label).to eq("Lisbon Meetup")
      expect(channel.suggested).to be(false)
    end

    it "creates a new row flagged suggested for a non-operator" do
      channel = discovery.identify(descriptor: descriptor, operator: false)

      expect(channel.suggested).to be(true)
    end

    it "renames an EXISTING row, unlike #saw's own record which never overwrites a known label" do
      discovery.identify(descriptor: descriptor(name: "first-name"), operator: true)
      channel = discovery.identify(descriptor: descriptor(name: "renamed"), operator: true)

      expect(channel.label).to eq("renamed")
      expect(models.channel.where(route_key: descriptor[:route_key]).count).to eq(1)
    end

    it "returns nil for a space with no owning community" do
      channel = discovery.identify(
        descriptor: { adapter: "telegram", account: "telegram", external_id: "-999999",
                      route_key: "-999999/1", name: "x" },
        operator: true
      )
      expect(channel).to be_nil
    end

    it "returns nil for a blank name" do
      expect(discovery.identify(descriptor: descriptor(name: ""), operator: true)).to be_nil
      expect(discovery.identify(descriptor: descriptor(name: "  "), operator: true)).to be_nil
    end
  end

  # How {#identify}'s caller decides whether an asker's request takes effect at
  # once or only as a suggestion.
  describe "#operator_for?" do
    let(:operators) { Rubotty::ControlPlane::OperatorFlow.new(models: models) }
    subject(:discovery_with_operators) do
      described_class.new(models: models, watch: watch, notifier: notifier, operators: operators, logger: Rubotty::Log.null)
    end

    def seed_operator(native_id: "55", username: "ada")
      now = Time.now
      person = models.person.create(community_id: community.id, name: "Ada", created_at: now, updated_at: now)
      models.person_identity.create(
        person_id: person.id, adapter: "telegram", native_id: native_id, username: username, created_at: now
      )
      models.operator.create(
        community_id: community.id, person_id: person.id, actions: '"all"', scope: '"all"',
        granted_at: now, granted_by: "test"
      )
    end

    it "is true for a known operator's native_id" do
      seed_operator
      result = discovery_with_operators.operator_for?(
        adapter: "telegram", account: "telegram", external_id: telegram_connection.external_id,
        native_id: "55", username: "someone-else"
      )
      expect(result).to be(true)
    end

    it "is false for someone who is not an operator" do
      seed_operator
      result = discovery_with_operators.operator_for?(
        adapter: "telegram", account: "telegram", external_id: telegram_connection.external_id,
        native_id: "999999", username: "stranger"
      )
      expect(result).to be(false)
    end

    it "is false for a space with no owning community, never raising" do
      result = discovery_with_operators.operator_for?(
        adapter: "telegram", account: "telegram", external_id: "-999999", native_id: "55"
      )
      expect(result).to be(false)
    end

    # The owner floor. A protected operator is authorised everywhere by
    # definition, so it cannot depend on the community, the person row or the
    # operators row existing.
    it "is true for a deployment-configured protected operator, with no rows of any kind and no operators service" do
      # The REAL shipped config, so this also fails if the floor is emptied out.
      entry = Rubotty::Security::ProtectedOperators.default.entries.find { |e| e[:kind] == "username" }
      skip "no protected username configured to assert against" if entry.nil?

      protected_handle = entry[:handle]

      result = discovery.operator_for?(
        adapter: "telegram", account: "telegram", external_id: "-999999",
        native_id: "42", username: protected_handle
      )
      expect(result).to be(true)
    end

    it "is false when no operators: service is wired in, the pre-existing safe default" do
      seed_operator
      result = discovery.operator_for?(
        adapter: "telegram", account: "telegram", external_id: telegram_connection.external_id, native_id: "55"
      )
      expect(result).to be(false)
    end
  end

  # The pipeline-level path, where a row is guaranteed to exist already: the
  # adapter's own resolve is what got the message to the pipeline.
  describe "#identify_known" do
    it "renames the row at the given endpoint_key" do
      channel = discovery.identify_known(
        community_id: seeded_discord_channel.community_id,
        endpoint_key: seeded_discord_channel.endpoint_key, name: "New Name", operator: true
      )
      expect(channel.label).to eq("New Name")
      expect(channel.suggested).to be(false)
      expect(seeded_discord_channel.reload.label).to eq("New Name")
    end

    it "flags suggested for a non-operator" do
      channel = discovery.identify_known(
        community_id: seeded_discord_channel.community_id,
        endpoint_key: seeded_discord_channel.endpoint_key, name: "New Name", operator: false
      )
      expect(channel.suggested).to be(true)
    end

    it "returns nil for an endpoint_key with no matching row (never creates one)" do
      expect(
        discovery.identify_known(community_id: seeded_discord_channel.community_id,
                                 endpoint_key: "no-such-key", name: "x", operator: true)
      ).to be_nil
    end

    # Issue #1802: endpoint keys are globally unique, so a predicate without
    # the community relabels whichever tenant happens to own the key.
    it "refuses the shape of the call that has no community to scope by" do
      expect do
        discovery.identify_known(community_id: nil, endpoint_key: seeded_discord_channel.endpoint_key,
                                 name: "New Name", operator: true)
      end.to raise_error(ArgumentError)
    end

    it "keeps no overload that takes a bare endpoint key" do
      expect do
        discovery.identify_known(endpoint_key: seeded_discord_channel.endpoint_key,
                                 name: "New Name", operator: true)
      end.to raise_error(ArgumentError)
    end

    it "returns nil for a blank name" do
      expect(
        discovery.identify_known(community_id: seeded_discord_channel.community_id,
                                 endpoint_key: seeded_discord_channel.endpoint_key, name: "", operator: true)
      ).to be_nil
    end
  end

  describe "#approve_suggestion and #reject_suggestion" do
    let!(:suggestion) { discovery.identify(descriptor: descriptor, operator: false) }

    def descriptor(name: "Lisbon Meetup")
      { adapter: "telegram", account: "telegram", external_id: telegram_connection.external_id,
        route_key: "#{telegram_connection.external_id}/8888", name: name }
    end

    it "approve clears the suggested flag without touching anything else" do
      channel = discovery.approve_suggestion(suggestion.id)
      expect(channel.suggested).to be(false)
      expect(channel.label).to eq("Lisbon Meetup")
    end

    it "approve is a no-op on an id that was never suggested" do
      discovery.approve_suggestion(suggestion.id)
      expect(discovery.approve_suggestion(suggestion.id)).to be_nil
    end

    it "reject clears the suggested name and keeps the channel" do
      expect(discovery.reject_suggestion(suggestion.id)).to be(true)
      channel = models.channel[suggestion.id]
      expect(channel.label).to be_nil
      expect(channel.suggested).to be(false)
    end

    it "reject keeps a mapped channel in its room" do
      discovery.identify_known(community_id: seeded_discord_channel.community_id,
                               endpoint_key: seeded_discord_channel.endpoint_key,
                               name: "Suggested name", operator: false)
      room_ids = models.room_channel.where(channel_id: seeded_discord_channel.id).select_map(:room_id)

      expect(discovery.reject_suggestion(seeded_discord_channel.id)).to be(true)

      channel = models.channel[seeded_discord_channel.id]
      expect(channel.label).to be_nil
      expect(channel.suggested).to be(false)
      expect(models.room_channel.where(channel_id: seeded_discord_channel.id).select_map(:room_id)).to eq(room_ids)
    end

    it "reject is a no-op (and never deletes) a row that was never suggested" do
      discovery.approve_suggestion(suggestion.id)
      expect(discovery.reject_suggestion(suggestion.id)).to be(false)
      expect(models.channel[suggestion.id]).not_to be_nil
    end

    it "reject never touches an unrelated, already-approved real channel by guessing its id" do
      expect(discovery.reject_suggestion(seeded_discord_channel.id)).to be(false)
      expect(models.channel[seeded_discord_channel.id]).not_to be_nil
    end
  end

  # The join event is a single point of failure: a bot that was down when it was
  # added never sees one. Traffic from a space nothing can attribute is the
  # second way in, and it reaches every adapter that already feeds #saw.
  describe "pending an unattributed space from its traffic" do
    let(:pended) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def on_traffic!(adapter:, account:, external_id:, name: nil)
          @calls << { adapter: adapter, account: account, external_id: external_id, name: name }
          nil
        end
      end.new
    end

    subject(:discovery) do
      described_class.new(models: models, watch: watch, notifier: notifier,
                          pending_spaces: pended, logger: Rubotty::Log.null)
    end

    it "pends a space no platform connection owns" do
      discovery.saw(adapter: :telegram, account: "telegram", external_id: "-100777",
                    route_key: "-100777", name: "Rando Group")

      expect(pended.calls).to eq(
        [{ adapter: "telegram", account: "telegram", external_id: "-100777", name: "Rando Group" }]
      )
    end

    it "offers no name when the sighting is one channel inside the space, not the space itself" do
      discovery.saw(adapter: :telegram, account: "telegram", external_id: "-100777",
                    route_key: "-100777/42", name: "some topic")

      expect(pended.calls.first[:name]).to be_nil
    end

    it "never pends a space that IS mapped to a community" do
      discovery.saw(adapter: :telegram, account: telegram_connection.account,
                    external_id: telegram_connection.external_id, route_key: "-100777/9",
                    name: "a new topic")

      expect(pended.calls).to be_empty
    end

    it "keeps recording channels normally, so the fallback changes no discovery behaviour" do
      enable_alerts
      decision = discovery.saw(adapter: :telegram, account: telegram_connection.account,
                               external_id: telegram_connection.external_id,
                               route_key: "-100777/9", name: "a new topic")

      expect(decision.prompt?).to be(true)
      expect(models.channel.where(route_key: "-100777/9").first).not_to be_nil
    end

    it "swallows a failure in the pending service rather than losing the sighting" do
      allow(pended).to receive(:on_traffic!).and_raise(StandardError, "database gone")

      expect do
        discovery.saw(adapter: :telegram, account: "telegram", external_id: "-100777",
                      route_key: "-100777", name: "Rando Group")
      end.not_to raise_error
    end

    it "does nothing at all without a pending service, which is the dashboard's wiring" do
      bare = described_class.new(models: models, watch: watch, logger: Rubotty::Log.null)

      expect do
        bare.saw(adapter: :telegram, account: "telegram", external_id: "-100777",
                 route_key: "-100777", name: "Rando Group")
      end.not_to raise_error
    end
  end
end
