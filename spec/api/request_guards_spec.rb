# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/mock"
require "stringio"

RSpec.describe "API request guards", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:issued) { deps.api_keys.issue(scope: "administrator", label: "finite fixture") }
  let(:app) do
    Rubotty::Api::App.assemble(deps: deps, env: {}).tap do |klass|
      klass.post("/request-guard-fixture") do
        yaml_body("decoded_bytes" => write_body_params["data"].to_s.bytesize)
      end
    end
  end
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

  def request(body, path: "/request-guard-fixture", token: nil, length: :actual, type: "application/json", &on_read)
    source = input_class.new(body)
    source.on_read = on_read
    env = Rack::MockRequest.env_for(path, method: "POST", "CONTENT_TYPE" => type)
    env["rack.input"] = source
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    length == :actual ? env["CONTENT_LENGTH"] = body.bytesize.to_s : (length.nil? ? env.delete("CONTENT_LENGTH") : env["CONTENT_LENGTH"] = length.to_s)
    status, headers, response = app.call(env)
    bytes = +""
    response.each { |chunk| bytes << chunk }
    [status, headers, bytes, source, env]
  ensure
    response.close if response&.respond_to?(:close)
    Array(env && env["rack.tempfiles"]).each { |file| file.close! }
  end

  it "rejects a missing bearer credential before reading a finite multipart body" do
    result = request("x" * (512 * 1024), path: "/admin/accounts", type: "multipart/form-data; boundary=finite")

    expect(result[0]).to eq(401)
    expect(YAMLCamel.load(result[2])).to eq("error" => "missing or malformed Authorization header")
    expect(result[3].bytes_read).to eq(0)
    expect(Array(result[4]["rack.tempfiles"])).to be_empty
  end

  it "rejects a revoked bearer credential before reading the body" do
    deps.api_keys.revoke_by_public_id(public_id: issued.key_row.public_id)
    result = request("x" * (512 * 1024), token: issued.token)

    expect(result[0]).to eq(401)
    expect(YAMLCamel.load(result[2])).to eq("error" => "invalid or revoked API key")
    expect(result[3].bytes_read).to eq(0)
  end

  it "does not trust a prefilled environment claim in place of the bearer header" do
    env = Rack::MockRequest.env_for("/request-guard-fixture", method: "POST", input: "finite")
    input = input_class.new("finite")
    env["rack.input"] = input
    env[Rubotty::Api::RequestGuard::CLAIM_KEY] = { marker: app.settings.request_guard_marker, token: issued.token }
    status, _, output = app.call(env)

    expect(status).to eq(401)
    expect(input.bytes_read).to eq(0)
  ensure
    output.close if output&.respond_to?(:close)
  end

  it "revalidates revocation after form parsing without charging or touching twice" do
    allow(deps.rate_limiter).to receive(:record!).and_call_original
    allow(deps.api_keys).to receive(:touch_last_used).and_call_original
    result = request("data=finite", token: issued.token, type: "application/x-www-form-urlencoded") do
      deps.api_keys.revoke_by_public_id(public_id: issued.key_row.public_id)
    end

    expect(result[0]).to eq(401)
    expect(deps.rate_limiter).to have_received(:record!).once
    expect(deps.api_keys).to have_received(:touch_last_used).once
  end

  it "charges a successful request once while checking its credential before and after parsing" do
    allow(deps.api_keys).to receive(:authenticate).and_call_original
    allow(deps.rate_limiter).to receive(:record!).and_call_original
    allow(deps.api_keys).to receive(:touch_last_used).and_call_original

    expect(request('{"data":"finite"}', token: issued.token)[0]).to eq(200)
    expect(deps.api_keys).to have_received(:authenticate).exactly(3).times
    expect(deps.rate_limiter).to have_received(:record!).once
    expect(deps.api_keys).to have_received(:touch_last_used).once
  end

  %w[application/json application/yaml].each do |type|
    it "revalidates a key revoked while reading #{type} before the route uses its parsed body" do
      payload = type == "application/json" ? '{"data":"finite"}' : "data: finite\n"
      result = request(payload, token: issued.token, type: type) do
        deps.api_keys.revoke_by_public_id(public_id: issued.key_row.public_id)
      end

      expect(result[0]).to eq(401)
      expect(YAMLCamel.load(result[2])).to eq("error" => "invalid or revoked API key")
    end
  end

  it "returns a YAML 413 for excessive declared length without reading input" do
    result = request("finite", token: issued.token, length: Rubotty::Api::App::TEXT_BODY_BYTES + 1)

    expect(result[0]).to eq(413)
    expect(result[1]["content-type"]).to start_with("application/yaml")
    expect(YAMLCamel.load(result[2])["error"]).to include("larger")
    expect(result[3].bytes_read).to eq(0)
  end

  it "caps actual unknown-length JSON bytes with the same YAML 413" do
    limit = Rubotty::Api::App::TEXT_BODY_BYTES
    result = request(JSON.generate(data: "x" * limit), token: issued.token, length: nil)

    expect(result[0]).to eq(413)
    expect(YAMLCamel.load(result[2])["error"]).to include("#{limit} bytes")
    expect(result[3].bytes_read).to eq(limit + 1)
  end

  it "keeps room for JSON escaping of a 512-KiB source within the four-MiB budget" do
    source = "\0" * (512 * 1024)
    result = request(JSON.generate(data: source), token: issued.token, length: nil)

    expect(result[0]).to eq(200)
    expect(YAMLCamel.load(result[2])["decoded_bytes"]).to eq(source.bytesize)
  end

  it "denies developer scope before granting a large admin upload budget or reading the body" do
    developer = deps.api_keys.issue(scope: "developer", community: community, label: "finite developer")
    files = instance_double(Rubotty::ControlPlane::RehostedFiles)
    allow(deps).to receive(:rehosted_files).and_return(files)
    expect(files).not_to receive(:policy_for)
    result = request("x" * 1_024, path: "/admin/communities/sample/files", token: developer.token,
                                  length: 8 * 1024 * 1024 * 1024)

    expect(result[0]).to eq(403)
    expect(result[3].bytes_read).to eq(0)
  end

  it "returns the resource 404 before reading an upload for an unknown community" do
    result = request("x" * 1_024, path: "/admin/communities/unknown/files", token: issued.token,
                                  length: 8 * 1024 * 1024 * 1024)

    expect(result[0]).to eq(404)
    expect(YAMLCamel.load(result[2])).to eq("error" => "not found")
    expect(result[3].bytes_read).to eq(0)
  end

  it "enforces admin scope before parsing paths with Sinatra-supported encoded literal characters" do
    developer = deps.api_keys.issue(scope: "developer", community: community, label: "finite developer")
    result = request("x" * 1_024, path: "/%61dmin/communities/sample/%66iles", token: developer.token,
                                  length: 8 * 1024 * 1024 * 1024)

    expect(result[0]).to eq(403)
    expect(result[3].bytes_read).to eq(0)
  end

  it "derives a file budget from the largest configured room policy without reading body fields" do
    files = instance_double(Rubotty::ControlPlane::RehostedFiles)
    allow(deps).to receive(:rehosted_files).and_return(files)
    allow(files).to receive(:policy_for) do |community_id:, room_key:|
      expect(community_id).to eq(community.id)
      { max_bytes: room_key == "general" ? 8 * 1024 * 1024 * 1024 : 1_024 }
    end
    captured = nil
    guard = Rubotty::Api::RequestGuard.new(
      ->(env) { captured = env[Rubotty::Api::RequestGuard::LIMIT_KEY]; [204, {}, []] },
      deps: deps, marker: Object.new, text_limit: Rubotty::Api::App::TEXT_BODY_BYTES,
      envelope_bytes: Rubotty::Api::App::UPLOAD_ENVELOPE_BYTES
    )
    env = Rack::MockRequest.env_for("/admin/communities/sample/files", method: "POST",
                                   "HTTP_AUTHORIZATION" => "Bearer #{issued.token}")

    expect(guard.call(env).first).to eq(204)
    expect(captured).to eq(8 * 1024 * 1024 * 1024 + Rubotty::Api::App::UPLOAD_ENVELOPE_BYTES)
  end
end
