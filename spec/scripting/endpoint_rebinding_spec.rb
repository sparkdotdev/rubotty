# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The SSRF guard has to validate the answer that is actually connected to. guard_public_address!
# resolved the hostname and refused a private answer, but Net::HTTP.new(uri.host, ...) then
# resolved the same name again when it opened the socket: a name with a very short TTL could
# answer public to the guard and 127.0.0.1 or the cloud metadata address to the connection.
RSpec.describe Rubotty::Scripting::Endpoints, "a rebinding name", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }

  # Answers public once, to the guard, and would answer loopback to anything
  # that asked a second time. Recorded so the spec can prove there was no
  # second lookup at all.
  let(:lookups) { [] }
  let(:rebinding_resolver) do
    lambda do |host|
      lookups << host
      lookups.length == 1 ? ["93.184.216.34"] : ["127.0.0.1"]
    end
  end

  subject(:endpoints) do
    described_class.new(models: models, logger: Rubotty::Log.null, resolver: rebinding_resolver,
                        executor: ->(work) { work.call })
  end

  def define!
    now = Time.now
    models.script_endpoint.create(
      community_id: community.id, name: "weather", url: "https://rebind.example/w",
      http_method: "GET", allow_sync: true, timeout_seconds: 2, cache_seconds: 0,
      enabled: true, created_at: now, updated_at: now
    )
  end

  # Records what the connection was pinned to, standing in for the socket.
  let(:pinned) { [] }

  def stub_http!
    response = streaming_response("---\nsecret: no\n", "application/yaml")
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:ipaddr=) { |value| pinned << value }
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request) { |_req, &block| block ? block.call(response) : response }
    http
  end

  def call!
    produced = nil
    endpoints.enqueue(community, "weather", {}) { |job| produced = job.call }
    produced
  end

  it "connects to the address the guard validated, not to a fresh lookup" do
    define!
    stub_http!

    call!

    expect(pinned).to eq(["93.184.216.34"])
  end

  it "resolves the name exactly once, so there is no second answer to swap" do
    define!
    stub_http!

    call!

    expect(lookups).to eq(["rebind.example"])
  end

  # The hostname stays on the connection, so the Host header, TLS SNI and
  # certificate verification are all still about the name rather than the IP.
  it "keeps the hostname on the connection for Host and SNI" do
    define!
    stub_http!

    call!

    expect(Net::HTTP).to have_received(:new).with("rebind.example", 443)
  end

  # The guard itself still refuses outright when the FIRST answer is private,
  # which is the case it always caught.
  it "still refuses a name whose only answer is private" do
    define!
    allow(Net::HTTP).to receive(:new) { raise "should never open a connection" }
    private_only = ->(_host) { ["127.0.0.1"] }
    endpoints = described_class.new(models: models, logger: Rubotty::Log.null, resolver: private_only,
                                    executor: ->(work) { work.call })

    expect do
      endpoints.enqueue(community, "weather", {}) { |job| job.call }
    end.to raise_error(described_class::Refused, /non public/)
  end
end
