# frozen_string_literal: true

require "spec_helper"
require "rubotty/guest_portal"
require "rack/test"
require "json"
require "stringio"
require "tmpdir"

# The browser upload flow a /upload ticket names: /u/:token to show the form
# and accept a whole batch. It lives on the guest portal's app since that is
# already the public, token-gated surface building every capability URL off
# GUEST_PORTAL_URL. The download link is served separately, by {Rubotty::FileStorage::App}.
RSpec.describe "the /upload flow", :control_plane do
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

  let(:deps) do
    Rubotty::GuestPortal::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: @root)
  end
  let(:app) { Rubotty::GuestPortal::App.assemble(deps: deps, env: {}) }

  let(:tickets) { deps.upload_tickets }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  # The feature is off by default, so the room is switched on before any upload is
  # accepted at all.
  before { controls.enable(community: community, selector: "general", feature: "file_rehosting") }

  def issue
    tickets.issue(community_id: community.id, room_key: "general", endpoint_key: "tg-general",
                  adapter: :telegram, native_id: "55", label: "Ada")
  end

  def uploaded_file(bytes, filename)
    file = Tempfile.new("upload")
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: filename)
  end

  def upload(token, bytes: "hello from a browser", filename: "notes.txt")
    post "/u/#{token}", "file" => [uploaded_file(bytes, filename)]
  end

  def upload_many(token, specs)
    post "/u/#{token}", "file" => specs.map { |bytes, filename| uploaded_file(bytes, filename) }
  end

  it "shows the form for a live ticket" do
    issued = issue

    get "/u/#{issued.token}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("Upload files")
  end

  it "states the per file, count and total limits on the form" do
    issued = issue
    mib = 1024 * 1024
    per_file = Rubotty::ControlPlane::RehostedFiles::DEFAULT_MAX_BYTES / mib
    count = Rubotty::ControlPlane::RehostedFiles::DEFAULT_MAX_BATCH_FILES
    total = per_file * Rubotty::ControlPlane::RehostedFiles::DEFAULT_BATCH_BYTES_MULTIPLIER

    get "/u/#{issued.token}"

    expect(last_response.body).to include("#{per_file} MB")
    expect(last_response.body).to include("#{count} files")
    expect(last_response.body).to include("#{total} MB")
  end

  it "stores what the browser sent and mints its download link" do
    issued = issue

    upload(issued.token)

    expect(last_response.status).to eq(200)
    expect(models.rehosted_file.count).to eq(1)
    link = last_response.body[%r{/filestorage/[0-9a-f-]{36}\.\w+}]
    expect(link).not_to be_nil
  end

  it "files it against the ticket's own community and room, not anything the browser said" do
    issued = issue
    upload(issued.token)
    row = models.rehosted_file.first

    expect(row.community_id).to eq(community.id)
    expect(row.room_key).to eq("general")
    expect(row.source).to eq("upload")
  end

  # A link somebody forwarded must not be a second way in.
  it "refuses a second upload on the same ticket" do
    issued = issue
    upload(issued.token)

    upload(issued.token, bytes: "a second file")

    expect(last_response.status).to eq(410)
    expect(models.rehosted_file.count).to eq(1)
  end

  it "refuses an unknown or expired ticket" do
    get "/u/not-a-real-ticket"
    expect(last_response.status).to eq(410)

    issued = issue
    models.rehosted_upload_ticket[issued.ticket.id].update(expires_at: Time.now - 60)
    upload(issued.token)
    expect(last_response.status).to eq(410)
    expect(models.rehosted_file.count).to be_zero
  end

  it "refuses a post with no file at all" do
    issued = issue

    post "/u/#{issued.token}"

    expect(last_response.status).to eq(422)
  end

  describe "a multi file selection" do
    it "stores every file as one batch, spending the ticket once" do
      issued = issue

      upload_many(issued.token, [["one", "one.txt"], ["two", "two.txt"], ["three", "three.txt"]])

      expect(last_response.status).to eq(200)
      expect(models.rehosted_file.count).to eq(3)
      expect(models.rehosted_file.order(:id).select_map(:filename)).to eq(%w[one.txt two.txt three.txt])
    end

    it "hands the batch to the announcer in selection order" do
      issued = issue
      upload_many(issued.token, [["one", "one.txt"], ["two", "two.txt"]])
      ticket = models.rehosted_upload_ticket[issued.ticket.id]

      pending = JSON.parse(ticket.pending_files)
      files = pending.map { |entry| models.rehosted_file[entry["file_id"]].filename }
      expect(files).to eq(%w[one.txt two.txt])
    end

    it "refuses a selection over the batch file count" do
      issued = issue
      controls.set(community: community, selector: "general", feature: "file_rehosting",
                   key: "max_batch_files", value: 2)

      upload_many(issued.token, [["a", "a.txt"], ["b", "b.txt"], ["c", "c.txt"]])

      expect(last_response.status).to eq(422)
      expect(models.rehosted_file.count).to be_zero
    end

    it "refuses a selection over the batch byte total, before storing anything" do
      issued = issue
      controls.set(community: community, selector: "general", feature: "file_rehosting",
                   key: "max_batch_bytes", value: 10)

      upload_many(issued.token, [["12345", "a.txt"], ["12345", "b.txt"], ["12345", "c.txt"]])

      expect(last_response.status).to eq(413)
      expect(models.rehosted_file.count).to be_zero
    end

    it "posts the files that stored, with a note naming the ones that did not" do
      issued = issue
      # max_bytes=4 fails the second file alone; the default batch total (3x
      # that, 12) still admits both, so this exercises the per-file failure
      # rather than the upfront batch-total refusal.
      controls.set(community: community, selector: "general", feature: "file_rehosting",
                   key: "max_bytes", value: 4)

      upload_many(issued.token, [["ok", "ok.txt"], ["1234567", "big.txt"]])

      expect(last_response.status).to eq(200)
      expect(models.rehosted_file.count).to eq(1)
      expect(models.rehosted_file.first.filename).to eq("ok.txt")
      expect(last_response.body).to include("big.txt")

      ticket = models.rehosted_upload_ticket[issued.ticket.id]
      expect(JSON.parse(ticket.pending_failed)).to eq(["big.txt"])
    end

    it "refuses the batch outright when every file in it is too large" do
      issued = issue
      # Both files exceed max_bytes=2, but their combined 6 bytes still sits
      # at the default batch total (3x that, also 6), so this reaches the
      # "nothing stored" path rather than the upfront batch-total refusal.
      controls.set(community: community, selector: "general", feature: "file_rehosting",
                   key: "max_bytes", value: 2)

      upload_many(issued.token, [["abc", "a.txt"], ["def", "b.txt"]])

      expect(last_response.status).to eq(413)
      expect(models.rehosted_file.count).to be_zero
    end
  end

  # The web process holds no snapshot and reads feature_settings itself, or /upload
  # becomes a way around every setting an operator made.
  describe "the community's own settings" do
    it "refuses once an operator has switched the feature back off" do
      issued = issue
      controls.disable(community: community, selector: "general", feature: "file_rehosting")

      upload(issued.token)

      expect(last_response.status).to eq(410)
      expect(models.rehosted_file.count).to be_zero
    end

    it "honours the community's own cap rather than this app's default" do
      controls.set(community: community, selector: "general", feature: "file_rehosting",
                   key: "max_bytes", value: 8)
      issued = issue

      upload(issued.token, bytes: "far more than eight bytes")

      expect(last_response.status).to eq(413)
      expect(models.rehosted_file.count).to be_zero
    end

    it "honours the community's own retention" do
      controls.set(community: community, selector: "general", feature: "file_rehosting",
                   key: "retention_days", value: 2)
      issued = issue

      upload(issued.token)
      row = models.rehosted_file.first

      expect(row.expires_at.to_time - row.created_at.to_time).to be_within(60).of(2 * 86_400)
    end

    it "derives the batch total from a raised per file cap when none is set explicitly" do
      controls.set(community: community, selector: "general", feature: "file_rehosting",
                   key: "max_bytes", value: 500 * 1024 * 1024)
      issued = issue

      get "/u/#{issued.token}"

      expect(last_response.body).to include("500 MB")
      expect(last_response.body).to include("1500 MB")
    end
  end

  # The web process has no adapters, so it records the hand-off and the bot posts.
  it "hands the finished upload to the bot to post, with the secrets held only until it does" do
    issued = issue
    upload(issued.token)
    ticket = models.rehosted_upload_ticket[issued.ticket.id]

    pending = JSON.parse(ticket.pending_files)
    expect(pending.size).to eq(1)
    expect(pending.first["file_id"]).to eq(models.rehosted_file.first.id)
    expect(pending.first["secret"]).not_to be_nil

    announcer = Rubotty::ControlPlane::UploadAnnouncer.new(models: models, logger: Rubotty::Log.null)
    announcer.deliver(ticket)

    expect(ticket.reload.pending_files).to eq("[]")
  end

  describe "when the object store is not usable" do
    let(:deps) do
      FileUtils.mkdir_p(@root)
      File.binwrite(File.join(@root, "stray.bin"), "an unmounted volume looks like this")
      Rubotty::GuestPortal::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: @root)
    end

    # A mount that did not come up must not take the guest chat down with it.
    it "leaves the guest chat alive" do
      get "/"
      expect(last_response.status).to eq(200)
    end

    # A guest upload goes to the same store, so it is off too, and the POST answers 503
    # rather than 404 because somebody is standing there waiting to be told to retry.
    it "refuses a guest upload with a reason, and serves none" do
      room = models.room.where(community_id: community.id, room_key: "general").first
      Rubotty::ControlPlane::FeatureControls.new(models: models)
                                            .enable(community: community, selector: "general",
                                                    feature: "guest_portal")
      issued = deps.invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600)

      post "/g/#{issued.token}/upload", file: Rack::Test::UploadedFile.new(
        StringIO.new("PNGDATA"), "image/png", original_filename: "shot.png"
      )
      expect(last_response.status).to eq(503)

      get "/uploads/#{SecureRandom.uuid}"
      expect(last_response.status).to eq(404)
    end
  end
end
