# frozen_string_literal: true

require "spec_helper"

# The SSRF guard has to validate the answer that is actually connected to,
# not just the answer it resolved once. WebhookPump let Net::HTTP re-resolve
# the hostname when opening the socket, so a short-TTL rebinding attacker
# could answer public to the guard and loopback or metadata to the connection.
RSpec.describe Rubotty::ControlPlane::WebhookPump, "a rebinding subscriber", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:now) { Time.local(2026, 7, 30, 12, 0, 0) }
  let(:clock) { -> { now } }

  let(:webhooks) { Rubotty::ControlPlane::Webhooks.new(models: models, logger: Rubotty::Log.null, clock: clock) }

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

  let(:pump) do
    described_class.new(webhooks: webhooks, models: models, logger: Rubotty::Log.null, clock: clock,
                        resolver: rebinding_resolver)
  end

  def subscribe!
    webhooks.create(community_id: community.id, url: "https://rebind.example/hook",
                    event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED])
  end

  def emit!
    webhooks.emit(community_id: community.id, event_type: Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED,
                  room_key: "general", data: { "room_key" => "general", "body" => "hi" })
  end

  # The durable job row the scheduler would hand the pump.
  def pump_job(subscription_id)
    Rubotty::Core::DurableSchedulerStore::Row.new(
      id: 1, kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND,
      payload: { "subscription_id" => subscription_id }, status: "claimed", attempts: 0
    )
  end

  def delivery_row(created)
    db[:webhook_deliveries].where(subscription_id: created.row.id).order(:id).first
  end

  # Records what the connection was pinned to, standing in for the socket.
  let(:pinned) { [] }

  def stub_http!
    response = streaming_response("", "text/plain")
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:ipaddr=) { |value| pinned << value }
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request) { |_req, &block| block ? block.call(response) : response }
    http
  end

  it "connects to the address the guard validated, not to a fresh lookup" do
    created = subscribe!
    emit!
    stub_http!

    pump.call(pump_job(created.row.id))

    expect(pinned).to eq(["93.184.216.34"])
  end

  it "resolves the name exactly once, so there is no second answer to swap" do
    created = subscribe!
    emit!
    stub_http!

    pump.call(pump_job(created.row.id))

    expect(lookups).to eq(["rebind.example"])
  end

  # The hostname stays on the connection, so the Host header, TLS SNI and the
  # webhook signature verification are all still about the name rather than
  # the pinned IP.
  it "keeps the hostname on the connection for Host and SNI" do
    created = subscribe!
    emit!
    stub_http!

    pump.call(pump_job(created.row.id))

    expect(Net::HTTP).to have_received(:new).with("rebind.example", 443)
  end

  it "records the delivery as landed, so the fix does not just fail differently" do
    created = subscribe!
    emit!
    stub_http!

    pump.call(pump_job(created.row.id))

    expect(delivery_row(created)[:status]).to eq("delivered")
  end

  # The guard itself still refuses outright when the FIRST answer is private,
  # which is the case it always caught.
  it "still refuses a subscriber whose only answer is private" do
    created = subscribe!
    emit!
    allow(Net::HTTP).to receive(:new) { raise "should never open a connection" }
    private_only = ->(_host) { ["169.254.169.254"] }
    refusing_pump = described_class.new(webhooks: webhooks, models: models, logger: Rubotty::Log.null,
                                        clock: clock, resolver: private_only)

    refusing_pump.call(pump_job(created.row.id))

    row = delivery_row(created)
    expect(row[:status]).to eq("queued")
    expect(row[:last_error]).to include("refused")
  end
end
