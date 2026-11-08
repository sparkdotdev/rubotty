# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The keyword watcher's chat-facing half: the /watch command surface and the per-community
# matcher cache that scans chat and calls Core::KeywordWatches::Service to notify.
RSpec.describe Rubotty::Features::KeywordWatch do
  let(:tg) { endpoint("tg") }

  # One fake stands in for every endpoint this spec touches, extended with DM capability so
  # "dm" mode notifications are observable without a second platform.
  def dm_capable_adapter(own_id: "bot")
    Class.new(Fakes::ReactingAdapter) do
      def initialize(**opts)
        super
        @dms = []
      end

      attr_reader :dms

      def supports_admin_dm? = true

      def send_admin_dm(native_id, text)
        @dms << { native_id: native_id, text: text }
        true
      end
    end.new(own_id: own_id)
  end

  let(:adapter) { dm_capable_adapter }
  let(:adapters) { Hash.new(adapter) }

  let(:db) do
    db = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(db)
    db
  end
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s", logger: Rubotty::Log.null
    )
  end
  let(:service) do
    Rubotty::Core::KeywordWatches::Service.new(
      store: Rubotty::Core::KeywordWatchStore::Sequel.new(db: db), scheduler: scheduler, adapters: adapters,
      logger: Rubotty::Log.null
    )
  end

  before { scheduler.register(Rubotty::Core::KeywordWatches::EXPIRE_KIND) { |job| service.expire(job) } }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg)), logger: Rubotty::Log.null
    )
  end

  let(:subscriber) { author(native_id: "u1", username: "watcher") }
  let(:stranger) { author(native_id: "u2", username: "stranger") }

  def feature(cleanup: nil)
    described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
      service: service, ephemeral: ephemeral, cleanup: cleanup
    )
  end

  def command(text, from: subscriber, native_id: "100")
    message(tg, text: text, native_id: native_id, author: from)
  end

  # A real Snapshot::Community sharing the "sample" slug the keyword-watch service
  # calls resolve to, so #command_prefixes has feature_config to read; +prefixes+
  # configures the shared marker the way an operator would through the dashboard.
  def community_with(prefixes: nil)
    settings = prefixes.nil? ? [] : [
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        feature: Rubotty::Core::CommandPrefix::CONFIG_FEATURE, enabled: true, config: { "prefixes" => prefixes }
      )
    ]
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: "sample", slug: "sample", name: "sample", status: "active", settings: {},
      topology: Rubotty::Core::Topology.new([]), channels: [],
      operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
      feature_settings: settings
    )
  end

  def context(msg, config: {}, community: community_with)
    Rubotty::Features::Context.new(message: msg, config: config, community: community)
  end

  def last_reply = adapter.delivered_to("tg").last&.body&.text

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat" do
      expect(described_class.feature_name).to eq("keyword_watch")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "publishes a config schema for the dashboard and loader" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "leaves an ordinary message alone so the bridge relays it" do
      outcome = feature.call(context(message(tg, text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "leaves another feature's command alone (only /watch is ours)" do
      outcome = feature.call(context(command("/delete")))
      expect(outcome).to be_continue
    end
  end

  describe "/watch" do
    it "subscribes with the default duration and mode, and confirms it" do
      outcome = feature.call(context(command("/watch aoe3")))
      expect(outcome).to be_halt
      expect(last_reply).to include('Watching "aoe3"').and include("notified by mention")
      watch = service.list(community: "sample", subscriber: subscriber, adapter: :fake).first
      expect(watch.expires_at - Time.now).to be_within(5).of(Rubotty::Core::KeywordWatches::DEFAULT_DURATION)
      expect(watch.notify_via).to eq("mention")
    end

    it "honours an explicit duration and notify mode" do
      feature.call(context(command("/watch aoe3 2h dm")))
      watch = service.list(community: "sample", subscriber: subscriber, adapter: :fake).first
      expect(watch.expires_at - Time.now).to be_within(5).of(7200)
      expect(watch.notify_via).to eq("dm")
    end

    it "swallows the command either way, never relaying it as chat content" do
      outcome = feature.call(context(command("/watch aoe3")))
      expect(outcome).to be_halt
    end

    it "shows the usage help for a bare /watch or /watch help" do
      feature.call(context(command("/watch")))
      expect(last_reply).to include("/watch <keyword>")
      feature.call(context(command("/watch help")))
      expect(last_reply).to include("/watch list")
    end

    it "relays the service's refusal reason verbatim, so a rejection never looks like a bug" do
      feature.call(context(command("/watch x"))) # below the minimum keyword length
      expect(last_reply).to include("at least")
    end

    it "recognises the alternate ! prefix by default, not only /" do
      outcome = feature.call(context(command("!watch aoe3")))
      expect(outcome).to be_halt
      expect(service.list(community: "sample", subscriber: subscriber, adapter: :fake).map(&:keyword)).to eq(["aoe3"])
    end
  end

  describe "/watch list" do
    it "says so when there are no active watches" do
      feature.call(context(command("/watch list")))
      expect(last_reply).to eq("You have no active watches.")
    end

    it "lists every active watch with its remaining time" do
      feature.call(context(command("/watch aoe3 4h")))
      feature.call(context(command("/watch warcraft 1h")))
      outcome = feature.call(context(command("/watch list")))
      expect(outcome).to be_halt
      expect(last_reply).to include("aoe3").and include("warcraft")
    end
  end

  describe "/watch stop" do
    it "says so when there is nothing to stop" do
      feature.call(context(command("/watch stop")))
      expect(last_reply).to eq("You have no active watches to stop.")
    end

    it "stops the one active watch when no keyword is given" do
      feature.call(context(command("/watch aoe3")))
      outcome = feature.call(context(command("/watch stop")))
      expect(outcome).to be_halt
      expect(last_reply).to eq('Stopped watching "aoe3".')
      expect(service.list(community: "sample", subscriber: subscriber, adapter: :fake)).to be_empty
    end

    it "asks which one when several watches exist and no keyword was given" do
      feature.call(context(command("/watch aoe3")))
      feature.call(context(command("/watch warcraft")))
      feature.call(context(command("/watch stop")))
      expect(last_reply).to include("Which one?").and include("aoe3").and include("warcraft")
      # Neither was touched by the ambiguous request.
      expect(service.list(community: "sample", subscriber: subscriber, adapter: :fake).size).to eq(2)
    end

    it "stops the named watch when a keyword is given, leaving the rest" do
      feature.call(context(command("/watch aoe3")))
      feature.call(context(command("/watch warcraft")))
      feature.call(context(command("/watch stop aoe3")))
      expect(last_reply).to eq('Stopped watching "aoe3".')
      remaining = service.list(community: "sample", subscriber: subscriber, adapter: :fake)
      expect(remaining.map(&:keyword)).to eq(["warcraft"])
    end

    it "reports a keyword the subscriber is not watching, rather than silently no-op'ing" do
      feature.call(context(command("/watch stop nope")))
      expect(last_reply).to eq('You\'re not watching "nope".')
    end
  end

  describe "scanning ordinary chat for a match" do
    it "notifies the subscriber when their keyword is said by someone else" do
      feature.call(context(command("/watch aoe3 4h dm", from: subscriber)))
      adapter.delivered.clear

      outcome = feature.call(context(command("anyone up for aoe3 tonight?", from: stranger)))
      expect(outcome).to be_continue # still relayed, this feature never removes anything
      expect(adapter.dms.size).to eq(1)
      expect(adapter.dms.first[:native_id]).to eq("u1")
    end

    it "never notifies the subscriber of their own message" do
      feature.call(context(command("/watch aoe3 4h dm", from: subscriber)))
      feature.call(context(command("thinking about aoe3 later", from: subscriber)))
      expect(adapter.dms).to be_empty
    end

    it "picks up a freshly registered watch on the very next message" do
      feature.call(context(command("nothing to see here", from: stranger))) # compiles an empty cache
      feature.call(context(command("/watch aoe3 4h dm", from: subscriber)))
      feature.call(context(command("aoe3!", from: stranger)))
      expect(adapter.dms.size).to eq(1)
    end

    it "stops matching a keyword once its watch is stopped" do
      feature.call(context(command("/watch aoe3 4h dm", from: subscriber)))
      feature.call(context(command("/watch stop aoe3", from: subscriber)))
      feature.call(context(command("aoe3!", from: stranger)))
      expect(adapter.dms).to be_empty
    end

    describe "at most one notification per message (issue #255)" do
      it "notifies once even when two of the SAME subscriber's keywords both match" do
        feature.call(context(command("/watch aoe3 4h dm", from: subscriber)))
        feature.call(context(command("/watch warcraft 4h dm", from: subscriber)))

        feature.call(context(command("aoe3 or warcraft tonight?", from: stranger)))
        expect(adapter.dms.size).to eq(1)
      end

      it "still notifies two DIFFERENT subscribers whose own keywords both match the same message" do
        other = author(native_id: "u3", username: "second_watcher")
        feature.call(context(command("/watch aoe3 4h dm", from: subscriber)))
        feature.call(context(command("/watch warcraft 4h dm", from: other)))

        feature.call(context(command("aoe3 or warcraft tonight?", from: stranger)))
        expect(adapter.dms.map { |dm| dm[:native_id] }).to contain_exactly("u1", "u3")
      end
    end
  end

  describe "off by default, through the Snapshot", :control_plane do
    def registry_for(feature_settings)
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: 1, route_key: tg.id)
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "sample", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg)]), channels: [channel],
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: feature_settings
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
    end

    it "does not run where no feature_settings row enables it" do
      pipeline = Rubotty::Features::Pipeline.new(features: [feature], registry: registry_for([]))
      pipeline.handle(command("/watch aoe3"))
      expect(adapter.delivered).to be_empty
      expect(service.list(community: "sample", subscriber: subscriber, adapter: :fake)).to be_empty
    end

    it "runs where a feature_settings row turns it on for the community" do
      settings = [Rubotty::ControlPlane::Snapshot::FeatureSetting.new(feature: "keyword_watch", enabled: true,
                                                                       config: {})]
      pipeline = Rubotty::Features::Pipeline.new(features: [feature], registry: registry_for(settings))
      pipeline.handle(command("/watch aoe3"))
      expect(service.list(community: "sample", subscriber: subscriber, adapter: :fake).size).to eq(1)
    end
  end
end
