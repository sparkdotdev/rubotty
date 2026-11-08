# frozen_string_literal: true

require "spec_helper"

# What the router actually serves a script. The catalog, the editor's
# autocomplete and the smoke test all agreed on thirty one functions while
# the router registered a subset, so a script calling one of the others
# passed the save time gate and failed on its first real message.
RSpec.describe Rubotty::Core::Router, "the registry a script gets" do
  let(:context) { Struct.new(:community, :channel).new(nil, nil) }

  # Built without services on purpose: what is left is everything that should
  # be available to every script on every deployment.
  def registry_without_services
    described_class.allocate.send(:script_registry_builder, logger: Rubotty::Log.null)
                   .call(context, nil)
  end

  # Anything needing a service is absent when that service is missing, which is
  # deliberate: calling it is then an ordinary Lua error rather than a stub that
  # quietly does nothing.
  NEEDS_A_SERVICE = %w[notify alert warn async_http schedule unschedule
                       remember recall forget add move top keys entries count_keys
                       increment_stat record_stat community_stats
                       post edit delete react whisper
                       participant resolve_participant mention_participant name_participants
                       session open_session close_session round open_round close_round].freeze

  it "serves every catalog function that needs no service at all" do
    served = registry_without_services.names
    expected = Rubotty::Scripting::HostFunctions.callable_names - NEEDS_A_SERVICE

    expect(expected - served).to be_empty
  end

  it "registers nothing the catalog does not declare" do
    served = registry_without_services.names

    expect(served - Rubotty::Scripting::HostFunctions::CATALOG.keys).to be_empty
  end

  # A getter is answered inside the Lua child out of the payload it was already
  # sent, so registering one here would put the same name in the sandbox
  # twice and send a frame down the pipe for something the child had.
  it "registers no getter, however the catalog grows" do
    served = registry_without_services.names

    expect(served & Rubotty::Scripting::HostFunctions.getter_names).to be_empty
  end

  # Styling needs nothing behind it, which is precisely why it was the set that
  # got left out of the router's hash.
  it "serves the styling helpers, which need nothing behind them" do
    served = registry_without_services.names

    expect(served).to include("bold", "italic", "underline", "strikethrough", "spoiler",
                              "code", "pre", "blockquote", "format", "mention")
  end

  describe "turning a script's answer into something a room can render" do
    def body(text) = described_class.allocate.send(:script_body, text)

    it "leaves a plain answer plain, without parsing it" do
      rendered = body("just words")

      expect(rendered.text).to eq("just words")
      expect(rendered.spans).to be_empty
    end

    # Without this the private use characters reach the chat window as
    # themselves, which is what happened while nothing called to_rich_text.
    it "turns the sentinels into spans rather than posting them" do
      styled = Rubotty::Scripting::Markup.wrap("bold", "careful")
      rendered = body(styled)

      expect(rendered.text).to eq("careful")
      expect(rendered.spans.map(&:kind)).to eq([:bold])
    end

    it "carries the handle on a mention, so the bridge can resolve it" do
      rendered = body(Rubotty::Scripting::Markup.mention("ada"))

      expect(rendered.text).to eq("@ada")
      expect(rendered.spans.first.attributes[:username]).to eq("ada")
    end
  end
end

# truncate measured the whole community's platforms, so a single IRC room
# anywhere cut every other room's replies to IRC's limit.
RSpec.describe "Rubotty::Core::Router truncate scope" do
  let(:discord) { endpoint("dc-general", adapter: :discord, settings: { room_key: "general" }) }
  let(:irc) { endpoint("irc-ops", adapter: :irc, settings: { room_key: "ops" }) }

  # Two rooms, one Discord and one IRC, in one community.
  let(:community) do
    rooms = [room("general", discord), room("ops", irc)]
    Class.new do
      def initialize(rooms) = @rooms = rooms

      attr_reader :rooms

      def feature_config(*) = {}

      def feature_enabled?(*) = true

      def room_key_of(channel)
        @rooms.find { |r| r.endpoints.any? { |e| e.id == channel.to_s } }&.id
      end
    end.new(rooms)
  end

  def truncate_in(room_key, text)
    router = Rubotty::Core::Router.allocate
    router.send(:script_room_platforms, community, room_key)
       .then { |platforms| Rubotty::Scripting::Markup.truncate(text, platforms) }
  end

  it "uses the Discord limit in the Discord room" do
    long = "x" * 1200

    expect(truncate_in("general", long).length).to be > 500
  end

  it "uses the IRC limit in the IRC room" do
    long = "x" * 1200

    expect(truncate_in("ops", long).length).to be <= 400
  end
end

# community_stats used to filter Analytics#overview's TOP level for Numeric,
# and every top level value there is a section hash or a Time, so it answered
# an empty table for every community while looking like it worked.
RSpec.describe "Rubotty::Core::Router community_stats", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:analytics) { Rubotty::ControlPlane::Analytics.new(db: db, models: models) }

  def stats
    Rubotty::Core::Router.allocate.send(:script_community_stats_handler, analytics, community).call
  end

  it "answers with real numbers rather than an empty table" do
    expect(stats).not_to be_empty
    expect(stats["members_total"]).to be_a(Numeric)
  end

  it "keeps only numbers, so nothing awkward crosses into Lua" do
    expect(stats.values).to all(be_a(Numeric))
  end

  it "names them by section, so two sections cannot collide on a key" do
    expect(stats.keys).to all(include("_"))
  end
end
