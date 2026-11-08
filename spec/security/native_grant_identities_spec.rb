# frozen_string_literal: true

require "spec_helper"

RSpec.describe "privileged native account bindings", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:flow) { Rubotty::ControlPlane::OperatorFlow.new(models: models) }
  let(:directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }

  before { without_owner_floor }

  {
    "dashboard administrator" => [Rubotty::ControlPlane::DashboardAdministrators, :administrator?, :dashboard_administrators],
    "dashboard viewer" => [Rubotty::ControlPlane::DashboardViewers, :viewer?, :dashboard_viewers],
    "community viewer" => [Rubotty::ControlPlane::CommunityViewers, :viewer?, :community_viewers]
  }.each do |role, (service_class, predicate, table)|
    context role do
      let(:scope) { table == :community_viewers ? { community_id: community.id } : {} }
      let(:floor_class) do
        table == :dashboard_administrators ? Rubotty::Security::DashboardAdministrators : Rubotty::Security::DashboardViewers
      end
      let(:service) { service_class.new(models: models, floor: floor_class.new) }

      def granted_identity?(predicate, **identity)
        service.public_send(predicate, **scope, **identity)
      end

      it "keeps the original native account authorised after a rename and refuses its replacement" do
        row = service.grant(**scope, adapter: "telegram", handle: "ada", native_id: "100", granted_by: "administrator")

        expect(row[:native_id]).to eq("100")
        expect(granted_identity?(predicate, adapter: "telegram", native_id: "100", username: "renamed")).to be(true)
        expect(granted_identity?(predicate, adapter: "telegram", native_id: "200", username: "ada")).to be(false)
        expect(granted_identity?(predicate, adapter: "telegram", username: "ada")).to be(false)
      end

      it "resolves a known handle exactly once at the authorised grant" do
        directory.record(community_id: community.id, adapter: "discord", native_id: "100", username: "ada")
        row = service.grant(**scope, adapter: "discord", handle: "ada", granted_by: "administrator")
        directory.record(community_id: community.id, adapter: "discord", native_id: "100", username: "renamed")
        directory.record(community_id: community.id, adapter: "discord", native_id: "200", username: "ada")

        expect(row[:native_id]).to eq("100")
        expect(granted_identity?(predicate, adapter: "discord", native_id: "200", username: "ada")).to be(false)
      end

      it "rejects both an unknown and an ambiguous handle without writing a grant" do
        expect { service.grant(**scope, adapter: "telegram", handle: "unknown", granted_by: "administrator") }
          .to raise_error(service_class::Invalid, /native_id.*request access/)
        %w[100 200].each do |id|
          directory.record(community_id: community.id, adapter: "telegram", native_id: id, username: "ada")
        end

        expect { service.grant(**scope, adapter: "telegram", handle: "ada", granted_by: "administrator") }
          .to raise_error(service_class::Invalid, /several native account ids/)
        expect(db[table].count).to eq(0)
      end

      it "leaves legacy handle-only rows visible but inactive and permits an explicit regrant" do
        old_id = db[table].insert(**scope, adapter: "telegram", handle: "ada", granted_at: Time.now)
        expect(granted_identity?(predicate, adapter: "telegram", native_id: "100", username: "ada")).to be(false)

        new_row = service.grant(**scope, adapter: "telegram", handle: "ada", native_id: "100", granted_by: "administrator")
        expect(new_row[:id]).not_to eq(old_id)
        expect(db[table].where(id: old_id).first[:native_id]).to be_nil
        expect(granted_identity?(predicate, adapter: "telegram", native_id: "100")).to be(true)
      end

      it "distinguishes explicitly granted accounts even when a handle has been reused" do
        first = service.grant(**scope, adapter: "telegram", handle: "ada", native_id: "100", granted_by: "administrator")
        second = service.grant(**scope, adapter: "telegram", handle: "ada", native_id: "200", granted_by: "administrator")

        expect(first[:id]).not_to eq(second[:id])
        expect(service.grant(**scope, adapter: "telegram", handle: "renamed", native_id: "100", granted_by: "administrator")[:id])
          .to eq(first[:id])
      end

      it "requires a full Matrix account id and treats a conflicting presented id as authoritative" do
        service.grant(**scope, adapter: "matrix", handle: "@ada:example.org", granted_by: "administrator")

        expect(granted_identity?(predicate, adapter: "matrix", username: "@ada:example.org")).to be(true)
        expect(granted_identity?(predicate, adapter: "matrix", native_id: "@other:example.org", username: "@ada:example.org")).to be(false)
        expect { service.grant(**scope, adapter: "matrix", handle: "ada", granted_by: "administrator") }
          .to raise_error(service_class::Invalid, /full MXID/)
      end

      it "rejects IRC nicknames while preserving explicit scoped authenticated accounts" do
        expect { service.grant(**scope, adapter: "irc", handle: "ada", native_id: "ada", granted_by: "administrator") }
          .to raise_error(service_class::Invalid, /durable native/)
        service.grant(**scope, adapter: "irc", handle: "ada", native_id: "account:network:ada", granted_by: "administrator")

        expect(granted_identity?(predicate, adapter: "irc", native_id: "ada", username: "ada")).to be(false)
        expect(granted_identity?(predicate, adapter: "irc", native_id: "account:network:ada")).to be(true)
      end

      it "requires the trusted XMPP DM namespace when authenticating a granted bare JID" do
        service.grant(**scope, adapter: "xmpp", handle: "ada", native_id: "ada@example.org", granted_by: "administrator")

        expect(granted_identity?(predicate, adapter: "xmpp", native_id: "ada@example.org")).to be(false)
        expect(granted_identity?(predicate, adapter: "xmpp", native_id: "jid:ada@example.org")).to be(true)
      end
    end
  end

  it "does not resolve or merge a different native account using an operator's recycled username" do
    old_identity = models.person_identity.where(adapter: "telegram", native_id: "80000012").first
    expect(flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                 native_id: "200", username: "sample_owner")).to be_nil

    new_operator = flow.promote(community_id: community.id, adapter: "telegram", native_id: "200",
                                username: "sample_owner", granted_by: "administrator")
    expect(new_operator.person_id).not_to eq(old_identity.person_id)
    expect(models.person_identity.where(adapter: "telegram", native_id: "80000012").first.person_id)
      .to eq(old_identity.person_id)
  end

  it "approves the requester's captured native identity despite a recycled public handle" do
    service = Rubotty::ControlPlane::DashboardViewers.new(models: models, floor: Rubotty::Security::DashboardViewers.new)
    request = service.request(adapter: "telegram", native_id: "100", username: "ada").request
    directory.record(community_id: community.id, adapter: "telegram", native_id: "200", username: "ada")

    expect(service.approve(request: request, decided_by: "administrator")).to be_approved
    expect(service.viewer?(adapter: "telegram", native_id: "100", username: "renamed")).to be(true)
    expect(service.viewer?(adapter: "telegram", native_id: "200", username: "ada")).to be(false)
  end

  it "does not promote a legacy session nickname" do
    expect { flow.promote(community_id: community.id, adapter: "irc", native_id: "ada", granted_by: "administrator") }
      .to raise_error(Rubotty::Security::GrantIdentity::Invalid)
  end

  it "does not rewrite an existing operator's identity when a config reuses their name and handle" do
    original = sample_model
    replacement = Rubotty::Core::Person.new(name: "sample_owner", identities: { telegram: ["200"] },
                                            handles: { telegram: ["sample_owner"] })
    attributes = %i[name accounts topology storage behaviour display_name source commands announce]
                 .to_h { |key| [key, original.public_send(key)] }
    updated = Rubotty::Config::Model.new(**attributes, operators: original.operators,
                                         people: Rubotty::Core::Directory.new([replacement]))
    community # create the original seeded identity before the next config

    Rubotty::ControlPlane::Seed.from_model(updated, models: models, slug: "sample")

    expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "200")).to be_nil
    expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "80000012"))
      .not_to be_nil
  end
end

RSpec.describe "stable grant identity migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "requires regrant of every legacy label, including a Matrix MXID that may have lost its original case" do
    migrator = Rubotty::ControlPlane::Migrator.new(db)
    migrator.run(target: 101)
    db[:dashboard_administrators].insert(adapter: "telegram", handle: "ada", granted_at: Time.now)
    db[:dashboard_viewers].insert(adapter: "matrix", handle: "@ada:example.org", granted_at: Time.now)
    migrator.run(target: 102)

    expect(db[:dashboard_administrators].first[:native_id]).to be_nil
    expect(db[:dashboard_viewers].first[:native_id]).to be_nil
    rebound = db[:dashboard_viewers].insert(adapter: "matrix", handle: "@Ada:Example.org",
                                            native_id: "@Ada:Example.org", granted_at: Time.now)
    expect { migrator.run(target: 101) }.to raise_error(Rubotty::StorageError, /export and remove/)
    expect(db[:dashboard_viewers].where(id: rebound).first[:native_id]).to eq("@Ada:Example.org")
  end

  it "can roll back an empty validation database and migrate it again" do
    migrator = Rubotty::ControlPlane::Migrator.new(db)
    migrator.run(target: 102)
    migrator.run(target: 101)
    migrator.run(target: 102)

    expect(db.schema(:dashboard_administrators).map(&:first)).to include(:native_id)
  end

  it "creates binary native identity columns even on a MySQL database with a different default collation" do
    Sequel.extension :migration
    path = File.join(Rubotty::ControlPlane::Migrator::MIGRATIONS_DIR, "102_stable_grant_identities.rb")
    migration = eval(File.read(path), TOPLEVEL_BINDING, path)
    mysql = Sequel.mock(host: "mysql")
    mysql.default_collate = "utf8mb4_general_ci"

    migration.apply(mysql, :up)

    added = mysql.sqls.select { |sql| sql.include?("ADD COLUMN `native_id`") }
    expect(added.size).to eq(3)
    expect(added).to all(include("COLLATE utf8mb4_bin"))
  end
end
