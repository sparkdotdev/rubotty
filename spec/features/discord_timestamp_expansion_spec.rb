# frozen_string_literal: true

require "spec_helper"

# A Discord `<t:UNIX:FORMAT>` timestamp only Discord's own client resolves
# live, per viewer; relayed anywhere else it used to leak through as literal
# markup. Bridge#prepare now expands it against the per-scope
# `timestamp_timezones` field: unset gets DEFAULT_ZONES, an empty list gets nothing.
RSpec.describe "Discord timestamp expansion through the bridge", :control_plane do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:dc2) { endpoint("dc2", adapter: :discord) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }

  subject(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", tg, dc, dc2)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null
    )
  end

  let(:zones) do
    [
      { label: "Pacific", iana_timezone: "Etc/GMT+8" },
      { label: "Eastern", iana_timezone: "Etc/GMT+5" },
      { label: "India", iana_timezone: "Etc/GMT-4" }
    ]
  end

  # 20:00 UTC: noon in Pacific, 3PM Eastern, midnight the next day in India.
  let(:unix) { Time.utc(2026, 8, 12, 20, 0, 0).to_i }

  # #expand_timestamps reads the real Time.now for "today", not an injected one (a
  # live relay has no other honest answer), so the day label is pinned here rather
  # than left to whatever day the suite happens to run on.
  before { allow(Time).to receive(:now).and_return(Time.utc(2026, 8, 12, 10, 0, 0)) }

  def relay(text, origin: dc, timezones: zones)
    config = timezones.nil? ? {} : { timestamp_timezones: timezones }
    context = Rubotty::Features::Context.new(message: message(origin, text: text), community: nil, config: config)
    bridge.call(context)
  end

  def body_for(endpoint_id) = adapter.delivered_to(endpoint_id).last.body.text

  describe "expanding on a non-Discord target" do
    it "replaces the token with the day label and one reading per configured zone" do
      relay("start <t:#{unix}:t> ok")
      expect(body_for("tg")).to eq("start Today Noon Pacific, 3PM Eastern, Midnight India ok")
    end

    it "expands every one of Discord's format codes relayed through the bridge" do
      %w[t T d D f F R].each do |code|
        relay("<t:#{unix}:#{code}>")
        expect(body_for("tg")).to eq("Today Noon Pacific, 3PM Eastern, Midnight India")
      end
    end

    it "expands multiple tokens carried by the same message independently" do
      later = Time.utc(2026, 8, 14, 9, 0, 0).to_i
      relay("start <t:#{unix}:t>, then <t:#{later}:t>")
      expect(body_for("tg"))
        .to eq("start Today Noon Pacific, 3PM Eastern, Midnight India, " \
               "then Friday 1AM Pacific, 4AM Eastern, 1PM India")
    end
  end

  describe "leaving Discord targets untouched" do
    it "keeps the raw markup for a Discord-to-Discord relay in the same room" do
      relay("start <t:#{unix}:t> ok")
      expect(body_for("dc2")).to eq("start <t:#{unix}:t> ok")
    end
  end

  describe "a scope that never configured the key" do
    it "expands against the shipped default zones" do
      relay("start <t:#{unix}:t> ok", timezones: nil)
      expect(body_for("tg"))
        .to eq("start Today 1PM Pacific, 4PM Eastern, 9PM Western Europe, 10PM Central Europe ok")
    end

    it "still leaves a Discord target's markup alone" do
      relay("start <t:#{unix}:t> ok", timezones: nil)
      expect(body_for("dc2")).to eq("start <t:#{unix}:t> ok")
    end
  end

  describe "turning expansion off" do
    it "leaves the markup untouched when timestamp_timezones is explicitly an empty list" do
      relay("start <t:#{unix}:t> ok", timezones: [])
      expect(body_for("tg")).to eq("start <t:#{unix}:t> ok")
    end
  end

  describe "a message with no timestamp token" do
    it "is delivered completely unchanged" do
      relay("just an ordinary message, nothing to expand")
      expect(body_for("tg")).to eq("just an ordinary message, nothing to expand")
    end
  end
end
