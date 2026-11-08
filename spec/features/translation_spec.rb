# frozen_string_literal: true

require "spec_helper"

# The feature layer only: which peers a message is queued for, and what it
# hands off. Everything past the hand-off, the actual LibreTranslate call and
# delivery, is exercised directly against Translation::Relay and, end to end
# with a real three room group, in spec/integration/translation_loop_spec.rb.
RSpec.describe Rubotty::Features::Translation do
  include Builders

  # The snapshot seam the feature reads rooms and per-room config through, the same double
  # spec/features/redirection_spec.rb uses, extended here with real per-room settings since
  # this feature's whole job is reading them. Real Snapshot::Community#feature_enabled?/
  # #feature_config resolve an endpoint id back to a room key themselves (channel over room
  # over community), so this double mirrors that indirection rather than taking the room key
  # directly.
  TranslationFakeCommunity = Struct.new(:rooms, :settings, :slug, :id, keyword_init: true) do
    def room_key_of(endpoint_id) = rooms.find { |r| r.include?(endpoint_id) }&.id

    def feature_enabled?(channel_or_key, feature)
      row(channel_or_key, feature)&.fetch(:enabled, false) || false
    end

    def feature_config(channel_or_key, feature) = row(channel_or_key, feature)&.fetch(:config, {}) || {}

    private

    def row(channel_or_key, feature) = settings[[room_key_of(channel_or_key) || channel_or_key.to_s, feature]]
  end

  # Records what the feature asked for instead of actually enqueueing it,
  # since the feature must never call LibreTranslate or an adapter itself.
  class RecordingRelay
    def initialize = @asked = []

    attr_reader :asked

    def enqueue_new(**spec)
      @asked << spec.merge(action: :new)
      "job-#{@asked.length}"
    end

    def enqueue_edit(**spec)
      @asked << spec.merge(action: :edit)
      "job-#{@asked.length}"
    end
  end

  let(:ep_en) { endpoint("en-room-ep", adapter: :telegram, account: "bot") }
  let(:ep_pt) { endpoint("pt-room-ep", adapter: :discord, account: "bot") }
  let(:ep_es) { endpoint("es-room-ep", adapter: :discord, account: "bot") }

  let(:room_en) { room("room-en", ep_en) }
  let(:room_pt) { room("room-pt", ep_pt) }
  let(:room_es) { room("room-es", ep_es) }

  let(:settings) do
    {
      ["room-en", "translation"] => { enabled: true, config: { language: "en", group: "welcome" } },
      ["room-pt", "translation"] => { enabled: true, config: { language: "pt", group: "welcome" } },
      ["room-es", "translation"] => { enabled: true, config: { language: "es", group: "welcome" } }
    }
  end

  let(:community) { TranslationFakeCommunity.new(rooms: [room_en, room_pt, room_es], settings: settings) }
  let(:relay) { RecordingRelay.new }
  let(:feature) { described_class.new(logger: Rubotty::Log.null, adapters: {}, relay: relay) }

  def context(message, community_override = community)
    Rubotty::Features::Context.new(message: message, community: community_override, config: {},
                                   logger: Rubotty::Log.null)
  end

  def chat(endpoint, text, native_id: "1", **rest)
    message(endpoint, text: text, native_id: native_id, **rest)
  end

  it "always continues, never halts, so the bridge still relays the original untouched" do
    outcome = feature.call(context(chat(ep_en, "hello")))

    expect(outcome).to be_continue
  end

  it "is inert with no relay behind it" do
    inert = described_class.new(logger: Rubotty::Log.null, relay: nil)

    inert.call(context(chat(ep_en, "hello")))
    # No error and, more to the point, no crash from ever touching @adapters;
    # there is nothing else observable to assert with no relay to record.
  end

  it "does nothing without a community, the config-only-file deployment shape" do
    feature.call(context(chat(ep_en, "hello"), nil))

    expect(relay.asked).to be_empty
  end

  describe "a two room group" do
    let(:community) { TranslationFakeCommunity.new(rooms: [room_en, room_pt], settings: settings) }

    it "queues one translation, into the other room's language" do
      feature.call(context(chat(ep_en, "hello", native_id: "m1")))

      expect(relay.asked.length).to eq(1)
      asked = relay.asked.first
      expect(asked[:action]).to eq(:new)
      expect(asked[:source_language]).to eq("en")
      expect(asked[:target_language]).to eq("pt")
      expect(asked[:target_room]).to eq(room_pt)
      expect(asked[:source_ref]).to eq(ref("en-room-ep", "m1"))
    end
  end

  describe "a three room group" do
    it "queues a translation into EVERY other room in the group, not just one" do
      feature.call(context(chat(ep_en, "hello")))

      targets = relay.asked.map { |spec| spec[:target_language] }
      expect(targets.sort).to eq(%w[es pt])
    end

    it "queues from whichever room originates, not only the first one configured" do
      feature.call(context(chat(ep_pt, "oi", native_id: "m2")))

      targets = relay.asked.map { |spec| spec[:target_language] }
      expect(targets.sort).to eq(%w[en es])
    end
  end

  describe "gating" do
    it "does nothing for a room with the feature off" do
      off = settings.merge(["room-en", "translation"] => { enabled: false, config: { language: "en", group: "welcome" } })
      feature.call(context(chat(ep_en, "hello"), TranslationFakeCommunity.new(rooms: community.rooms, settings: off)))

      expect(relay.asked).to be_empty
    end

    it "does nothing for a room with no language set" do
      no_language = settings.merge(["room-en", "translation"] => { enabled: true, config: { group: "welcome" } })
      feature.call(context(chat(ep_en, "hello"), TranslationFakeCommunity.new(rooms: community.rooms, settings: no_language)))

      expect(relay.asked).to be_empty
    end

    it "does nothing for a room with no group set" do
      no_group = settings.merge(["room-en", "translation"] => { enabled: true, config: { language: "en" } })
      feature.call(context(chat(ep_en, "hello"), TranslationFakeCommunity.new(rooms: community.rooms, settings: no_group)))

      expect(relay.asked).to be_empty
    end

    it "does not pair a room with one in a different group" do
      lonely = settings.merge(["room-pt", "translation"] => { enabled: true, config: { language: "pt", group: "other" } })
      feature.call(context(chat(ep_en, "hello"), TranslationFakeCommunity.new(rooms: community.rooms, settings: lonely)))

      targets = relay.asked.map { |spec| spec[:target_language] }
      expect(targets).to eq(["es"])
    end

    it "ignores a message with neither text nor an attachment" do
      feature.call(context(chat(ep_en, "")))

      expect(relay.asked).to be_empty
    end

    it "still queues a message that is only an attachment, with nothing to translate" do
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://example.com/x.jpg")
      feature.call(context(message(ep_en, text: "", native_id: "p1", attachments: [photo])))

      expect(relay.asked.length).to eq(2)
      expect(relay.asked.first[:attachments]).to eq([photo])
    end

    it "leaves a synthetic message (a slash-command interaction) alone" do
      feature.call(context(chat(ep_en, "hello", synthetic: true)))

      expect(relay.asked).to be_empty
    end
  end

  describe "attribution" do
    it "shows the original author, tagged with the origin platform, never the bot" do
      speaker = author(username: "ada", first_name: "Ada")
      feature.call(context(chat(ep_en, "hello", author: speaker)))

      label = relay.asked.first[:sender_label]
      expect(label).to be_a(Rubotty::Core::SenderLabel)
      rendered = label.to_s
      expect(rendered).to include("ada")
      expect(rendered).to include("telegram")
    end
  end

  describe "an edit" do
    it "queues a re-translation for the edited text" do
      feature.call(context(message(ep_en, kind: :edit, text: "hello again", native_id: "m1")))

      expect(relay.asked.length).to eq(1)
      asked = relay.asked.first
      expect(asked[:action]).to eq(:edit)
      expect(asked[:text]).to eq("hello again")
      expect(asked[:source_language]).to eq("en")
    end

    it "does nothing for a room outside any group" do
      lone = endpoint("lone", adapter: :telegram, account: "bot")
      solo_room = room("solo", lone)
      solo_community = TranslationFakeCommunity.new(rooms: [solo_room], settings: {})

      feature.call(context(message(lone, kind: :edit, text: "x", native_id: "m1"), solo_community))

      expect(relay.asked).to be_empty
    end
  end

  describe "redelivery" do
    let(:storage) { Rubotty::Storage::Memory.new }
    let(:feature) { described_class.new(logger: Rubotty::Log.null, adapters: {}, storage: storage, relay: relay) }

    it "queues a message's whole fan-out at most once, the same guarantee Bridge gives its own relay" do
      2.times { feature.call(context(chat(ep_en, "hello", native_id: "m1"))) }

      expect(relay.asked.length).to eq(2) # one job per peer, not per delivery
    end

    it "still queues a genuinely different message" do
      feature.call(context(chat(ep_en, "hello", native_id: "m1")))
      feature.call(context(chat(ep_en, "world", native_id: "m2")))

      expect(relay.asked.length).to eq(4)
    end

    it "queues a distinct edit again, but not the same edit redelivered" do
      2.times { feature.call(context(message(ep_en, kind: :edit, text: "hello again", native_id: "m1"))) }
      feature.call(context(message(ep_en, kind: :edit, text: "hello once more", native_id: "m1")))

      expect(relay.asked.count { |spec| spec[:action] == :edit }).to eq(2)
    end
  end
end
