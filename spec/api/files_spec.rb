# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"
require "stringio"
require "tmpdir"

# Files rubotty is holding on a community's behalf, over the API. The secret naming
# a file is never stored, so nothing can hand out a link for a file it is merely
# looking at, and minting a new link means re-encrypting under a new key.
RSpec.describe "Rubotty::Api::App files", :control_plane do
  include Rack::Test::Methods

  around do |example|
    Dir.mktmpdir("rubotty-api-files") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) do
    Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200, file_store_path: @root)
  end
  # What a download link is built from. Unset by default, so most examples see the
  # bare path.
  let(:portal_url) { nil }
  let(:app) do
    Rubotty::Api::App.assemble(deps: deps,
                               env: portal_url.nil? ? {} : { "RUBOTTY_FILE_STORAGE_URL" => portal_url })
  end
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  let(:other) do
    now = Time.now
    models.community.create(slug: "other-co", name: "Other Co", status: "active",
                            settings: "{}", created_at: now, updated_at: now)
  end

  # Big enough to cross the store's chunk boundary several times, so a rotation
  # really streams rather than fitting in one read.
  let(:payload) { "a file no platform here would take. " * 20_000 }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  def allow_files(**config)
    deps.feature_controls.enable(community: community, selector: "all", feature: "file_rehosting")
    config.each do |key, value|
      deps.feature_controls.set(community: community, selector: "all", feature: "file_rehosting",
                                key: key.to_s, value: value)
    end
  end

  def upload(bytes = payload, slug: "sample", filename: "clip.mp4", type: "video/mp4", **rest)
    post "/admin/communities/#{slug}/files",
         { file: Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: filename),
           **rest }, admin
    body
  end

  # Straight off the store rather than through the download route, which lives on a
  # different surface.
  def read_back(uuid, community_id: community.id)
    row = deps.rehosted_files.fetch(secret: uuid, community_id: community_id)
    return nil if row.nil?

    out = +""
    deps.rehosted_files.stream(row, secret: uuid) { |chunk| out << chunk }
    out
  end

  def hold(community_id: community.id, **rest)
    deps.rehosted_files.store_file(community_id: community_id, source: StringIO.new(payload),
                                   room_key: "general", filename: "held.bin", **rest)
  end

  describe "POST /admin/communities/:slug/files" do
    before { allow_files }

    it "stores the file and hands back the UUID that names it" do
      created = upload

      expect(last_response.status).to eq(201)
      expect(created["uuid"]).to match(/\A[0-9a-f-]{36}\z/)
      expect(created["filename"]).to eq("clip.mp4")
      expect(created["byte_size"]).to eq(payload.bytesize)
      expect(read_back(created["uuid"])).to eq(payload)
    end

    context "with a public base configured" do
      let(:portal_url) { "https://example.invalid" }

      it "builds the download link off it, ending in the file's own extension" do
        created = upload("a small one", filename: "note.txt", type: "text/plain")

        expect(created["url"]).to eq("https://example.invalid/filestorage/#{created['uuid']}.txt")
      end
    end

    it "records where it came from without being told" do
      expect(upload["source"]).to eq("upload")
      expect(upload["created_by"]).to start_with("api:")
    end

    # A UUID cannot be looked up later, so this is the whole of what an uploader gets.
    it "is the only response that carries the UUID, along with a rotation" do
      created = upload

      get "/admin/communities/sample/files/#{created['id']}", {}, admin
      expect(body).not_to have_key("uuid")

      get "/admin/communities/sample/files", {}, admin
      expect(body["files"].first).not_to have_key("uuid")
    end

    it "refuses a request with no file" do
      post "/admin/communities/sample/files", {}, admin

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("no file")
    end

    # The community's setting decides, so an administrator key is no way around it.
    it "refuses when the community is not accepting files" do
      deps.feature_controls.disable(community: community, selector: "all", feature: "file_rehosting")

      upload

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("not accepting files")
    end

    it "refuses a file over the community's own cap" do
      allow_files(max_bytes: 32)

      upload

      expect(last_response.status).to eq(413)
    end

    it "holds it under the community's own retention" do
      allow_files(retention_days: 3)

      created = upload

      expect(Time.parse(created["expires_at"])).to be_within(60).of(Time.now + (3 * 86_400))
    end

    it "403s a developer key" do
      post "/admin/communities/sample/files",
           { file: Rack::Test::UploadedFile.new(StringIO.new("x"), "text/plain",
                                                original_filename: "x.txt") }, developer

      expect(last_response.status).to eq(403)
    end
  end

  describe "GET /admin/communities/:slug/files" do
    it "lists what the community is holding, newest first" do
      hold(filename: "first.bin")
      hold(filename: "second.bin")

      get "/admin/communities/sample/files", {}, admin

      expect(body["files"].map { |row| row["filename"] }).to eq(["second.bin", "first.bin"])
    end

    it "reports the real size and what the disk is carrying" do
      hold

      get "/admin/communities/sample/files", {}, admin

      row = body["files"].first
      expect(row["byte_size"]).to eq(payload.bytesize)
      expect(row["sealed_bytes"]).to be_positive
    end

    it "reports the serve ceiling and how many serves are left" do
      hold

      get "/admin/communities/sample/files", {}, admin

      row = body["files"].first
      expect(row["serve_limit"]).to eq(Rubotty::ControlPlane::RehostedFiles::SERVE_LIMIT_FLAT)
      expect(row["served_count"]).to eq(0)
      expect(row["serves_remaining"]).to eq(Rubotty::ControlPlane::RehostedFiles::SERVE_LIMIT_FLAT)
    end

    it "never carries another community's files" do
      hold(community_id: other.id, filename: "theirs.bin")
      hold(filename: "ours.bin")

      get "/admin/communities/sample/files", {}, admin

      expect(body["files"].map { |row| row["filename"] }).to eq(["ours.bin"])
    end

    it "404s another community's file id" do
      theirs = hold(community_id: other.id)

      get "/admin/communities/sample/files/#{theirs.file.id}", {}, admin

      expect(last_response.status).to eq(404)
    end

    it "403s a developer key" do
      get "/admin/communities/sample/files", {}, developer

      expect(last_response.status).to eq(403)
    end
  end

  # The service cannot mint a second link on its own, so the caller supplies the one
  # they hold and the file is re-encrypted under a new key.
  describe "POST /admin/communities/:slug/files/rotate" do
    it "hands back a new UUID that reads the identical bytes" do
      stored = hold

      post "/admin/communities/sample/files/rotate", { uuid: stored.secret }, admin

      expect(last_response.status).to eq(200)
      expect(body["uuid"]).not_to eq(stored.secret)
      expect(read_back(body["uuid"])).to eq(payload)
    end

    it "kills the old link" do
      stored = hold

      post "/admin/communities/sample/files/rotate", { uuid: stored.secret }, admin

      expect(read_back(stored.secret)).to be_nil
    end

    # A rotation changes who can reach the file, so it stays the same file.
    it "keeps the file it was, rather than making a second one" do
      stored = hold

      post "/admin/communities/sample/files/rotate", { uuid: stored.secret }, admin

      expect(body["id"]).to eq(stored.file.id)
      expect(body["byte_size"]).to eq(payload.bytesize)
      expect(deps.rehosted_files.list(community_id: community.id).length).to eq(1)
    end

    # Rotating weekly must not become a way to keep a file forever.
    it "does not extend the retention" do
      stored = hold
      before = stored.file.expires_at

      post "/admin/communities/sample/files/rotate", { uuid: stored.secret }, admin

      expect(Time.parse(body["expires_at"])).to be_within(1).of(before)
    end

    it "leaves nothing behind on disk" do
      stored = hold
      previous = stored.file.object_key

      post "/admin/communities/sample/files/rotate", { uuid: stored.secret }, admin

      expect(deps.rehosted_files.store.exist?(previous)).to be(false)
      expect(deps.rehosted_files.store.exist?(stored.file.refresh.object_key)).to be(true)
    end

    it "404s a UUID that names nothing" do
      post "/admin/communities/sample/files/rotate", { uuid: SecureRandom.uuid }, admin

      expect(last_response.status).to eq(404)
    end

    # Otherwise this is an oracle for whether a guessed link is real.
    it "404s another community's UUID, with the same body as an unknown one" do
      theirs = hold(community_id: other.id)

      post "/admin/communities/sample/files/rotate", { uuid: theirs.secret }, admin

      expect(last_response.status).to eq(404)
      expect(body["error"]).to eq("not found")
      expect(read_back(theirs.secret, community_id: other.id)).to eq(payload)
    end

    it "refuses a request with no UUID rather than reading it as a miss" do
      post "/admin/communities/sample/files/rotate", {}, admin

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("uuid is required")
    end

    it "403s a developer key" do
      stored = hold

      post "/admin/communities/sample/files/rotate", { uuid: stored.secret }, developer

      expect(last_response.status).to eq(403)
    end
  end

  describe "POST /admin/communities/:slug/files/expire" do
    it "brings the expiry forward and kills the link at once" do
      stored = hold

      post "/admin/communities/sample/files/expire", { uuid: stored.secret }, admin

      expect(last_response.status).to eq(200)
      expect(Time.parse(body["expires_at"])).to be <= Time.now
      expect(read_back(stored.secret)).to be_nil
    end

    # The bytes go with the sweep, so one place orders the unlink before the row.
    it "leaves the bytes for the next reclaim pass, which then takes them" do
      stored = hold
      post "/admin/communities/sample/files/expire", { uuid: stored.secret }, admin
      expect(deps.rehosted_files.store.exist?(stored.file.object_key)).to be(true)

      deps.rehosted_files.expire(now: Time.now + 1)

      expect(deps.rehosted_files.store.exist?(stored.file.object_key)).to be(false)
      expect(deps.rehosted_files.list(community_id: community.id)).to be_empty
    end

    it "404s a UUID that names nothing" do
      post "/admin/communities/sample/files/expire", { uuid: SecureRandom.uuid }, admin

      expect(last_response.status).to eq(404)
    end

    it "404s another community's UUID and leaves their file alone" do
      theirs = hold(community_id: other.id)

      post "/admin/communities/sample/files/expire", { uuid: theirs.secret }, admin

      expect(last_response.status).to eq(404)
      expect(read_back(theirs.secret, community_id: other.id)).to eq(payload)
    end

    it "403s a developer key" do
      stored = hold

      post "/admin/communities/sample/files/expire", { uuid: stored.secret }, developer

      expect(last_response.status).to eq(403)
    end
  end

  # The way to reach a file whose UUID nobody kept. Safe to address by id because
  # expiring only writes a column and the sweep does the rest.
  describe "DELETE /admin/communities/:slug/files/:id" do
    it "expires a file whose UUID the caller no longer has" do
      stored = hold

      delete "/admin/communities/sample/files/#{stored.file.id}", {}, admin

      expect(last_response.status).to eq(200)
      expect(Time.parse(body["expires_at"])).to be <= Time.now
      expect(read_back(stored.secret)).to be_nil
    end

    it "leaves the bytes for the next reclaim pass, which then takes them" do
      stored = hold
      delete "/admin/communities/sample/files/#{stored.file.id}", {}, admin
      expect(deps.rehosted_files.store.exist?(stored.file.object_key)).to be(true)

      deps.rehosted_files.expire(now: Time.now + 1)

      expect(deps.rehosted_files.store.exist?(stored.file.object_key)).to be(false)
    end

    # Calling it twice must not push a lapsed file's deletion out of the sweep's reach.
    it "does not move an expiry that has already passed" do
      stored = hold
      delete "/admin/communities/sample/files/#{stored.file.id}", {}, admin
      first = Time.parse(body["expires_at"])

      delete "/admin/communities/sample/files/#{stored.file.id}", {}, admin

      expect(last_response.status).to eq(200)
      expect(Time.parse(body["expires_at"])).to eq(first)
    end

    it "404s an id that names nothing" do
      delete "/admin/communities/sample/files/999999", {}, admin

      expect(last_response.status).to eq(404)
    end

    it "404s another community's id and leaves their file alone" do
      theirs = hold(community_id: other.id)

      delete "/admin/communities/sample/files/#{theirs.file.id}", {}, admin

      expect(last_response.status).to eq(404)
      expect(read_back(theirs.secret, community_id: other.id)).to eq(payload)
    end

    it "403s a developer key" do
      stored = hold

      delete "/admin/communities/sample/files/#{stored.file.id}", {}, developer

      expect(last_response.status).to eq(403)
    end
  end

  # A mount that did not come up is an operator's problem, so say so rather than 404
  # as if the community were unknown.
  describe "with no file store configured" do
    let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }

    it "says the deployment has no file store rather than 404ing" do
      get "/admin/communities/sample/files", {}, admin

      expect(last_response.status).to eq(503)
      expect(body["error"]).to include("no file store")
    end
  end

  describe "with an unavailable configured file store" do
    before do
      File.binwrite(@root, "a regular file cannot be an object-store directory")
      allow(Rubotty::Storage::ObjectStore).to receive(:path_from).with(@root).and_return(@root)
    end

    it "keeps community reads available while reporting file storage as unavailable" do
      get "/admin/communities/sample/files", {}, admin

      expect(last_response.status).to eq(503)
      expect(body).to eq("error" => "this deployment has no file store configured")

      get "/communities/sample", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["slug"]).to eq("sample")
      expect(File.binread(@root)).to eq("a regular file cannot be an object-store directory")
    end

    it "rejects an upload before reading or buffering its body even when its declared length is excessive" do
      source = StringIO.new("finite fixture")
      expect(source).not_to receive(:read)
      env = Rack::MockRequest.env_for("/admin/communities/sample/files", method: "POST",
                                      "CONTENT_TYPE" => "multipart/form-data; boundary=finite",
                                      "HTTP_AUTHORIZATION" => admin.fetch("HTTP_AUTHORIZATION"))
      env["rack.input"] = source
      env["CONTENT_LENGTH"] = (8 * 1024 * 1024 * 1024).to_s

      status, headers, response = app.call(env)
      bytes = +""
      response.each { |chunk| bytes << chunk }

      expect(status).to eq(503)
      expect(headers["content-type"]).to start_with("application/yaml")
      expect(headers["x-rubotty-version"]).to eq(Rubotty::VERSION.to_s)
      expect(YAMLCamel.load(bytes)).to eq("error" => "this deployment has no file store configured")
      expect(Array(env["rack.tempfiles"])).to be_empty
    ensure
      response.close if response&.respond_to?(:close)
    end
  end
end
