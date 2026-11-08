# frozen_string_literal: true

require "spec_helper"

# Who an operator alert for one community is addressed to. Two audiences, and
# the second is the one that used to go missing: the granted operator rows,
# and the deployment-configured floor, which holds no row anywhere and so contributed
# nobody to any alert at all.
RSpec.describe Rubotty::ControlPlane::OperatorAudience, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }

  # The fixture's operator is "sample_owner", a handle the shipped floor
  # protects, so one person stands for both audiences unless the grant is
  # taken away or the floor is narrowed under it.
  subject(:audience) { described_class.new(models: models) }

  def nobody_protected
    Rubotty::Security::ProtectedOperators.new(usernames: ["someone_else"], matrix_ids: [])
  end

  def observe(adapter:, native_id:, username:)
    models.observed_identity.create(
      community_id: community.id, adapter: adapter, native_id: native_id, username: username,
      display_name: username, first_seen_at: Time.now, last_seen_at: Time.now
    )
  end

  describe "#identity_rows" do
    it "carries every platform this community's granted operator is linked on" do
      rows = audience.identity_rows(community.id)

      expect(rows.map(&:adapter)).to contain_exactly("telegram", "discord")
    end

    it "still carries a deployment-configured owner once their grant is taken away" do
      models.operator.where(community_id: community.id).delete

      rows = audience.identity_rows(community.id)
      expect(rows.map(&:adapter)).to eq(["telegram"])
      expect(rows.first.username).to eq("sample_owner")
    end

    # The same row reached by both routes is one operator, not two DMs.
    it "carries a row once when the same person is granted and baked in" do
      rows = audience.identity_rows(community.id)

      expect(rows.map(&:id).uniq.length).to eq(rows.length)
    end

    it "is empty with no grant and a floor that protects nobody here" do
      models.operator.where(community_id: community.id).delete
      narrowed = described_class.new(models: models, protected_operators: nobody_protected)

      expect(narrowed.identity_rows(community.id)).to be_empty
    end

    it "never reads another community's rows, or answers for no community" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)

      expect(audience.identity_rows(other.id)).to be_empty
      expect(audience.identity_rows(nil)).to be_empty
    end
  end

  describe "#sighting_rows" do
    it "finds a floor owner nothing has linked to a person" do
      observe(adapter: "telegram", native_id: "77123", username: "maintainer")

      expect(audience.sighting_rows(community.id).map(&:native_id)).to eq(["77123"])
    end

    # The floor grants on a handle the platform issues, never on a display
    # name and never on somebody who merely spoke here.
    it "ignores a sighting of somebody the floor does not protect" do
      observe(adapter: "telegram", native_id: "77123", username: "random_user")

      expect(audience.sighting_rows(community.id)).to be_empty
    end

    # A bare handle is only owned on the platforms that issue one, which is
    # the whole reason HandleFloor refuses to match anywhere else.
    it "ignores a protected handle on a platform that does not issue handles" do
      observe(adapter: "irc", native_id: "maintainer", username: "maintainer")

      expect(audience.sighting_rows(community.id)).to be_empty
    end

    it "is empty for a floor that protects nobody here" do
      observe(adapter: "telegram", native_id: "77123", username: "maintainer")
      narrowed = described_class.new(models: models, protected_operators: nobody_protected)

      expect(narrowed.sighting_rows(community.id)).to be_empty
    end
  end
end
