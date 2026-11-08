# frozen_string_literal: true

require "spec_helper"

# What the dashboard's Platforms page drives to add, edit, list and remove a
# community's Fluxer connections.
RSpec.describe Rubotty::ControlPlane::FluxerInstances, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  let(:community) do
    models.community.create(slug: "sample", name: "SAMPLE", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end
  let(:other_community) do
    models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  subject(:instances) { described_class.new(models: models, clock: -> { now }) }

  describe "#create" do
    it "creates a flagship instance from an api key env var alone" do
      row = instances.create(community: community, label: "Flagship", kind: "flagship",
                              endpoint_url: nil, api_key_env: "FLUXER_FLAGSHIP_API_KEY")
      expect(row.kind).to eq("flagship")
      expect(row.endpoint_url).to be_nil
      expect(row.api_key_env).to eq("FLUXER_FLAGSHIP_API_KEY")
    end

    it "creates a self-hosted instance carrying its endpoint URL" do
      row = instances.create(community: community, label: "Our server", kind: "self_hosted",
                              endpoint_url: "https://fluxer.example.org", api_key_env: "FLUXER_SELF_API_KEY")
      expect(row.kind).to eq("self_hosted")
      expect(row.endpoint_url).to eq("https://fluxer.example.org")
    end

    it "defaults kind to self_hosted, matching the column's own default" do
      row = instances.create(community: community, label: "Our server", kind: nil,
                              endpoint_url: "https://fluxer.example.org", api_key_env: "FLUXER_API_KEY")
      expect(row.kind).to eq("self_hosted")
    end

    it "clears a stray endpoint_url submitted alongside kind flagship rather than storing it" do
      row = instances.create(community: community, label: "Flagship", kind: "flagship",
                              endpoint_url: "https://fluxer.example.org", api_key_env: "FLUXER_API_KEY")
      expect(row.endpoint_url).to be_nil
    end

    it "rejects a blank label" do
      expect do
        instances.create(community: community, label: "  ", kind: "flagship",
                          endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      end.to raise_error(described_class::Invalid, /label/)
    end

    it "rejects a blank api_key_env" do
      expect do
        instances.create(community: community, label: "Flagship", kind: "flagship",
                          endpoint_url: nil, api_key_env: "  ")
      end.to raise_error(described_class::Invalid, /api_key_env/)
    end

    it "rejects an unknown kind" do
      expect do
        instances.create(community: community, label: "Weird", kind: "bogus",
                          endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      end.to raise_error(described_class::Invalid, /must be one of/)
    end

    it "rejects a self-hosted instance with no endpoint_url" do
      expect do
        instances.create(community: community, label: "Our server", kind: "self_hosted",
                          endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      end.to raise_error(described_class::Invalid, /endpoint_url/)
    end

    it "rejects a self-hosted instance whose endpoint_url is not an http(s) URL" do
      expect do
        instances.create(community: community, label: "Our server", kind: "self_hosted",
                          endpoint_url: "not a url", api_key_env: "FLUXER_API_KEY")
      end.to raise_error(described_class::Invalid, /endpoint_url/)
    end

    it "accepts a self-hosted endpoint_url on a nonstandard port and path" do
      row = instances.create(community: community, label: "Our server", kind: "self_hosted",
                              endpoint_url: "http://10.0.0.5:8443/api", api_key_env: "FLUXER_API_KEY")
      expect(row.endpoint_url).to eq("http://10.0.0.5:8443/api")
    end

    it "rejects two instances with the same label in one community" do
      instances.create(community: community, label: "Flagship", kind: "flagship",
                        endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      expect do
        instances.create(community: community, label: "Flagship", kind: "flagship",
                          endpoint_url: nil, api_key_env: "FLUXER_API_KEY_2")
      end.to raise_error(described_class::Invalid, /already exists/)
    end

    it "allows the same label across two different communities" do
      instances.create(community: community, label: "Flagship", kind: "flagship",
                        endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      expect do
        instances.create(community: other_community, label: "Flagship", kind: "flagship",
                          endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      end.not_to raise_error
    end

    it "reports every problem in one pass rather than only the first" do
      expect do
        instances.create(community: community, label: "  ", kind: "flagship", endpoint_url: nil, api_key_env: "  ")
      end.to raise_error(described_class::Invalid) { |error| expect(error.message).to match(/label.*api_key_env|api_key_env.*label/) }
    end
  end

  describe "#update" do
    let!(:row) do
      instances.create(community: community, label: "Flagship", kind: "flagship",
                        endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
    end

    it "switches an existing instance from flagship to self-hosted" do
      updated = instances.update(instance: row, label: "Our server", kind: "self_hosted",
                                 endpoint_url: "https://fluxer.example.org", api_key_env: "FLUXER_API_KEY")
      expect(updated.kind).to eq("self_hosted")
      expect(updated.endpoint_url).to eq("https://fluxer.example.org")
    end

    it "switches an existing instance from self-hosted back to flagship, dropping the endpoint" do
      instances.update(instance: row, label: "Our server", kind: "self_hosted",
                       endpoint_url: "https://fluxer.example.org", api_key_env: "FLUXER_API_KEY")
      updated = instances.update(instance: row.refresh, label: "Flagship again", kind: "flagship",
                                 endpoint_url: "https://fluxer.example.org", api_key_env: "FLUXER_API_KEY")
      expect(updated.kind).to eq("flagship")
      expect(updated.endpoint_url).to be_nil
    end

    it "leaves the row unchanged when the edit is invalid" do
      expect do
        instances.update(instance: row, label: "", kind: "flagship", endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      end.to raise_error(described_class::Invalid)
      expect(row.refresh.label).to eq("Flagship")
    end
  end

  describe "#list" do
    it "lists only the calling community's instances, flagship first then by label" do
      instances.create(community: community, label: "Zeta server", kind: "self_hosted",
                        endpoint_url: "https://z.example.org", api_key_env: "FLUXER_Z")
      instances.create(community: community, label: "Flagship", kind: "flagship",
                        endpoint_url: nil, api_key_env: "FLUXER_FLAGSHIP")
      instances.create(community: other_community, label: "Not mine", kind: "flagship",
                        endpoint_url: nil, api_key_env: "FLUXER_OTHER")

      expect(instances.list(community: community).map(&:label)).to eq(%w[Flagship Zeta\ server])
    end
  end

  describe "#remove" do
    it "removes an instance and returns true" do
      row = instances.create(community: community, label: "Flagship", kind: "flagship",
                              endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      expect(instances.remove(community: community, id: row.id)).to be(true)
      expect(models.fluxer_instance[row.id]).to be_nil
    end

    it "returns false and removes nothing for an id from a different community" do
      row = instances.create(community: community, label: "Flagship", kind: "flagship",
                              endpoint_url: nil, api_key_env: "FLUXER_API_KEY")
      expect(instances.remove(community: other_community, id: row.id)).to be(false)
      expect(models.fluxer_instance[row.id]).not_to be_nil
    end

    it "returns false for an unknown id" do
      expect(instances.remove(community: community, id: 999_999)).to be(false)
    end
  end
end
