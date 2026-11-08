# frozen_string_literal: true

require "spec_helper"
require "rubotty/guest_portal"
require "rack/mock"
require "stringio"
require "uri"

RSpec.describe "guest request guards", :control_plane do
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
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:deps) { Rubotty::GuestPortal::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: @root) }
  let(:app) { Rubotty::GuestPortal::App.assemble(deps: deps, env: { "GUEST_PORTAL_URL" => "https://guest.example" }) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:input_class) do
    Class.new(StringIO) do
      attr_reader :bytes_read
      attr_accessor :on_read
      def initialize(body)
        super(body.b)
        @bytes_read = 0
      end
      def read(*args)
        if on_read
          callback, self.on_read = on_read, nil
          callback.call
        end
        super.tap { |bytes| @bytes_read += bytes.to_s.bytesize }
      end
    end
  end

  before do
    controls.enable(community: community, selector: "general", feature: "guest_portal")
    controls.enable(community: community, selector: "general", feature: "file_rehosting")
  end

  def invite
    deps.invites.issue(community: community, room: room, nickname: "Finite guest", ttl_seconds: 3_600)
  end

  def ticket
    deps.upload_tickets.issue(community_id: community.id, room_key: "general", endpoint_key: "tg-general",
                              adapter: :telegram, native_id: "55", label: "Finite user")
  end

  def multipart(bytes)
    "--finite\r\nContent-Disposition: form-data; name=\"file\"; filename=\"fixture.bin\"\r\n" \
      "Content-Type: application/octet-stream\r\n\r\n#{bytes}\r\n--finite--\r\n"
  end

  def request(path, body, type: "application/x-www-form-urlencoded", length: :actual, &on_read)
    input = input_class.new(body)
    input.on_read = on_read
    env = Rack::MockRequest.env_for(path, method: "POST", "CONTENT_TYPE" => type)
    env["rack.input"] = input
    length == :actual ? env["CONTENT_LENGTH"] = body.bytesize.to_s : (length.nil? ? env.delete("CONTENT_LENGTH") : env["CONTENT_LENGTH"] = length.to_s)
    status, headers, output = app.call(env)
    bytes = +""
    output.each { |chunk| bytes << chunk }
    [status, headers, bytes, input, env]
  ensure
    output.close if output&.respond_to?(:close)
    Array(env && env["rack.tempfiles"]).each { |file| file.close! }
  end

  %w[messages upload].each do |suffix|
    it "rejects an invalid invite on #{suffix} before reading a multipart body" do
      result = request("/g/unknown/#{suffix}", multipart("x" * (512 * 1024)), type: "multipart/form-data; boundary=finite")

      expect(result[0]).to eq(410)
      expect(JSON.parse(result[2])).to eq("ended" => true, "error" => "This guest session has ended.")
      expect(result[3].bytes_read).to eq(0)
      expect(Array(result[4]["rack.tempfiles"])).to be_empty
    end
  end

  it "preserves the exact ended-ticket HTML without reading or claiming a ticket" do
    status, _, output = app.call(Rack::MockRequest.env_for("/u/unknown"))
    expected = +""
    output.each { |part| expected << part }
    output.close if output.respond_to?(:close)
    expect(status).to eq(410)
    expect(deps.upload_tickets).not_to receive(:claim)

    result = request("/u/unknown", multipart("x" * (512 * 1024)), type: "multipart/form-data; boundary=finite")

    expect(result[0]).to eq(410)
    expect(result[2]).to eq(expected)
    expect(result[3].bytes_read).to eq(0)
    expect(Array(result[4]["rack.tempfiles"])).to be_empty
  end

  it "checks an invite before parsing Sinatra-supported encoded route literals" do
    result = request("/%67/unknown/%6dessages", multipart("x" * (512 * 1024)), type: "multipart/form-data; boundary=finite")

    expect(result[0]).to eq(410)
    expect(result[3].bytes_read).to eq(0)
    expect(Array(result[4]["rack.tempfiles"])).to be_empty
  end

  it "uses a small actual-byte budget for valid text forms with no declared length" do
    issued = invite
    limit = Rubotty::GuestPortal::App::TEXT_BODY_BYTES
    result = request("/g/#{issued.token}/messages", "body=#{'x' * limit}", length: nil)

    expect(result[0]).to eq(413)
    expect(result[3].bytes_read).to eq(limit + 1)
    expect(models.guest_message.count).to eq(0)
  end

  it "accepts a full-size UTF-8 message even when URL encoding expands it" do
    issued = invite
    body = "💬" * Rubotty::GuestPortal::App::MAX_BODY
    encoded = URI.encode_www_form(body: body)
    expect(encoded.bytesize).to be < Rubotty::GuestPortal::App::TEXT_BODY_BYTES

    result = request("/g/#{issued.token}/messages", encoded, length: nil)

    expect(result[0]).to eq(201)
    expect(models.guest_message.first.body).to eq(body)
  end

  it "rechecks an invite revoked during form parsing before recording a message" do
    issued = invite
    result = request("/g/#{issued.token}/messages", "body=finite") do
      deps.invites.revoke(invite: issued.invite)
    end

    expect(result[0]).to eq(410)
    expect(models.guest_message.count).to eq(0)
  end

  it "does not burn a live upload ticket when actual multipart bytes exceed its policy budget" do
    controls.set(community: community, selector: "general", feature: "file_rehosting", key: "max_batch_bytes", value: 128 * 1024)
    controls.set(community: community, selector: "general", feature: "file_rehosting", key: "max_batch_files", value: 1)
    issued = ticket
    limit = 128 * 1024 + Rubotty::GuestPortal::App::UPLOAD_ENVELOPE_BYTES
    expect(deps.upload_tickets).not_to receive(:claim)

    result = request("/u/#{issued.token}", multipart("x" * (limit + 1)),
                     type: "multipart/form-data; boundary=finite", length: nil)

    expect(result[0]).to eq(413)
    expect(result[3].bytes_read).to eq(limit + 1)
    expect(deps.upload_tickets.authenticate(token: issued.token)).not_to be_nil
    expect(models.rehosted_file.count).to eq(0)
    expect(result[4]["rack.tempfiles"]).to eq([])
  end

  it "preserves a ticket's raised upload policy and only authenticates in the precheck" do
    controls.set(community: community, selector: "general", feature: "file_rehosting", key: "max_bytes", value: 8 * 1024 * 1024 * 1024)
    issued = ticket
    policy = deps.rehosted_files.policy_for(community_id: community.id, room_key: "general")
    captured = nil
    expect(deps.upload_tickets).not_to receive(:claim)
    guard = Rubotty::GuestPortal::RequestGuard.new(
      ->(env) { captured = env[Rubotty::GuestPortal::RequestGuard::LIMIT_KEY]; [204, {}, []] },
      deps: deps, marker: Object.new, text_limit: Rubotty::GuestPortal::App::TEXT_BODY_BYTES,
      upload_limit: Rubotty::GuestPortal::App::MAX_UPLOAD_BYTES + Rubotty::GuestPortal::App::UPLOAD_ENVELOPE_BYTES,
      envelope_bytes: Rubotty::GuestPortal::App::UPLOAD_ENVELOPE_BYTES
    )

    expect(guard.call(Rack::MockRequest.env_for("/u/#{issued.token}", method: "POST")).first).to eq(204)
    expect(captured).to eq(policy[:max_batch_bytes] + policy[:max_batch_files] * Rubotty::GuestPortal::App::UPLOAD_ENVELOPE_BYTES)
    expect(captured).to be > Rubotty::GuestPortal::App::MAX_TICKET_BATCH_BODY_BYTES / 2
    expect(deps.upload_tickets.authenticate(token: issued.token)).not_to be_nil
  end
end
