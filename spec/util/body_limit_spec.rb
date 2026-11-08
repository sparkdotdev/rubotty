# frozen_string_literal: true

require "spec_helper"
require "rubotty"
require "rack/test"

# Sinatra parses params before its own filters run, so a route-level size check
# happens after Rack has written the whole multipart body to a tempfile. This has
# to be middleware to be early enough.
RSpec.describe Rubotty::Util::BodyLimit do
  include Rack::Test::Methods

  let(:reached) { [] }
  let(:inner) { ->(env) { reached << env["PATH_INFO"] and [200, { "content-type" => "text/plain" }, ["ok"]] } }
  let(:app) do
    described_class.new(inner, max: 1_000, rules: [[%r{\A/g/[^/]+/upload\z}, 100]])
  end

  it "passes a body under the ceiling through" do
    post "/anything", "x" * 500

    expect(last_response.status).to eq(200)
    expect(reached).to eq(["/anything"])
  end

  it "refuses a body over the ceiling without reaching the app" do
    post "/anything", "x" * 1_001

    expect(last_response.status).to eq(413)
    expect(reached).to be_empty
  end

  it "applies a tighter rule to the path it names" do
    post "/g/abc/upload", "x" * 500

    expect(last_response.status).to eq(413)
    expect(reached).to be_empty
  end

  it "leaves a path no rule names on the default ceiling" do
    post "/g/abc/other", "x" * 500

    expect(last_response.status).to eq(200)
  end

  it "decides on the declared length alone, without reading the body" do
    post "/anything", "x" * 10, "CONTENT_LENGTH" => "999999"

    expect(last_response.status).to eq(413)
    expect(reached).to be_empty
  end

  it "passes a request with no declared length through, since there is nothing to compare" do
    get "/anything"

    expect(last_response.status).to eq(200)
  end

  it "names the ceiling in the refusal, so an operator can tell what it hit" do
    post "/g/abc/upload", "x" * 500

    expect(last_response.body).to include("100 bytes")
  end
end
