# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The people page is the identity directory, with a bridged nickname
# editable next to each row. Writes go through
# ControlPlane::BridgedNicknames, the same store the /nickname chat
# command uses, so examples check a write by reading it back through it.
RSpec.describe "Rubotty::Dashboard::App people", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }

  def login!
    post "/login", secret: secret
  end

  def record_identity(adapter: "telegram", native_id: "u5", username: "ada", display: "Ada Lovelace")
    deps.identities.record(community_id: community.id, adapter: adapter, native_id: native_id,
                           username: username, display: display)
  end

  def set_nickname(identity_adapter: "telegram", native_id: "u5", username: "ada", display: "Ada Lovelace",
                   target_adapter: "discord", nickname: "owner")
    post "/communities/sample/people", identity_adapter: identity_adapter, native_id: native_id,
                                     username: username, display: display,
                                     target_adapter: target_adapter, nickname: nickname
  end

  # The stand-in operator session moderation_spec.rb uses: told only which
  # actions to allow and which community to scope them to.
  let(:stub_role_class) do
    Struct.new(:allowed_actions, :scoped_community_id) do
      def administrator? = false

      def operator? = true

      def kind = :operator

      def readable_community_ids = [scoped_community_id]

      def write_actions = allowed_actions

      def can?(action, community:)
        return false unless allowed_actions.include?(action)
        return true if community == Rubotty::Dashboard::Role::DEPLOYMENT

        !community.nil? && community.id == scoped_community_id
      end
    end
  end

  def app_as(role)
    people_deps = deps
    Class.new(Rubotty::Dashboard::App) do
      set :deps, people_deps
      helpers do
        define_method(:authenticated?) { true }
        define_method(:current_role) { role }
      end
    end
  end

  describe "an administrator session" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { login! }

    describe "GET /communities/:slug/people" do
      it "renders" do
        get "/communities/sample/people"
        expect(last_response.status).to eq(200)
      end

      it "lists a person the identity directory has seen, with their handle and display name" do
        record_identity
        get "/communities/sample/people"
        expect(last_response.body).to include("@ada")
        expect(last_response.body).to include("Ada Lovelace")
      end

      it "filters by handle or display name" do
        record_identity(native_id: "u5", username: "ada", display: "Ada Lovelace")
        record_identity(native_id: "u6", username: "bob", display: "Bob Smith")

        get "/communities/sample/people", q: "ada"

        expect(last_response.body).to include("Ada Lovelace")
        expect(last_response.body).not_to include("Bob Smith")
      end

      it "caps the listing and discloses the cap in the page copy" do
        now = Time.now
        60.times do |i|
          db[:observed_identities].insert(
            community_id: community.id, adapter: "telegram", native_id: "bulk-#{i}",
            username: "bulk#{i}", display_name: "Bulk #{i}",
            first_seen_at: now, last_seen_at: now + i
          )
        end

        get "/communities/sample/people"

        expect(last_response.body).to include("Showing up to 50")
        expect(last_response.body.scan("@bulk").size).to eq(50)
      end

      it "shows the most recently seen first" do
        record_identity(native_id: "u5", username: "older", display: "Older")
        db[:observed_identities].where(native_id: "u5").update(last_seen_at: Time.now - 3600)
        record_identity(native_id: "u6", username: "newer", display: "Newer")

        get "/communities/sample/people"

        expect(last_response.body.index("Newer")).to be < last_response.body.index("Older")
      end

      it "offers a nickname field only for a platform other than the one the row was seen on" do
        record_identity(native_id: "u5", username: "ada")
        get "/communities/sample/people"

        expect(last_response.body).to include('name="target_adapter" value="discord"')
        expect(last_response.body).not_to include('name="target_adapter" value="telegram"')
      end
    end

    describe "POST /communities/:slug/people" do
      it "sets a nickname through ControlPlane::BridgedNicknames and it persists" do
        record_identity(native_id: "u5", username: "ada", display: "Ada Lovelace")

        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord",
                     nickname: "owner")
        expect(last_response.status).to eq(302)
        follow_redirect!
        expect(last_response.body).to include("now shown as owner")

        # Read the write back through the same service the /nickname command
        # calls, rather than asserting against a second, independently derived
        # expectation: this is the actual proof there is no separate code path.
        person = deps.bridged_nicknames.person_for_identity(
          community_id: community.id, adapter: "telegram", native_id: "u5"
        )
        expect(deps.bridged_nicknames.for_person(community_id: community.id, person_id: person.id))
          .to eq("discord" => "owner")
      end

      # The refusal reported in the field: a display name is what this page sets,
      # so it has to take one.
      it "takes a display name with a space and an emoji in it" do
        record_identity(native_id: "u5", username: "ada", display: "Ada Lovelace")

        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord",
                     nickname: "River 🇵🇹")
        follow_redirect!

        expect(last_response.body).to include("now shown as River 🇵🇹")
      end

      it "takes a name that is not written in English" do
        record_identity(native_id: "u5", username: "ada", display: "Ada Lovelace")

        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord",
                     nickname: "João")
        follow_redirect!

        expect(last_response.body).to include("now shown as João")
      end

      it "shows the freshly set nickname back on the list" do
        record_identity(native_id: "u5", username: "ada", display: "Ada Lovelace")
        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord",
                     nickname: "owner")

        get "/communities/sample/people"
        expect(last_response.body).to include('value="owner"')
      end

      it "refuses a name someone else already holds, the same refusal the command gives" do
        record_identity(native_id: "u5", username: "ada")
        record_identity(native_id: "u6", username: "bob")
        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord",
                     nickname: "owner")

        set_nickname(identity_adapter: "telegram", native_id: "u6", target_adapter: "discord",
                     nickname: "owner")
        follow_redirect!
        expect(last_response.body).to include("already taken on discord")

        # The refused claim still earns bob a person row, the same as the chat
        # command does (Nickname#assign resolves a person before it writes),
        # but no nickname is recorded against it.
        bob = deps.bridged_nicknames.person_for_identity(community_id: community.id, adapter: "telegram",
                                                          native_id: "u6")
        expect(deps.bridged_nicknames.for_person(community_id: community.id, person_id: bob.id)).to be_empty
      end

      it "clears a nickname when the field is submitted blank" do
        record_identity(native_id: "u5", username: "ada")
        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord",
                     nickname: "owner")

        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord", nickname: "")
        follow_redirect!
        expect(last_response.body).to include("Cleared")

        person = deps.bridged_nicknames.person_for_identity(community_id: community.id, adapter: "telegram",
                                                             native_id: "u5")
        expect(deps.bridged_nicknames.for_person(community_id: community.id, person_id: person.id)).to be_empty
      end

      it "mints no person row for a blank submission on an identity nobody ever named" do
        record_identity(native_id: "u5", username: "ada")
        before_count = models.person.count

        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord", nickname: "")

        expect(models.person.count).to eq(before_count)
      end

      it "refuses to write when who_can_set is nobody, the same as the command would" do
        deps.feature_controls.set(community: community, selector: "all", feature: "nickname",
                                  key: "who_can_set", value: "nobody")
        record_identity(native_id: "u5", username: "ada")

        set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord",
                     nickname: "owner")
        follow_redirect!

        expect(last_response.body).to include("not being handed out")
        expect(
          deps.bridged_nicknames.person_for_identity(community_id: community.id, adapter: "telegram",
                                                      native_id: "u5")
        ).to be_nil
      end
    end
  end

  describe "an operator whose grant covers this community" do
    let(:app) { app_as(stub_role_class.new(%i[configure_nickname view_community], community.id)) }

    it "reaches the page and can set a nickname" do
      record_identity(native_id: "u5", username: "ada")
      get "/communities/sample/people"
      expect(last_response.status).to eq(200)

      set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord", nickname: "owner")
      expect(last_response.status).to eq(302)

      person = deps.bridged_nicknames.person_for_identity(community_id: community.id, adapter: "telegram",
                                                           native_id: "u5")
      expect(deps.bridged_nicknames.for_person(community_id: community.id, person_id: person.id))
        .to eq("discord" => "owner")
    end
  end

  describe "an operator without the configure_nickname grant" do
    let(:app) { app_as(stub_role_class.new(%i[view_community], community.id)) }

    it "can read the page" do
      get "/communities/sample/people"
      expect(last_response.status).to eq(200)
    end

    it "is denied setting a nickname, and nothing is written" do
      record_identity(native_id: "u5", username: "ada")

      set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord", nickname: "owner")

      expect(last_response.status).to eq(403)
      expect(
        deps.bridged_nicknames.person_for_identity(community_id: community.id, adapter: "telegram",
                                                    native_id: "u5")
      ).to be_nil
    end
  end

  describe "an operator whose grant does NOT cover this community" do
    let(:other_community) do
      models.community.create(slug: "other", name: "Other", status: "active",
                              settings: "{}", created_at: Time.now, updated_at: Time.now)
    end
    let(:app) { app_as(stub_role_class.new(%i[configure_nickname view_community], other_community.id)) }

    it "is denied the people page" do
      get "/communities/sample/people"
      expect(last_response.status).to eq(403)
    end

    it "is denied setting a nickname" do
      set_nickname(identity_adapter: "telegram", native_id: "u5", target_adapter: "discord", nickname: "owner")
      expect(last_response.status).to eq(403)
    end
  end
end
