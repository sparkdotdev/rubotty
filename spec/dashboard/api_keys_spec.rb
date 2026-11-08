# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The admin-only API key surface: issue, list and revoke the bearer credentials the
# REST admin API authenticates against, driven with rack-test over the seeded SAMPLE
# control plane.
RSpec.describe "Rubotty::Dashboard::App API keys", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def login! = post("/login", secret: secret)

  it "gates the listing behind the operator session" do
    get "/api-keys"
    expect(last_response.status).to eq(302)
    expect(last_response.headers["location"]).to end_with("/login")
  end

  it "gates issuing a key behind a session, performing no change" do
    expect do
      post "/api-keys", scope: "administrator", label: "CI bot"
    end.not_to change { models.api_key.count }
    expect(last_response.headers["location"]).to end_with("/login")
  end

  context "when signed in" do
    before { login! }

    it "renders the listing page" do
      get "/api-keys"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("API keys")
    end

    it "offers every community as a scoping choice on the issue form" do
      get "/api-keys"
      expect(last_response.body).to include("sample")
      expect(last_response.body).to include('name="community"')
    end

    it "issues a developer key scoped to the chosen community" do
      expect do
        post "/api-keys", scope: "developer", community: "sample", label: "Discord relay bot"
      end.to change { models.api_key.count }.by(1)

      key = models.api_key.order(:id).last
      expect(key.scope).to eq("developer")
      expect(key.community_id).to eq(community.id)
      expect(key.label).to eq("Discord relay bot")
      expect(key.created_by).to eq("dashboard")
      expect(key.key_hash.length).to eq(64)
    end

    it "issues an administrator key with no community" do
      post "/api-keys", scope: "administrator", label: "CI bot"
      key = models.api_key.order(:id).last
      expect(key.scope).to eq("administrator")
      expect(key.community_id).to be_nil
    end

    it "ignores a submitted community for an administrator key" do
      post "/api-keys", scope: "administrator", community: "sample", label: "CI bot"
      key = models.api_key.order(:id).last
      expect(key.scope).to eq("administrator")
      expect(key.community_id).to be_nil
    end

    it "shows the raw token once, right after issuing" do
      post "/api-keys", scope: "administrator", label: "CI bot"
      follow_redirect!
      expect(last_response.body).to include("CI bot")
      key = models.api_key.order(:id).last
      # Only the digest is ever persisted, so the exact token cannot be asserted from
      # here and a token-shaped value on the page is what there is to check.
      expect(last_response.body).to match(/value="[\w\-]{40,}"/)
      expect(last_response.body).not_to include(key.key_hash)
    end

    it "does not show the token again on a later render" do
      post "/api-keys", scope: "administrator", label: "CI bot"
      follow_redirect!
      get "/api-keys"
      expect(last_response.body).not_to match(/value="[\w\-]{40,}"/)
    end

    it "turns a developer key with no community into a flash error and creates no key" do
      expect do
        post "/api-keys", scope: "developer", label: "Discord relay bot"
      end.not_to change { models.api_key.count }
      follow_redirect!
      expect(last_response.body).to include("developer key needs a community")
    end

    it "turns an unknown scope into a flash error and creates no key" do
      expect do
        post "/api-keys", scope: "superuser", label: "X"
      end.not_to change { models.api_key.count }
      follow_redirect!
      expect(last_response.body).to include("scope")
    end

    it "revokes a live key" do
      issued = deps.api_keys.issue(scope: "administrator", label: "CI bot")
      post "/api-keys/#{issued.key_row.public_id}/revoke"
      expect(issued.key_row.refresh.revoked_at).not_to be_nil
    end

    it "flashes an error for revoking an unknown key" do
      post "/api-keys/no-such-id/revoke"
      follow_redirect!
      expect(last_response.body).to include("No such API key")
    end

    it "no longer offers a revoke action for an already-revoked key" do
      issued = deps.api_keys.issue(scope: "administrator", label: "CI bot")
      deps.api_keys.revoke_by_public_id(public_id: issued.key_row.public_id)
      get "/api-keys"
      expect(last_response.body).to include("revoked")
    end

    # These Deps carry no boot-time config: reading api_wrapper names out of
    # config alone used to refuse every platform-account key, since the
    # accounts table is where those accounts actually live.
    context "a platform-account key where the account lives only in the database" do
      before do
        Rubotty::ControlPlane::Accounts.new(models: models).create(
          adapter: "api_wrapper", name: "acme-bridge",
          settings: { "webhook_url" => "https://acme.example.com/hook",
                      "signing_secret_env" => "ACME_SIGNING_SECRET" }
        )
      end

      it "issues the key, rather than refusing a name it could not see" do
        expect do
          post "/api-keys", scope: "developer", community: "sample",
                            platform_account: "acme-bridge", label: "acme bridge key"
        end.to change { models.api_key.count }.by(1)

        expect(models.api_key.order(:id).last.platform_account).to eq("acme-bridge")
      end

      it "offers the stored name as a suggestion on the form" do
        get "/api-keys"
        expect(last_response.body).to include("acme-bridge")
      end

      it "still refuses a name no account carries anywhere" do
        expect do
          post "/api-keys", scope: "developer", community: "sample",
                            platform_account: "not-an-account", label: "bogus"
        end.not_to change { models.api_key.count }
        follow_redirect!
        expect(last_response.body).to include("names no configured api_wrapper account")
      end
    end
  end
end
