# frozen_string_literal: true

require "spec_helper"
require "rubotty/file_storage"
require "rack/test"
require "stringio"
require "tmpdir"

# {Rubotty::FileStorage::App} has no relationship to the guest portal; the
# download link is its whole capability. The route has two shapes,
# /filestorage/<uuid>.<ext> for every fresh link and /f/<uuid> for one minted
# before that change, so both are mounted here at their real prefixes to prove the split works.
RSpec.describe "the rehosted-file download routes", :control_plane do
  include Rack::Test::Methods

  around do |example|
    with_object_store_root do |root|
      @root = root
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:store) { Rubotty::Storage::Memory.new }
  let(:object_store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:now) { Time.now }
  let(:rehosted_files) do
    Rubotty::ControlPlane::RehostedFiles.new(models: models, store: object_store, clock: -> { now })
  end
  let(:app) do
    files_app = Rubotty::FileStorage::App.assemble(rehosted_files: rehosted_files, logger: Rubotty::Log.null)
    Rack::URLMap.new("/filestorage" => files_app, "/f" => files_app)
  end

  let(:payload) { "a file too big for one of the platforms. " * 2_000 }

  def store_file(**rest)
    rehosted_files.store_file(
      community_id: community.id, room_key: "general", source: StringIO.new(payload),
      filename: "clip.mp4", content_type: "video/mp4", **rest
    )
  end

  describe "GET /filestorage/:token" do
    it "streams the exact bytes back to whoever holds the link" do
      stored = store_file

      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq(payload)
      expect(last_response.headers["Content-Type"]).to include("video/mp4")
      expect(last_response.headers["Content-Disposition"]).to include("clip.mp4")
    end

    # The extension is a courtesy to whoever reads the link, never something the
    # route trusts: the Content-Type above comes from the stored row regardless
    # of what the url's own extension says.
    it "matches the extension without regard to case" do
      stored = store_file

      get "/filestorage/#{stored.secret}.MP4"

      expect(last_response.status).to eq(200)
    end

    # A url whose extension disagrees with what was actually stored is refused
    # outright rather than served under a type nobody checked.
    it "404s a token whose extension does not match what was stored" do
      stored = store_file

      get "/filestorage/#{stored.secret}.jpg"

      expect(last_response.status).to eq(404)
    end

    # No dot to split on falls back to the legacy bare-secret shape, so this
    # 404s for the same reason an unknown legacy token does: no such file.
    it "404s a token with no extension that also names no file" do
      get "/filestorage/#{SecureRandom.uuid}"

      expect(last_response.status).to eq(404)
    end

    # A link is a bearer capability, so a shared cache would hand the file on.
    it "marks the response private rather than cacheable by a proxy" do
      stored = store_file

      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.headers["Cache-Control"]).to include("private")
    end

    it "404s an unknown token, revealing nothing" do
      get "/filestorage/#{SecureRandom.uuid}.mp4"

      expect(last_response.status).to eq(404)
    end

    # An expired file answers exactly as one that never existed does.
    it "404s a file past its retention, before the daily job has even run" do
      stored = store_file(ttl_days: 1)
      models.rehosted_file[stored.file.id].update(expires_at: Time.now - 60)

      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(404)
    end

    it "404s once the file has actually been deleted" do
      stored = store_file
      rehosted_files.forget(models.rehosted_file[stored.file.id])

      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(404)
    end
  end

  # The pre-existing shape, kept resolving for a link minted before this
  # route existed. No extension in the path here, and none checked: this is
  # exactly the behaviour the route had before.
  describe "GET /f/:token" do
    it "streams the exact bytes back to whoever holds the link" do
      stored = store_file

      get "/f/#{stored.secret}"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq(payload)
      expect(last_response.headers["Content-Type"]).to include("video/mp4")
      expect(last_response.headers["Content-Disposition"]).to include("clip.mp4")
    end

    # A link is a bearer capability, so a shared cache would hand the file on.
    it "marks the response private rather than cacheable by a proxy" do
      stored = store_file

      get "/f/#{stored.secret}"

      expect(last_response.headers["Cache-Control"]).to include("private")
    end

    it "404s an unknown token, revealing nothing" do
      get "/f/#{SecureRandom.uuid}"

      expect(last_response.status).to eq(404)
    end

    # An expired file answers exactly as one that never existed does.
    it "404s a file past its retention, before the daily job has even run" do
      stored = store_file(ttl_days: 1)
      models.rehosted_file[stored.file.id].update(expires_at: Time.now - 60)

      get "/f/#{stored.secret}"

      expect(last_response.status).to eq(404)
    end

    it "404s once the file has actually been deleted" do
      stored = store_file
      rehosted_files.forget(models.rehosted_file[stored.file.id])

      get "/f/#{stored.secret}"

      expect(last_response.status).to eq(404)
    end
  end

  # Requests here all land after PREVIEW_GRACE_SECONDS has passed, served by a
  # second RehostedFiles reading the same rows through a clock set that far
  # ahead, exactly the way spec/control_plane/rehosted_files_spec.rb ages a
  # row for its own expiry examples.
  describe "the serve ceiling" do
    let(:later) do
      Rubotty::ControlPlane::RehostedFiles.new(
        models: models, store: object_store,
        clock: -> { now + Rubotty::ControlPlane::RehostedFiles::PREVIEW_GRACE_SECONDS + 1 }
      )
    end
    let(:app) do
      files_app = Rubotty::FileStorage::App.assemble(rehosted_files: later, logger: Rubotty::Log.null)
      Rack::URLMap.new("/filestorage" => files_app, "/f" => files_app)
    end

    it "serves normally and counts against the ceiling" do
      stored = store_file(serve_limit: 3)

      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(200)
      expect(models.rehosted_file[stored.file.id].served_count).to eq(1)
    end

    it "404s once the ceiling is spent, the same as an unknown token" do
      stored = store_file(serve_limit: 1)
      get "/filestorage/#{stored.secret}.mp4"

      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(404)
    end

    # An exhausted link must reveal nothing a wrong secret would not: no
    # filename, no size, nothing naming the file at all.
    it "leaks no header naming the file once exhausted" do
      stored = store_file(serve_limit: 1)
      get "/filestorage/#{stored.secret}.mp4"

      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.headers["Content-Disposition"]).to be_nil
      expect(last_response.headers["Content-Length"]).not_to eq(payload.bytesize.to_s)
    end

    it "does not spend a serve on a HEAD request" do
      stored = store_file(serve_limit: 1)

      head "/filestorage/#{stored.secret}.mp4"
      head "/filestorage/#{stored.secret}.mp4"
      head "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(200)
      expect(models.rehosted_file[stored.file.id].served_count).to eq(0)
    end

    it "still refuses a HEAD once the ceiling is already spent by real GETs" do
      stored = store_file(serve_limit: 1)
      get "/filestorage/#{stored.secret}.mp4"

      head "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(404)
    end
  end

  # A request landing inside PREVIEW_GRACE_SECONDS of the row's own creation
  # is treated as a platform building a link preview, not a member's
  # download, so it does not spend the link's budget.
  describe "the preview-fetch grace window" do
    it "does not spend a serve for a request right after the link is posted" do
      stored = store_file(serve_limit: 1)

      get "/filestorage/#{stored.secret}.mp4"
      get "/filestorage/#{stored.secret}.mp4"
      get "/filestorage/#{stored.secret}.mp4"

      expect(last_response.status).to eq(200)
      expect(models.rehosted_file[stored.file.id].served_count).to eq(0)
    end
  end

  describe "when the object store is not usable" do
    let(:object_store) do
      FileUtils.mkdir_p(@root)
      File.binwrite(File.join(@root, "stray.bin"), "an unmounted volume looks like this")
      Rubotty::Storage::ObjectStore.new(root: @root)
    end

    it "404s rather than raise" do
      get "/filestorage/#{SecureRandom.uuid}.bin"
      expect(last_response.status).to eq(404)

      get "/f/#{SecureRandom.uuid}"
      expect(last_response.status).to eq(404)
    end
  end

  describe "when the deployment has no rehosted-files store at all" do
    let(:app) do
      files_app = Rubotty::FileStorage::App.assemble(rehosted_files: nil, logger: Rubotty::Log.null)
      Rack::URLMap.new("/filestorage" => files_app, "/f" => files_app)
    end

    it "404s rather than raise" do
      get "/filestorage/#{SecureRandom.uuid}.bin"
      expect(last_response.status).to eq(404)
    end
  end
end
