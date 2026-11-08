# frozen_string_literal: true

require "spec_helper"

# The switch itself. Copying a member's profile picture onto rubotty's own disk
# is a decision for whoever runs the community, so the default and the wording an
# operator reads before ticking it are worth asserting.
RSpec.describe Rubotty::Features::TelegramAvatars do
  it "is off until an administrator turns it on" do
    expect(described_class.default_enabled?).to be(false)
  end

  it "is in the catalog under a stable key" do
    expect(described_class.feature_name).to eq("telegram_avatars")
    expect(Rubotty::Features::Catalog.class_for("telegram_avatars")).to eq(described_class)
  end

  # Nothing in the pipeline runs it: the Telegram adapter asks the snapshot itself.
  it "observes nothing" do
    expect(described_class.observes).to be_empty
  end

  describe "retention" do
    # A face is not something the person chose to post, so a copied photo keeps
    # the shorter default rather than the year a rehosted file now gets.
    it "defaults to its own retention, shorter than a rehosted file's" do
      expect(described_class.retention_days({}))
        .to eq(Rubotty::ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS)
      expect(Rubotty::ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS)
        .to be < Rubotty::ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS
    end

    it "reads a community's own setting, string keyed from the database or symbol keyed in code" do
      expect(described_class.retention_days({ "retention_days" => 7 })).to eq(7)
      expect(described_class.retention_days({ retention_days: 7 })).to eq(7)
    end

    it "declares the field so the dashboard has something to edit" do
      expect(described_class.config_schema.fields.keys).to include(:retention_days)
    end
  end

  describe "the notice an operator reads before switching it on" do
    subject(:notice) { described_class.retention_notice }

    it "says what starts being kept" do
      expect(notice).to include("PROFILE PHOTO")
      expect(notice).to include("rubotty's own disk")
    end

    it "says how long, in the numbers the retention really runs at" do
      expect(notice).to include("#{Rubotty::ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS} days")
      expect(notice).to include(Rubotty::ControlPlane::RehostedFiles::MAX_TTL_DAYS.to_s)
    end

    it "says who can reach a copy, and what switching it back off does" do
      expect(notice).to include("no account and no membership check")
      expect(notice).to include("Switching the feature off")
    end

    # #1419: a Telegram-only room has nowhere to puppet the sender, so the
    # notice says plainly that turning this on there costs something for
    # nothing, in addition to the adapter's own gate that skips the fetch.
    it "says this only does something once a second platform puppets the room" do
      expect(notice).to include("second platform")
    end
  end
end
