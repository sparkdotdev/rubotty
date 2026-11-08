# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "tmpdir"

# The Files page: what ControlPlane::RehostedFiles is holding for a
# community, admin only the same way the admin API's file routes are.
# List and delete only: the page must never show or reissue a download
# link, since the UUID that names one is never stored, only its digest.
RSpec.describe "Rubotty::Dashboard::App files", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:store_dir) { Dir.mktmpdir("rubotty-files-spec") }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: store_dir) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  after { FileUtils.remove_entry(store_dir) }

  def login! = post("/login", secret: secret)

  def community_navigation_paths(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    document = JSON.parse(source)
    scope = document.fetch("scopes").find { |entry| entry.fetch("key") == "community" }
    scope.fetch("groups").flat_map { |group| group.fetch("items") }.map { |item| item.fetch("path") }
  end

  def stash(on: community, filename: "notes.txt", created_by: "telegram:ada", room_key: "general")
    deps.rehosted_files.store_file(
      community_id: on.id, source: StringIO.new("hello world"), filename: filename,
      content_type: "text/plain", room_key: room_key, origin: "relay", created_by: created_by
    )
  end

  describe "an administrator session" do
    before { login! }

    it "renders, with a link in the community's own nav" do
      get "/communities/sample/files"

      expect(last_response.status).to eq(200)
      expect(community_navigation_paths).to include("/communities/sample/files")
    end

    it "says plainly when nothing is held" do
      get "/communities/sample/files"

      expect(last_response.body).to include("Nothing is currently held")
    end

    it "lists a stashed file's uploader, size and expiry, never its uuid or a download link" do
      stored = stash

      get "/communities/sample/files"

      expect(last_response.body).to include("notes.txt")
      expect(last_response.body).to include("telegram:ada")
      expect(last_response.body).to include("11 B")
      expect(last_response.body).not_to include(stored.secret)
      expect(last_response.body).not_to include("uuid")
      expect(last_response.body).not_to include("/download")
    end

    it "never shows another community's file" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      stash(on: other, filename: "other-secret.txt")

      get "/communities/sample/files"

      expect(last_response.body).not_to include("other-secret.txt")
    end

    it "deletes a file immediately rather than waiting for the retention window" do
      stored = stash

      post "/communities/sample/files/#{stored.file.id}/delete"

      expect(models.rehosted_file[stored.file.id].expires_at).to be <= Time.now
      follow_redirect!
      expect(last_response.body).to include("marked for deletion")
    end

    it "404-shapes a delete for an id from another community as a flashed refusal" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      stored = stash(on: other)

      post "/communities/sample/files/#{stored.file.id}/delete"

      follow_redirect!
      expect(last_response.body).to include("No such file")
      expect(models.rehosted_file[stored.file.id].expires_at).to be > Time.now
    end
  end

  describe "unauthenticated" do
    it "redirects the listing to login" do
      get "/communities/sample/files"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    it "redirects a delete attempt to login, performing no change" do
      stored = stash

      post "/communities/sample/files/#{stored.file.id}/delete"

      expect(models.rehosted_file[stored.file.id].expires_at).to be > Time.now
      expect(last_response.headers["location"]).to end_with("/login")
    end
  end

  describe "an operator, not an administrator" do
    let(:stub_role_class) do
      Struct.new(:scoped_community_id) do
        def administrator? = false

        def operator? = true

      def kind = :operator

      def readable_community_ids = [scoped_community_id]

      def write_actions = []

      def can?(_action, community:)
          return true if community == Rubotty::Dashboard::Role::DEPLOYMENT

          !community.nil? && community.id == scoped_community_id
        end
      end
    end

    let(:role) { stub_role_class.new(community.id) }
    let(:app) do
      operator_deps = deps
      operator_role = role
      Class.new(Rubotty::Dashboard::App) do
        set :deps, operator_deps
        helpers do
          define_method(:authenticated?) { true }
          define_method(:current_role) { operator_role }
        end
      end
    end

    it "cannot open the files page even for a community it runs" do
      get "/communities/sample/files"

      expect(last_response.status).to eq(403)
    end

    it "cannot delete a file even for a community it runs" do
      stored = stash

      post "/communities/sample/files/#{stored.file.id}/delete"

      expect(last_response.status).to eq(403)
      expect(models.rehosted_file[stored.file.id].expires_at).to be > Time.now
    end
  end

  describe "with no file store configured" do
    let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: nil) }

    before { login! }

    it "says plainly that the deployment has no file store, rather than erroring" do
      get "/communities/sample/files"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("no file store configured")
    end
  end
end
