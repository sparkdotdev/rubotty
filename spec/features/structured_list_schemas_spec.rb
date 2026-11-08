# frozen_string_literal: true

require "spec_helper"

RSpec.describe "structured feature list schemas" do
  def field_for(feature, name)
    feature.config_schema.fields.fetch(name)
  end

  it "validates timestamp pairs before the bridge reads them" do
    schema = Rubotty::Features::Bridge.config_schema

    expect(schema.call({ timestamp_timezones: [{ label: "Lisbon", iana_timezone: "Europe/Lisbon" }] })).to be_valid
    result = schema.call({ timestamp_timezones: [{ label: "Lisbon", zone: "Europe/Lisbon" }] })
    expect(result.problems).to include("timestamp_timezones[0].iana_timezone: is required")
    expect(result.problems).to include("timestamp_timezones[0].zone: unknown key")
  end

  it "rejects a malformed warning rung instead of leaving it for the runtime to drop" do
    schema = Rubotty::Features::Warnings.config_schema

    expect(schema.call({ ladder: [{ threshold: 2, action: "mute", duration: "1h" }] })).to be_valid
    result = schema.call({ ladder: [{ threshold: 0, action: "pause", unknown: true }] })
    expect(result.problems).to include("ladder[0].threshold: must be positive")
    expect(result.problems).to include("ladder[0].action: must be one of mute, ban, kick, got \"pause\"")
    expect(result.problems).to include("ladder[0].unknown: unknown key")
  end

  it "checks announcement rows, including their endpoint list" do
    schema = Rubotty::Features::ScheduledAnnouncements.config_schema

    expect(schema.call({ announcements: [{ text: "Game night", channels: ["discord-general"], every: "1d" }] })).to be_valid
    result = schema.call({ announcements: [{ text: "Game night", channels: [], when: "tomorrow" }] })
    expect(result.problems).to include("announcements[0].channels: must name at least one endpoint")
    expect(result.problems).to include("announcements[0].when: unknown key")
  end

  it "declares the platform join-link fields the editor and loader share" do
    schema = Rubotty::Features::UtilityCommands.config_schema

    expect(schema.call({ platforms: [{ platform: "discord", label: "Discord", url: "https://example.test/invite" }] })).to be_valid
    result = schema.call({ platforms: [{ platform: "discord", href: "https://example.test/invite" }] })
    expect(result.problems).to include("platforms[0].url: is required")
    expect(result.problems).to include("platforms[0].href: unknown key")
  end

  it "keeps a word-filter word shorthand while validating mapped rules" do
    schema = Rubotty::Features::WordFilter.config_schema
    field = field_for(Rubotty::Features::WordFilter, :entries)

    expect(field.variants).to include(:string)
    expect(schema.call({ entries: ["badger", { pattern: "mushroom", action: "warn" }] })).to be_valid
    result = schema.call({ entries: [{ pattern: "mushroom", action: "explode" }] })
    expect(result.problems).to include("entries[0].action: must be one of delete, flag, warn, mute, got \"explode\"")
  end
end
