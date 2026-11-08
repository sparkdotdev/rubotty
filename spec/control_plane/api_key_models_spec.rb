# frozen_string_literal: true

require "spec_helper"

# The community.api_keys association and the community_id cascade, where a
# global administrator key has to survive what a developer key does not.
RSpec.describe Rubotty::ControlPlane::Models, "api_keys", :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  let(:community) do
    models.community.create(slug: "sample", name: "SAMPLE", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  let!(:developer_key) do
    models.api_key.create(
      public_id: "11111111-1111-1111-1111-111111111111", key_hash: "a" * 64,
      scope: "developer", community_id: community.id, label: "Discord relay bot",
      created_at: now, updated_at: now
    )
  end
  let!(:admin_key) do
    models.api_key.create(
      public_id: "22222222-2222-2222-2222-222222222222", key_hash: "b" * 64,
      scope: "administrator", community_id: nil, label: "CI bot",
      created_at: now, updated_at: now
    )
  end

  it "is reachable from its community, mirroring community.channels" do
    expect(community.api_keys.map(&:label)).to eq(["Discord relay bot"])
  end

  it "does not surface a global administrator key on any community" do
    expect(community.api_keys.map(&:public_id)).not_to include(admin_key.public_id)
  end

  it "points a developer key back to its community" do
    expect(developer_key.community.slug).to eq("sample")
  end

  it "leaves an administrator key with no community" do
    expect(admin_key.community_id).to be_nil
    expect(admin_key.community).to be_nil
  end

  it "removes a community's developer keys when the community is destroyed" do
    community.destroy
    expect(models.api_key.where(id: developer_key.id).count).to eq(0)
  end

  it "leaves a global administrator key untouched by a community's destruction" do
    community.destroy
    expect(models.api_key.where(id: admin_key.id).count).to eq(1)
  end
end
