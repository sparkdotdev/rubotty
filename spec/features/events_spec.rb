# frozen_string_literal: true

require "spec_helper"

# "events" is declared and dormant so the CLI and dashboard can configure it per room. It
# observes no message kind and never runs in the pipeline.
RSpec.describe Rubotty::Features::Events do
  it "is dormant by default, so no room schedules events until an operator enables it" do
    expect(described_class.default_enabled?).to be(false)
  end

  it "declares the stable feature key used in feature_settings" do
    expect(described_class.feature_name).to eq("events")
  end

  it "observes no message kind: a flag, not a pipeline step" do
    expect(described_class.observes).to eq([])
  end

  it "is registered in the catalog so the admin CLI recognises and resolves it" do
    expect(Rubotty::Features::Catalog.known?("events")).to be(true)
    expect(Rubotty::Features::Catalog.class_for("events")).to eq(described_class)
  end

  describe "config schema" do
    subject(:schema) { described_class.config_schema }

    it "is a real schema" do
      expect(schema).to be_a(Rubotty::Config::Schema)
    end

    it "defaults who_can_create to operators and accepts only operators or everyone" do
      result = schema.call({})
      expect(result).to be_valid
      expect(result.value[:who_can_create]).to eq("operators")

      accepted = schema.call({ who_can_create: "everyone" })
      expect(accepted).to be_valid
      expect(accepted.value[:who_can_create]).to eq("everyone")

      rejected = schema.call({ who_can_create: "nobody" })
      expect(rejected).not_to be_valid
    end

    it "defaults default_reminder_intervals to issue #184's ladder, seconds before starts_at" do
      result = schema.call({})
      expect(result.value[:default_reminder_intervals]).to eq(
        [604_800, 259_200, 172_800, 86_400, 43_200, 21_600, 10_800, 7_200, 3_600, 1_800, 900]
      )
    end

    it "accepts an explicit override of the reminder ladder" do
      result = schema.call({ default_reminder_intervals: [3600, 900] })
      expect(result).to be_valid
      expect(result.value[:default_reminder_intervals]).to eq([3600, 900])
    end
  end

  describe "WHO_CAN_CREATE" do
    it "lists exactly operators and everyone, matching guest_portal's who_can_invite shape" do
      expect(described_class::WHO_CAN_CREATE).to eq(%w[operators everyone])
    end
  end
end
