# frozen_string_literal: true

require "spec_helper"

# The feature layer only: which links it notices, when it decides to act, and what it hands
# off. Everything past the hand-off is exercised directly against LinkAnnotation::.
RSpec.describe Rubotty::Features::LinkAnnotation do
  include Builders

  let(:tg) { endpoint("tg") }

  # Records what the feature asked for instead of scheduling it, since the feature must
  # never do outbound work itself.
  let(:annotator) do
    Class.new do
      def initialize = @asked = []

      attr_reader :asked

      def enqueue(**spec)
        @asked << spec
        "job-1"
      end
    end.new
  end

  let(:feature) { described_class.new(logger: Rubotty::Log.null, annotator: annotator) }

  def context(message, **config)
    Rubotty::Features::Context.new(message: message, config: config)
  end

  def chat(text, native_id: "1", **rest)
    message(tg, text: text, native_id: native_id, **rest)
  end

  def reaction_on(native_id, emoji: "🌐")
    message(tg, kind: :reaction_add, native_id: native_id, text: "",
                reaction: Rubotty::Core::Reaction.new(emoji: emoji))
  end

  def urls = annotator.asked.map { |spec| spec[:url] }

  describe "always mode" do
    let(:always) { { mode: "always" } }

    it "asks about a link as soon as it is posted" do
      feature.call(context(chat("look at https://www.spiegel.de/politik/x"), **always))

      expect(urls).to eq(["https://www.spiegel.de/politik/x"])
    end

    it "hands over the room's languages and services, so the job needs nothing else" do
      feature.call(context(chat("https://www.lemonde.fr/a"),
                           **always, room_languages: %w[en de], services: %w[google yandex]))

      expect(annotator.asked.first).to include(known: %w[en de], services: %w[google yandex],
                                               endpoint_id: "tg")
    end

    it "cleans the link before handing it over, so the same article is one URL" do
      feature.call(context(chat("https://www.spiegel.de/a?utm_source=twitter#top"), **always))

      expect(urls).to eq(["https://www.spiegel.de/a"])
    end

    it "sees a link hidden behind display text, the way the link filter does" do
      body = rich("read this", span(:link, 5, 9, url: "https://www.spiegel.de/a"))

      feature.call(context(chat(body), **always))

      expect(urls).to eq(["https://www.spiegel.de/a"])
    end

    it "stops at max_links rather than answering a list of ten articles ten times" do
      feature.call(context(chat("https://a.example/1 https://b.example/2 https://c.example/3"),
                           **always, max_links: 2))

      expect(urls.length).to eq(2)
    end

    it "leaves a domain the room told it to skip alone" do
      feature.call(context(chat("https://news.example.com/a https://other.example/b"),
                           **always, skip_domains: %w[example.com]))

      expect(urls).to eq(["https://other.example/b"])
    end

    it "ignores a message with no link in it" do
      feature.call(context(chat("no links here, see figure 2.3"), **always))

      expect(annotator.asked).to be_empty
    end

    # In always mode the link was already answered when it was posted, so acting on a
    # reaction too would post the same links twice.
    it "does not act again when somebody reacts" do
      feature.call(context(chat("https://www.spiegel.de/a", native_id: "7"), **always))
      annotator.asked.clear
      feature.call(context(reaction_on("7"), **always))

      expect(annotator.asked).to be_empty
    end
  end

  describe "on_reaction mode" do
    it "says nothing until somebody asks" do
      feature.call(context(chat("https://www.spiegel.de/a", native_id: "7")))

      expect(annotator.asked).to be_empty
    end

    it "answers the reaction with the link that message carried" do
      feature.call(context(chat("https://www.spiegel.de/a", native_id: "7")))
      feature.call(context(reaction_on("7")))

      expect(urls).to eq(["https://www.spiegel.de/a"])
    end

    it "ignores a reaction that is not the one this room configured" do
      feature.call(context(chat("https://www.spiegel.de/a", native_id: "7")))
      feature.call(context(reaction_on("7", emoji: "👍")))

      expect(annotator.asked).to be_empty
    end

    it "takes the room's own choice of emoji" do
      config = { reaction: "🇬🇧" }
      feature.call(context(chat("https://www.spiegel.de/a", native_id: "7"), **config))
      feature.call(context(reaction_on("7", emoji: "🇬🇧"), **config))

      expect(urls).to eq(["https://www.spiegel.de/a"])
    end

    # Discord sends the emoji with the variation selector and Telegram sends it without, so
    # an operator pasting one into the config field could have either.
    it "matches the same emoji whether or not it carries the variation selector" do
      config = { reaction: "❤️" }
      feature.call(context(chat("https://www.spiegel.de/a", native_id: "7"), **config))
      feature.call(context(reaction_on("7", emoji: "❤"), **config))

      expect(urls).to eq(["https://www.spiegel.de/a"])
    end

    it "does nothing for a reaction on a message that carried no link" do
      feature.call(context(chat("just talking", native_id: "7")))
      feature.call(context(reaction_on("7")))

      expect(annotator.asked).to be_empty
    end

    it "does nothing for a reaction on a message it never saw" do
      feature.call(context(reaction_on("999")))

      expect(annotator.asked).to be_empty
    end
  end

  describe "as a pipeline citizen" do
    it "never halts, so the bridge still relays the message and the reaction" do
      expect(feature.call(context(chat("https://www.spiegel.de/a"), mode: "always"))).to be_continue
      expect(feature.call(context(reaction_on("7")))).to be_continue
    end

    it "is inert with no annotator behind it, the same degrade the watcher takes" do
      inert = described_class.new(logger: Rubotty::Log.null, annotator: nil)

      expect(inert.call(context(chat("https://www.spiegel.de/a"), mode: "always"))).to be_continue
    end

    it "watches chat and reactions, and nothing else" do
      expect(described_class.observes).to contain_exactly(:chat, :reaction_add)
    end

    it "is off until a community turns it on" do
      expect(described_class.default_enabled?).to be(false)
    end

    it "keeps nothing, so the Features page has no retention notice to show" do
      expect(described_class.retention_notice).to be_nil
    end
  end

  # Every example above calls #call directly, so it keeps passing whatever the
  # observes list says. These drive one real message per observed kind through a
  # real Pipeline, which is the only place the list is ever read.
  describe "every kind it observes, driven through the real pipeline", :control_plane do
    # Off by code default, so a row has to switch it on, and the mode comes off
    # that same row the way an operator sets it.
    def pipeline_in(mode)
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: 1, route_key: tg.id)
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg)]), channels: [channel],
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "link_annotation", enabled: true, config: { mode: mode }
          )
        ]
      )
      Rubotty::Features::Pipeline.new(
        features: [feature],
        registry: instance_double(
          Rubotty::ControlPlane::Registry,
          current: Rubotty::ControlPlane::Snapshot.new(communities: [community])
        )
      )
    end

    observes_kind :chat, "a link in an always-mode room is read as soon as it is posted" do
      pipeline_in("always").handle(chat("look at https://www.spiegel.de/politik/x"))
      urls
    end

    # The message it answers is remembered on the chat pass, so that half is
    # arranged directly and only the reaction goes through the pipeline.
    observes_kind :reaction_add, "the globe placed on an older message is what asks for a translation" do
      feature.call(context(chat("https://www.spiegel.de/a", native_id: "7")))
      pipeline_in("on_reaction").handle(reaction_on("7"))
      urls
    end

    covers_every_observed_kind
  end

  describe "its config" do
    let(:schema) { described_class.config_schema }

    # The dashboard renders a one_of field as a select, so declaring it here puts the
    # dropdown on the page.
    it "offers the two modes as a choice on the feature's config page" do
      expect(schema.fields[:mode].one_of).to eq(%w[always on_reaction])
    end

    it "defaults to waiting to be asked" do
      expect(schema.fields[:mode].default).to eq("on_reaction")
    end

    it "defaults the room to English, which is also what pages are translated into" do
      expect(schema.fields[:room_languages].default).to eq(%w[en])
    end

    it "falls back to sensible values for a scope that configured nothing" do
      feature.call(context(chat("https://www.spiegel.de/a"), mode: "always"))

      expect(annotator.asked.first).to include(known: %w[en], services: %w[google])
    end

    it "ignores a service name it does not know rather than posting a broken link" do
      feature.call(context(chat("https://www.spiegel.de/a"), mode: "always", services: %w[google outline]))

      expect(annotator.asked.first[:services]).to eq(%w[google])
    end

    it "reads a config that arrived from the database with string keys" do
      config = { "mode" => "always", "room_languages" => ["fr"] }
      feature.call(Rubotty::Features::Context.new(message: chat("https://www.spiegel.de/a"), config: config))

      expect(annotator.asked.first).to include(known: %w[fr])
    end
  end
end
