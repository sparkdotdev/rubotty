# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The size cap has to be applied as bytes arrive, not after the fact. perform does build a
# MediaFetcher with limit: MAX_BYTES, but only the address guard was ever borrowed from it:
# the request buffered the whole body and the cap was applied afterwards, by which point a
# 24 MiB answer was already resident.
RSpec.describe Rubotty::Scripting::Endpoints, "the response size cap", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:resolver) { ->(_host) { ["93.184.216.34"] } }

  subject(:endpoints) do
    described_class.new(models: models, logger: Rubotty::Log.null, resolver: resolver,
                        executor: ->(work) { work.call })
  end

  def define!
    now = Time.now
    models.script_endpoint.create(
      community_id: community.id, name: "big", url: "https://api.example.com/big",
      http_method: "GET", allow_sync: true, timeout_seconds: 2, cache_seconds: 0,
      enabled: true, created_at: now, updated_at: now
    )
  end

  # Counts what the caller actually pulled off the socket, which is the number
  # the old code got wrong: it read everything and then cut the result.
  let(:delivered) { [] }

  def oversized_response(total_bytes, chunk: 64 * 1024)
    response = instance_double(Net::HTTPResponse, code: "200")
    allow(response).to receive(:[]).with("content-type").and_return("text/plain")
    allow(response).to receive(:read_body) do |&block|
      sent = 0
      while sent < total_bytes
        piece = "x" * [chunk, total_bytes - sent].min
        delivered << piece.bytesize
        block.call(piece)
        sent += piece.bytesize
      end
    end
    response
  end

  def call_against(response)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request) { |_req, &block| block.call(response) }
    produced = nil
    endpoints.enqueue(community, "big", {}) { |job| produced = job.call }
    produced
  end

  let(:cap) { Rubotty::Scripting::Endpoints::MAX_BYTES }

  it "hands the script no more than the cap" do
    define!
    result = call_against(oversized_response(24 * 1024 * 1024))

    expect(result.body.bytesize).to eq(cap)
  end

  # The load-bearing one. The old code read all 24 MiB before cutting; this
  # asserts the reading stopped, not just that the answer was trimmed.
  it "stops pulling bytes once it is past the cap" do
    define!
    call_against(oversized_response(24 * 1024 * 1024))

    expect(delivered.sum).to be < (cap * 2)
  end

  it "leaves a response inside the cap completely alone" do
    define!
    result = call_against(oversized_response(1024))

    expect(result.body.bytesize).to eq(1024)
    expect(delivered.sum).to eq(1024)
  end

  it "still reports the status and format of an oversized answer" do
    define!
    result = call_against(oversized_response(4 * 1024 * 1024))

    expect(result.status).to eq(200)
    expect(result.ok).to be(true)
    expect(result.format).to eq("text")
  end
end
