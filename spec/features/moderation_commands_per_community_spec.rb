# frozen_string_literal: true

require "spec_helper"

# A community whose own commands block (seeded verbatim into
# communities.settings) names cleanup_after or acknowledge wins over the
# bridge-wide default; a room or channel's own feature_settings still wins.
RSpec.describe Rubotty::Features::Moderation do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["55"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end
  let(:clock) { -> { @now ||= Time.now } }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: Hash.new(adapter), session_id: "s", topology: topology(room("r", tg)),
      logger: Rubotty::Log.null
    )
  end

  # The bridge-wide defaults a fresh install ships with: acknowledgements on,
  # no grace period. Any deferral or silence observed below comes from the
  # community's own commands block.
  def feature(cleanup_after: 0, acknowledge: true)
    described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands, cleanup: scheduler,
      cleanup_after: cleanup_after, acknowledge: acknowledge, ephemeral: ephemeral
    )
  end

  def delete_command
    message(tg, text: "/delete", native_id: "1000", author: author(native_id: "55"),
                reply_to: ref("tg", "900"),
                reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "900")))
  end

  def community(settings)
    instance_double(
      Rubotty::ControlPlane::Snapshot::Community, id: 1, settings: settings, operators: directory,
      slug: "sample"
    )
  end

  # Without a control plane the single tenant's directory is what the pipeline
  # hands in; with one it comes off the community.
  def context(community_scope, config: {})
    Rubotty::Features::Context.new(
      message: delete_command, community: community_scope, config: config,
      operators: community_scope.nil? ? directory : nil
    )
  end

  after { scheduler.stop }

  describe "cleanup_after" do
    it "uses the community's own cleanup_after, not the bridge-wide default" do
      scope = community({ "commands" => { "cleanup_after" => 20 } })

      feature.call(context(scope))

      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Acknowledged, deleting this message on all services in 20 seconds.")
      expect(scheduler.pending).to eq(1)
    end

    it "falls through to the bridge-wide cleanup_after when the community sets nothing" do
      scope = community({})

      feature(cleanup_after: 15).call(context(scope))

      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Acknowledged, deleting this message on all services in 15 seconds.")
    end

    it "still lets a room or channel's own feature_settings win over the community block" do
      scope = community({ "commands" => { "cleanup_after" => 20 } })

      feature.call(context(scope, config: { ack_ttl_seconds: 5 }))

      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Acknowledged, deleting this message on all services in 5 seconds.")
    end

    it "always uses the bridge-wide default on the config-only path" do
      feature(cleanup_after: 15).call(context(nil))

      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Acknowledged, deleting this message on all services in 15 seconds.")
    end
  end

  describe "acknowledge" do
    it "silences the 'done' acknowledgement when the community's own block turns it off" do
      scope = community({ "commands" => { "acknowledge" => false } })

      feature.call(context(scope))

      expect(adapter.delivered_to("tg")).to be_empty
    end

    it "falls through to the bridge-wide acknowledge when the community sets nothing" do
      scope = community({})

      feature(acknowledge: false).call(context(scope))

      expect(adapter.delivered_to("tg")).to be_empty
    end

    it "always uses the bridge-wide acknowledge on the config-only path" do
      feature(acknowledge: false).call(context(nil))

      expect(adapter.delivered_to("tg")).to be_empty
    end
  end
end
