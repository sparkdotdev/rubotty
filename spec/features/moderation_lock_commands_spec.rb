# frozen_string_literal: true

require "spec_helper"

# /lock and /unlock (#1723) are Core::Moderation::ACTIONS entries handled here,
# not a new feature: they write moderated_room's own config back through
# FeatureControls, the same read-modify-write /whitelist already uses, rather
# than dispatching to an adapter the way delete/ban/kick/mute do.
RSpec.describe Rubotty::Features::Moderation, "/lock and /unlock", :control_plane do
  let(:tg) { endpoint("tg") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  let(:operator_person) do
    Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["op-1"] })
  end
  let(:operators) { Rubotty::Core::Moderation::Directory.new([operator_person]) }

  let(:channel) do
    Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: community_row.id, route_key: tg.id)
  end

  # Its id matches the real seeded community, and its room id is the real
  # seeded room_key ("general"), so a lock/unlock write here lands on the same
  # row moderated_room's own gate would read; the operator directory is hand
  # built so each example controls exactly who may issue the command.
  let(:snapshot_community) do
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: community_row.id, slug: "sample", name: "sample", status: "active", settings: {},
      topology: Rubotty::Core::Topology.new([room("general", tg)]), channels: [channel],
      operators: operators, people: Rubotty::Core::Directory.new, feature_settings: []
    )
  end

  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end

  def feature(acknowledge: false)
    described_class.new(
      topology: topology(room("general", tg)), adapters: adapters, storage: storage,
      logger: Rubotty::Log.null, commands: commands, feature_controls: controls, acknowledge: acknowledge
    )
  end

  def command(text, author_id:, native_id: "cmd-1")
    message(
      tg, text: text, native_id: native_id, kind: :chat,
      author: author(native_id: author_id, username: "#{author_id}_handle")
    )
  end

  def command_context(msg, config: {})
    Rubotty::Features::Context.new(message: msg, community: snapshot_community, channel: channel, config: config)
  end

  # Reads moderated_room's live state back through a freshly built Registry
  # and Snapshot, the same way the pipeline's own gate would, not the row
  # this spec wrote directly.
  def live_moderated_room
    registry = Rubotty::ControlPlane::Registry.build(models: models, accounts: sample_model.accounts)
    general = registry.current.channel_by_endpoint_key("tg-general")
    community = registry.current.community("sample")
    [community.feature_enabled?(general, "moderated_room"), community.feature_config(general, "moderated_room")]
  end

  describe "/lock" do
    it "enables moderated_room fresh and sets locked true for a room with no prior config" do
      feature.call(command_context(command("/lock", author_id: "op-1")))

      enabled, config = live_moderated_room
      expect(enabled).to be(true)
      expect(config[:locked]).to be(true)
      expect(Array(config[:approved_users])).to be_empty
    end

    it "keeps a real prior whitelist and enabled state while locking" do
      controls.enable(community: community_row, selector: "general", feature: "moderated_room")
      controls.set(community: community_row, selector: "general", feature: "moderated_room",
                    key: "approved_users", value: ["fake:bob-1"])

      feature.call(command_context(command("/lock", author_id: "op-1")))

      enabled, config = live_moderated_room
      expect(enabled).to be(true)
      expect(config[:locked]).to be(true)
      expect(config[:approved_users]).to eq(["fake:bob-1"])
    end

    it "refuses a non-operator with the standard wording, leaving moderated_room untouched" do
      feature.call(command_context(command("/lock", author_id: "someone-else")))

      expect(adapter.delivered_to("tg").last.body.text).to eq("You need to be an operator to use this command.")
      enabled, = live_moderated_room
      expect(enabled).to be(false)
    end

    it "posts a terse success acknowledgement" do
      feature(acknowledge: true).call(command_context(command("/lock", author_id: "op-1")))

      expect(adapter.delivered_to("tg").last.body.text).to eq("Successfully locked room.")
    end
  end

  describe "/unlock" do
    it "returns a room with no prior whitelist to fully open" do
      feature.call(command_context(command("/lock", author_id: "op-1")))

      feature.call(command_context(command("/unlock", author_id: "op-1", native_id: "cmd-2")))

      enabled, = live_moderated_room
      expect(enabled).to be(false)
    end

    it "restores a real prior whitelist and moderated_room's own enabled state exactly" do
      controls.enable(community: community_row, selector: "general", feature: "moderated_room")
      controls.set(community: community_row, selector: "general", feature: "moderated_room",
                    key: "approved_users", value: ["fake:bob-1", "fake:carol-1"])

      feature.call(command_context(command("/lock", author_id: "op-1")))
      feature.call(command_context(command("/unlock", author_id: "op-1", native_id: "cmd-2")))

      enabled, config = live_moderated_room
      expect(enabled).to be(true)
      expect(config[:locked]).to be(false)
      expect(config[:approved_users]).to eq(["fake:bob-1", "fake:carol-1"])
    end

    it "refuses a non-operator with the standard wording" do
      feature.call(command_context(command("/unlock", author_id: "someone-else")))

      expect(adapter.delivered_to("tg").last.body.text).to eq("You need to be an operator to use this command.")
    end

    it "posts a terse success acknowledgement" do
      feature.call(command_context(command("/lock", author_id: "op-1")))

      feature(acknowledge: true).call(command_context(command("/unlock", author_id: "op-1", native_id: "cmd-2")))

      expect(adapter.delivered_to("tg").last.body.text).to eq("Successfully unlocked room.")
    end
  end

  describe "the real gate, once locked" do
    # delete_command_message off, so a /lock's own self-deletion never lands
    # in adapter.deleted and muddies what the assertions below check next.
    let(:quiet) { { delete_command_message: false } }

    def moderated_room
      Rubotty::Features::ModeratedRoom.new(
        topology: topology(room("general", tg)), adapters: adapters, storage: storage,
        logger: Rubotty::Log.null, feature_controls: controls
      )
    end

    def post_as(author_id)
      _enabled, config = live_moderated_room
      moderated_room.call(
        Rubotty::Features::Context.new(
          message: message(tg, text: "hello", native_id: "member-1", author: author(native_id: author_id)),
          community: snapshot_community, channel: channel, config: config, operators: operators
        )
      )
    end

    it "still lets an operator's own message post" do
      feature.call(command_context(command("/lock", author_id: "op-1"), config: quiet))

      expect(post_as("op-1")).to be_continue
    end

    it "removes a non-operator's message through the same explanation flow a rejected poster gets" do
      feature.call(command_context(command("/lock", author_id: "op-1"), config: quiet))

      expect(post_as("member")).to be_halt
      expect(adapter.deleted).to include(["tg", "member-1"])
    end
  end
end
