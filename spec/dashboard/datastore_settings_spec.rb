# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "zlib"
require "yaml"

RSpec.describe "the dashboard Datastore settings", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  def admin!
    post "/login", secret: secret
  end

  before { admin! }

  it "shows the export page with a download link and a secrets warning" do
    get "/settings/datastore"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("Datastore")
    expect(last_response.body).to include("Download snapshot")
    expect(last_response.body).to include("every secret this deployment stores")
    expect(last_response.body).to include('href="http://example.org/settings/datastore/export"')
  end

  it "shows the import form as a multipart upload" do
    get "/settings/datastore"

    expect(last_response.body).to include('action="http://example.org/settings/datastore/import"')
    expect(last_response.body).to include('enctype="multipart/form-data"')
    expect(last_response.body).to include('type="file"')
  end

  it "streams a real gzipped snapshot as an attachment" do
    get "/settings/datastore/export"

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to eq("application/gzip")
    expect(last_response.headers["Content-Disposition"]).to match(/attachment.*rubotty-datastore-.*\.yaml\.gz/)

    document = YAMLCamel.load(Zlib::GzipReader.new(StringIO.new(last_response.body)).read)
    expect(document["format"]).to eq(Rubotty::Storage::Snapshot::FORMAT)
    expect(document["tables"]["communities"].length).to eq(1)
  end

  describe "import" do
    let(:empty_db) { Sequel.sqlite }
    let(:empty_deps) { Rubotty::Dashboard::Deps.new(db: empty_db, logger: Rubotty::Log.null) }
    let(:empty_app) { Rubotty::Dashboard::App.assemble(deps: empty_deps, env: env) }
    let(:empty_session) { Rack::Test::Session.new(empty_app) }

    before do
      Rubotty::Storage::Schema.apply(empty_db)
      Rubotty::ControlPlane::Migrator.run(empty_db)
      empty_session.post "/login", secret: secret
    end

    def upload(bytes, filename: "snapshot.yaml.gz")
      empty_session.post "/settings/datastore/import",
                         file: Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/gzip",
                                                            original_filename: filename)
    end

    it "restores a snapshot exported from a seeded deployment into an empty one" do
      exported = Rubotty::Storage::Snapshot.document_bytes(db, label: "test")

      upload(exported)
      expect(empty_session.last_response.status).to eq(302)

      empty_session.get "/settings/datastore"
      expect(empty_session.last_response.body).to include("Datastore restored")
      expect(empty_db[:communities].count).to eq(1)
    end

    it "rejects a file that is not a rubotty snapshot" do
      upload("not a snapshot")
      expect(empty_session.last_response.status).to eq(302)

      empty_session.get "/settings/datastore"
      expect(empty_session.last_response.body).to include("not a gzip file")
    end
  end

  it "keeps every route administrator-only" do
    session_env = { "rack.session" => dashboard_session(role: "operator", operator_communities: []) }

    get "/settings/datastore", {}, session_env
    expect(last_response.status).to eq(403)

    get "/settings/datastore/export", {}, session_env
    expect(last_response.status).to eq(403)

    post "/settings/datastore/import", {}, session_env
    expect(last_response.status).to eq(403)
  end
end
