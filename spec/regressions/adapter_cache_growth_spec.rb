# frozen_string_literal: true

require "spec_helper"

# Adapter-side caches live for the whole process, so a key that is only ever
# added is a slow leak on a bridge nobody restarts.
RSpec.describe "adapter caches" do
  include Builders

  describe Rubotty::Adapters::Matrix::Adapter do
    let(:client) { MatrixFakes::Client.new(displaynames: {}) }

    subject(:adapter) do
      described_class.new(
        account: "mx",
        settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
        dispatcher: Fakes::RecordingDispatcher.new,
        logger: Rubotty::Log.null,
        endpoints: [endpoint("mx-general", adapter: :matrix, settings: { room_id: "!room:example.org" })]
      ).replace_client(client).replace_sync(MatrixFakes::Sync.new)
    end

    def displayname_cache = adapter.send(:instance_variable_get, :@displayname_cache)

    it "caps the display-name cache a federated room can fill" do
      stub_const("#{described_class}::MAX_CACHED_DISPLAYNAMES", 8)

      30.times { |i| adapter.send(:resolve_displayname, "@user#{i}:example.org") }

      expect(displayname_cache.size).to be <= 8
    end

    it "still answers from the cache without asking the homeserver twice" do
      adapter.send(:resolve_displayname, "@ada:example.org")
      before = client.displayname_calls if client.respond_to?(:displayname_calls)

      adapter.send(:resolve_displayname, "@ada:example.org")

      expect(displayname_cache).to have_key("@ada:example.org")
      expect(client.displayname_calls).to eq(before) if client.respond_to?(:displayname_calls)
    end

    it "caps the reaction map, which only loses an entry when the reaction does" do
      stub_const("#{described_class}::MAX_TRACKED_REACTIONS", 4)
      reaction = Rubotty::Core::Reaction.new(emoji: "👍")

      20.times { |i| adapter.send(:remember_reaction, "!r:example.org", i.to_s, reaction, "$e#{i}") }

      expect(adapter.send(:instance_variable_get, :@reaction_events).size).to be <= 4
    end
  end

  # The map #redaction consults to recognise a reaction being taken back only loses an entry
  # when the reaction it names is removed, so a room where people react and never un-react
  # needs a cap of its own, the same way Adapter's own reaction cache does.
  describe Rubotty::Adapters::Matrix::Inbound do
    let(:place) { endpoint("mx", adapter: :matrix, settings: { room_id: "!r:example.org" }) }

    subject(:inbound) { described_class.new(endpoint_for: ->(_id) { place }) }

    def annotation_map = inbound.send(:instance_variable_get, :@annotations)

    def add_reaction(id)
      inbound.call(
        "!r:example.org",
        { "type" => "m.reaction", "event_id" => "$r#{id}", "sender" => "@ada:example.org",
          "content" => { "m.relates_to" => { "rel_type" => "m.annotation",
                                             "event_id" => "$m#{id}", "key" => "👍" } } }
      )
    end

    it "caps the remembered annotation map" do
      stub_const("#{described_class}::MAX_TRACKED_ANNOTATIONS", 4)

      20.times { |i| add_reaction(i) }

      expect(annotation_map.size).to be <= 4
    end

    it "loses an entry as soon as its reaction is redacted, ahead of the cap" do
      add_reaction(1)

      inbound.call("!r:example.org", { "type" => "m.room.redaction", "event_id" => "$x",
                                       "sender" => "@ada:example.org", "redacts" => "$r1" })

      expect(annotation_map).to be_empty
    end
  end

  describe Rubotty::Adapters::Guest::Adapter do
    let(:answers) { [true] }
    let(:invites) { Class.new { def live_on_room?(room_id:) = true }.new }
    let(:time_box) { [Time.now] }

    subject(:adapter) do
      described_class.new(
        dispatcher: Fakes::RecordingDispatcher.new, feed: Object.new, invites: invites,
        models: Object.new, registry: Object.new, logger: Rubotty::Log.null,
        clock: -> { time_box.first }
      )
    end

    def live_cache = adapter.send(:instance_variable_get, :@live_cache)

    it "forgets a room nobody has asked about for longer than the cache window" do
      50.times { |i| adapter.send(:live_guest?, i) }
      expect(live_cache.size).to eq(50)

      time_box[0] += described_class::LIVE_CACHE_SECONDS + 1
      adapter.send(:live_guest?, 999)

      expect(live_cache.keys).to eq([999])
    end

    it "still serves the cached answer inside the window" do
      expect(adapter.send(:live_guest?, 1)).to be(true)
      allow(invites).to receive(:live_on_room?).and_raise("must not be asked again")

      expect(adapter.send(:live_guest?, 1)).to be(true)
    end
  end
end
