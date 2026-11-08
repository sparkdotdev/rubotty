# frozen_string_literal: true

require "spec_helper"

# The one renderer every bridge-authored card writes an instant through.
RSpec.describe Rubotty::Rendering::CardTimestamps, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:moment) { Time.utc(2026, 8, 13, 18, 0, 0) }

  # moment is fixed 3 days ahead of this, safely inside the 2-6-day-out
  # "bare weekday name" window TimestampExpansion.render uses (0 is Today,
  # 1 is Tomorrow). Without pinning the clock, the expected "Thursday" below
  # silently becomes "Tomorrow" or "Today" once the real clock catches up.
  let(:pinned) { Time.utc(2026, 8, 10, 12, 0, 0) }

  subject(:timestamps) do
    described_class.new(registry: registry, logger: Rubotty::Log.null, clock: -> { pinned })
  end

  def adapter_for(name)
    Class.new do
      def initialize(name) = @name = name

      attr_reader :name

      def adapter_name = @name

      def render_timestamp(time, style: :full, tz: "UTC", now: nil)
        "fixed:#{time.to_i}:#{style}:#{tz}:#{now.to_i}"
      end
    end.new(name)
  end

  def discord_adapter
    Class.new do
      def adapter_name = :discord

      def render_timestamp(time, style: :full, tz: nil, now: nil)
        style.to_sym == :both ? "<t:#{time.to_i}:F> <t:#{time.to_i}:R>" : "<t:#{time.to_i}:F>"
      end
    end.new
  end

  def endpoint_named(id) = registry.current.channel_by_endpoint_key(id).endpoint

  def configure_zones!(*pairs)
    controls.set(
      community: registry.current.community("sample"), selector: "gaming", feature: "bridge",
      key: "timestamp_timezones", value: pairs
    )
  end

  # An explicitly stored empty list, which is how a room says it wants the
  # fixed zone and no expansion at all.
  def disable_zones! = configure_zones!

  def render(adapter, endpoint_id)
    timestamps.render(
      moment, adapter: adapter, endpoint: endpoint_named(endpoint_id),
      community_id: community.id, tz: "Europe/Lisbon", style: :both
    )
  end

  it "keeps Discord's own markup, which only its client can resolve per viewer" do
    configure_zones!(label: "Pacific", iana_timezone: "America/Los_Angeles")

    expect(render(discord_adapter, "dc-gaming")).to eq("<t:#{moment.to_i}:F> <t:#{moment.to_i}:R>")
  end

  it "keeps Discord's own markup in a room that configured no zones either" do
    expect(render(discord_adapter, "dc-gaming")).to eq("<t:#{moment.to_i}:F> <t:#{moment.to_i}:R>")
  end

  it "renders the room's configured zones everywhere else" do
    configure_zones!({ label: "Pacific", iana_timezone: "America/Los_Angeles" },
                     { label: "Lisbon", iana_timezone: "Europe/Lisbon" })

    expect(render(adapter_for(:telegram), "tg-gaming")).to eq("Thursday 11AM Pacific, 7PM Lisbon")
  end

  it "renders the shipped default zones in a room that configured none" do
    expect(render(adapter_for(:telegram), "tg-gaming"))
      .to eq("Thursday 11AM Pacific, 2PM Eastern, 7PM Western Europe, 8PM Central Europe")
  end

  it "leads the day label with Pacific, the first default pair, in a room that configured none" do
    # 11PM UTC on the 13th is still the afternoon of the 13th in Pacific, so a
    # home zone read further east would label this one day later.
    late = Time.utc(2026, 8, 13, 23, 0, 0)
    rendered = timestamps.render(
      late, adapter: adapter_for(:telegram), endpoint: endpoint_named("tg-gaming"),
      community_id: community.id, tz: "Europe/Lisbon", style: :both
    )

    expect(rendered).to eq("Thursday 4PM Pacific, 7PM Eastern, Midnight Western Europe, 1AM Central Europe")
  end

  it "renders the fixed zone in a room that stored an empty list to turn expansion off" do
    disable_zones!

    expect(render(adapter_for(:telegram), "tg-gaming"))
      .to eq("fixed:#{moment.to_i}:both:Europe/Lisbon:#{pinned.to_i}")
  end

  it "keeps a room's own zones rather than adding the defaults to them" do
    configure_zones!({ label: "Lisbon", iana_timezone: "Europe/Lisbon" })

    expect(render(adapter_for(:telegram), "tg-gaming")).to eq("Thursday 7PM Lisbon")
  end

  # The adapter counts down from whatever instant it is handed, so a caller
  # holding its own clock gets a countdown that agrees with its own text.
  it "hands the adapter the clock's instant rather than letting it read the wall clock" do
    disable_zones!
    later = described_class.new(registry: registry, logger: Rubotty::Log.null,
                                clock: -> { pinned + 86_400 })
    rendered = later.render(
      moment, adapter: adapter_for(:telegram), endpoint: endpoint_named("tg-gaming"),
      community_id: community.id, tz: "UTC", style: :relative
    )

    expect(rendered).to eq("fixed:#{moment.to_i}:relative:UTC:#{(pinned + 86_400).to_i}")
  end

  it "falls back the same way without a control plane to read a room's config from" do
    bare = described_class.new(registry: nil, logger: Rubotty::Log.null, clock: -> { pinned })
    rendered = bare.render(
      moment, adapter: adapter_for(:telegram), endpoint: endpoint_named("tg-gaming"),
      community_id: community.id, tz: "UTC", style: :full
    )

    expect(rendered).to eq("fixed:#{moment.to_i}:full:UTC:#{pinned.to_i}")
  end
end
