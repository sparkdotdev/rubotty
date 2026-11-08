# frozen_string_literal: true

require "spec_helper"

# "channel_management" is declared and dormant so an operator opts a community into the
# dashboard's create and delete room controls. The real work is ControlPlane::RoomProvisioning.
RSpec.describe Rubotty::Features::ChannelManagement do
  it "is dormant by default, so no community shows channel management controls until an operator enables it" do
    expect(described_class.default_enabled?).to be(false)
  end

  it "declares the stable feature key used in feature_settings" do
    expect(described_class.feature_name).to eq("channel_management")
  end

  it "observes no message kind: a flag, not a pipeline step" do
    expect(described_class.observes).to eq([])
  end

  it "declares no per-scope config schema" do
    expect(described_class.config_schema).to be_nil
  end

  it "is registered in the catalog so the admin CLI and dashboard recognise and resolve it" do
    expect(Rubotty::Features::Catalog.known?("channel_management")).to be(true)
    expect(Rubotty::Features::Catalog.class_for("channel_management")).to eq(described_class)
  end
end
