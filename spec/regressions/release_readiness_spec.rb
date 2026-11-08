# frozen_string_literal: true

require "spec_helper"

RSpec.describe "release authorization and storage regressions", :control_plane do
  [Rubotty::Security::ProtectedOperators, Rubotty::Security::DashboardAdministrators,
   Rubotty::Security::DashboardViewers].each do |klass|
    %i[telegram discord].each do |adapter|
      it "uses configured #{adapter} ids instead of retained usernames for #{klass}" do
        floor = klass.new(usernames: ["owner"], matrix_ids: [], ids: { adapter.to_s => ["123"] })
        predicate = { Rubotty::Security::ProtectedOperators => :owner?,
                      Rubotty::Security::DashboardAdministrators => :administrator?,
                      Rubotty::Security::DashboardViewers => :viewer? }.fetch(klass)
        expect(floor.public_send(predicate, adapter: adapter, native_id: "456", username: "owner")).to be(false)
        expect(floor.public_send(predicate, adapter: adapter, username: "owner")).to be(false)
        expect(floor.public_send(predicate, adapter: adapter, native_id: "123", username: "renamed")).to be(true)
      end
    end
  end

  %w[all general].each do |scope|
    [["bridge", "cross_platform_mentions", false, true],
     ["backfill", "lookback_seconds", 7200, true],
     ["anti_spam", "flood_threshold", 5, false]].each do |feature, key, value, enabled|
      it "preserves #{feature}'s default #{enabled} on its first config write at #{scope} scope" do
        _db, models = seeded_sample
        controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
        community = controls.community!("sample")
        models.feature_setting.where(community_id: community.id, feature: feature).delete
        row = controls.set(community: community, selector: scope, feature: feature, key: key, value: value).first
        expect(row[:enabled]).to be(enabled)
      end
    end
  end

  it "preserves an explicit disabled community setting when creating a room override" do
    _db, models = seeded_sample
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    community = controls.community!("sample")
    controls.disable(community: community, selector: "all", feature: "bridge")
    row = controls.set(community: community, selector: "general", feature: "bridge",
                       key: "cross_platform_mentions", value: false).first
    expect(row[:enabled]).to be(false)
  end

  it "opens a literal SQLite path containing spaces, URI delimiters and Unicode" do
    directory = Dir.mktmpdir("rubotty path #?é")
    path = File.join(directory, "database #?.sqlite3")
    store = Rubotty::Storage::Factory.build({ driver: :sqlite, path: path })
    expect(File.file?(path)).to be(true)
    expect(store.describe).to include(path)
  ensure
    store&.close
    FileUtils.remove_entry(directory) if directory && File.directory?(directory)
  end
end
