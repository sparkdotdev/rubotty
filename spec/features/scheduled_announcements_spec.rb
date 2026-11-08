# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::ScheduledAnnouncements do
  it "names itself with the scheduler's feature key and is off by default" do
    expect(described_class.feature_name).to eq("scheduled_announcements")
    expect(described_class.feature_name).to eq(Rubotty::Core::AnnouncementScheduler::FEATURE)
    expect(described_class.default_enabled?).to be(false)
  end

  it "observes no message kind: it is clock-driven, not part of the pipeline" do
    expect(described_class.observes).to eq([])
  end

  it "publishes a config schema for the dashboard and CLI to validate against" do
    schema = described_class.config_schema
    expect(schema).to be_a(Rubotty::Config::Schema)
    result = schema.call({ announcements: [] })
    expect(result).to be_valid
  end

  it "is registered in the catalog so an operator can enable and configure it" do
    expect(Rubotty::Features::Catalog.known?("scheduled_announcements")).to be(true)
    expect(Rubotty::Features::Catalog.class_for("scheduled_announcements")).to eq(described_class)
  end

  it "continues if it were ever run, though the pipeline never invokes it" do
    expect(described_class.new.call(nil)).to be_continue
  end
end
