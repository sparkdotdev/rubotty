# frozen_string_literal: true

require "spec_helper"

# The data and config layer only: no adapter reads these rows yet.
RSpec.describe Rubotty::ControlPlane::Models, "irc_networks and fluxer_instances", :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  let(:community) do
    models.community.create(slug: "sample", name: "SAMPLE", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  describe "irc_networks" do
    let!(:network) do
      models.irc_network.create(
        community_id: community.id, name: "libera", host: "irc.libera.chat", port: 6697,
        tls: true, nick: "rubotty", sasl_user: "rubotty",
        sasl_password_env: "IRC_LIBERA_SASL_PASSWORD",
        channels: Rubotty::ControlPlane::Models.dump_json(%w[#general #offtopic]),
        created_at: now, updated_at: now
      )
    end

    it "is reachable from its community, mirroring community.channels" do
      expect(community.irc_networks.map(&:name)).to eq(["libera"])
    end

    it "points back to its community" do
      expect(network.community.slug).to eq("sample")
    end

    it "reads the channels-to-join blob back as a Ruby array" do
      expect(network.json_value(:channels)).to eq(%w[#general #offtopic])
    end

    it "references the SASL secret by env var name, never a raw password" do
      expect(network.sasl_password_env).to eq("IRC_LIBERA_SASL_PASSWORD")
      expect(network.respond_to?(:sasl_password)).to be(false)
    end

    it "is removed when its community is destroyed" do
      community.destroy
      expect(models.irc_network.count).to eq(0)
    end
  end

  describe "fluxer_instances" do
    let!(:flagship) do
      models.fluxer_instance.create(
        community_id: community.id, label: "Flagship", kind: "flagship",
        api_key_env: "FLUXER_FLAGSHIP_API_KEY", created_at: now, updated_at: now
      )
    end
    let!(:self_hosted) do
      models.fluxer_instance.create(
        community_id: community.id, label: "Our server", kind: "self_hosted",
        endpoint_url: "https://fluxer.example.org", api_key_env: "FLUXER_SELF_HOSTED_API_KEY",
        created_at: now, updated_at: now
      )
    end

    it "is reachable from its community, mirroring community.channels" do
      expect(community.fluxer_instances.map(&:label)).to contain_exactly("Flagship", "Our server")
    end

    it "points back to its community" do
      expect(flagship.community.slug).to eq("sample")
    end

    it "leaves endpoint_url nil for the flagship instance" do
      expect(flagship.endpoint_url).to be_nil
    end

    it "carries an endpoint_url for a self-hosted instance" do
      expect(self_hosted.endpoint_url).to eq("https://fluxer.example.org")
    end

    it "references the API key by env var name, never the raw secret" do
      expect(flagship.api_key_env).to eq("FLUXER_FLAGSHIP_API_KEY")
      expect(flagship.respond_to?(:api_key)).to be(false)
    end

    it "is removed when its community is destroyed" do
      community.destroy
      expect(models.fluxer_instance.count).to eq(0)
    end
  end

  it "binds to the supplied database without global state, like the other models" do
    models.irc_network.create(
      community_id: community.id, name: "libera", host: "irc.libera.chat", port: 6697,
      tls: true, nick: "rubotty", channels: "[]", created_at: now, updated_at: now
    )
    other = build_models(migrated_db)
    expect(models.irc_network.count).to eq(1)
    expect(other.irc_network.count).to eq(0)
  end
end
