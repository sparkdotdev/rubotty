# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "securerandom"

RSpec.describe Rubotty::ControlPlane::ProtectedCommunityConnections, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  # Plain File.write to a throwaway path. A Tempfile unlinks itself when the object
  # is collected, so a helper that hands back only the path can lose the file
  # underneath the call it just set up.
  def write_yaml(content)
    path = File.join(Dir.tmpdir, "protected-communities-#{SecureRandom.hex(8)}.yml")
    File.write(path, content)
    path
  end

  def reconcile!(path)
    described_class.reconcile!(models: models, path: path)
  end

  it "creates a community and its connection from a fresh entry" do
    path = write_yaml(<<~YAML)
      communities:
        - slug: second
          name: SECOND
          connections:
            - adapter: discord
              account: discord
              external_id: "999888777"
              label: SECOND Discord
    YAML
    reconcile!(path)

    community = models.community.where(slug: "second").first
    expect(community.name).to eq("SECOND")
    expect(community.status).to eq("active")
    expect(community.bootstrap_source).to eq("config/protected_communities.yml")

    connection = models.platform_connection.where(adapter: "discord", account: "discord",
                                                   external_id: "999888777").first
    expect(connection.community_id).to eq(community.id)
    expect(connection.label).to eq("SECOND Discord")
  end

  it "is idempotent: reconciling twice does not duplicate the community or the connection" do
    path = write_yaml(<<~YAML)
      communities:
        - slug: second
          name: SECOND
          connections:
            - adapter: discord
              account: discord
              external_id: "999888777"
    YAML
    reconcile!(path)
    reconcile!(path)

    expect(models.community.where(slug: "second").count).to eq(1)
    expect(models.platform_connection.where(adapter: "discord", external_id: "999888777").count).to eq(1)
  end

  it "creates the community even with no connections yet, and adds one later" do
    path = write_yaml(<<~YAML)
      communities:
        - slug: example-travel
          name: Example Travel
          connections: []
    YAML
    reconcile!(path)
    expect(models.community.where(slug: "example-travel").first).not_to be_nil
    expect(models.platform_connection.count).to eq(0)

    path2 = write_yaml(<<~YAML)
      communities:
        - slug: example-travel
          name: Example Travel
          connections:
            - adapter: telegram
              account: telegram
              external_id: "-100123456"
    YAML
    reconcile!(path2)

    community = models.community.where(slug: "example-travel").first
    connection = models.platform_connection.where(adapter: "telegram", external_id: "-100123456").first
    expect(connection.community_id).to eq(community.id)
  end

  it "does not touch a community's existing name once it exists" do
    path = write_yaml(<<~YAML)
      communities:
        - slug: second
          name: SECOND
          connections: []
    YAML
    reconcile!(path)
    models.community.where(slug: "second").first.update(name: "Renamed by hand")

    reconcile!(path)
    expect(models.community.where(slug: "second").first.name).to eq("Renamed by hand")
  end

  it "reconciles a changed label onto an existing connection" do
    path = write_yaml(<<~YAML)
      communities:
        - slug: second
          name: SECOND
          connections:
            - adapter: discord
              account: discord
              external_id: "999888777"
              label: Main
    YAML
    reconcile!(path)

    renamed_path = write_yaml(<<~YAML)
      communities:
        - slug: second
          name: SECOND
          connections:
            - adapter: discord
              account: discord
              external_id: "999888777"
              label: Primary
    YAML
    reconcile!(renamed_path)

    connection = models.platform_connection.where(adapter: "discord", external_id: "999888777").first
    expect(connection.label).to eq("Primary")
  end

  it "reassigns a connection to a new community slug if the entry moves, instead of duplicating it" do
    path = write_yaml(<<~YAML)
      communities:
        - slug: second
          name: SECOND
          connections:
            - adapter: discord
              account: discord
              external_id: "999888777"
    YAML
    reconcile!(path)
    original_community = models.community.where(slug: "second").first

    moved_path = write_yaml(<<~YAML)
      communities:
        - slug: second-renamed
          name: SECOND
          connections:
            - adapter: discord
              account: discord
              external_id: "999888777"
    YAML
    reconcile!(moved_path)

    expect(models.platform_connection.where(adapter: "discord", external_id: "999888777").count).to eq(1)
    connection = models.platform_connection.where(adapter: "discord", external_id: "999888777").first
    expect(connection.community_id).not_to eq(original_community.id)
  end

  it "skips a malformed entry and still reconciles the rest" do
    path = write_yaml(<<~YAML)
      communities:
        - name: no slug at all
        - slug: second
          name: SECOND
          connections: []
    YAML
    expect { reconcile!(path) }.not_to raise_error
    expect(models.community.where(slug: "second").first).not_to be_nil
  end

  it "does nothing, without raising, when the file is missing" do
    expect { reconcile!("/tmp/does-not-exist-#{SecureRandom.hex(6)}.yml") }.not_to raise_error
    expect(models.community.count).to eq(0)
  end

  it "does nothing, without raising, on unparsable YAML" do
    path = write_yaml("not: valid: yaml: [")
    expect { reconcile!(path) }.not_to raise_error
  end
end
