# frozen_string_literal: true

require "spec_helper"
require "yamlcamel"

# The pump is driven directly rather than through a running scheduler thread,
# so nothing here waits on wall time.
RSpec.describe Rubotty::ControlPlane::Webhooks, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  # Local rather than UTC on purpose: every DateTime column here is a naive
  # local timestamp, so a UTC clock would read its own writes back shifted by
  # the machine's offset and the overlap window would look already closed.
  let(:now) { Time.local(2026, 7, 30, 12, 0, 0) }
  let(:clock) { -> { @now ||= now } }
  subject(:webhooks) { described_class.new(models: models, logger: Rubotty::Log.null, clock: clock) }

  # Move the injected clock, so a backoff can be waited out without sleeping.
  def travel(seconds)
    @now = (@now || now) + seconds
  end

  def subscribe(url: "https://example.invalid/hook", **rest)
    webhooks.create(community_id: community.id, url: url,
                    event_types: [described_class::MESSAGE_RELAYED], **rest)
  end

  def emit(body: "hello", room_key: "general")
    webhooks.emit(community_id: community.id, event_type: described_class::MESSAGE_RELAYED,
                  room_key: room_key, data: { "room_key" => room_key, "body" => body })
  end

  # A stand-in subscriber: records every request and answers from a script, so
  # a spec can make one endpoint fail without touching the network.
  class FakeEndpoint
    Response = Struct.new(:code, :body)

    attr_reader :requests

    def initialize(codes: nil)
      @codes = codes
      @requests = []
    end

    def to_proc
      lambda do |uri, headers, body|
        @requests << { uri: uri, headers: headers, body: body }
        code = @codes.is_a?(Array) ? (@codes.shift || "200") : (@codes || "200")
        raise Errno::ECONNREFUSED if code == :refused

        Response.new(code.to_s, "")
      end
    end
  end

  def pump_for(endpoint)
    Rubotty::ControlPlane::WebhookPump.new(
      webhooks: webhooks, models: models, logger: Rubotty::Log.null,
      http: endpoint.to_proc, clock: clock,
      # The SSRF guard resolves the host for real otherwise, and
      # example.invalid does not resolve. The guard has its own example below.
      resolver: ->(_host) { ["93.184.216.34"] }
    )
  end

  describe "the signature" do
    Sig = Rubotty::ControlPlane::WebhookSignature

    # The published vector from the Standard Webhooks spec. If this drifts,
    # off-the-shelf verification libraries stop agreeing with us.
    it "matches the Standard Webhooks reference vector" do
      signature = Sig.sign(
        secret: "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw",
        id: "msg_p5jXN8AQM9LWM0D4loKWxJek", timestamp: 1_614_265_330,
        payload: '{"test": 2432232314}'
      )

      expect(signature).to eq("v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
    end

    it "signs the id, the timestamp and the body together" do
      expect(Sig.signed_content(id: "msg_1", timestamp: 42, payload: "body"))
        .to eq("msg_1.42.body")
    end

    it "sends something the subscriber can verify with the secret alone" do
      created = subscribe
      emit(body: "watched")
      endpoint = FakeEndpoint.new
      pump_for(endpoint).call(pump_job(created.row.id))

      sent = endpoint.requests.first
      expect(Sig.verify(secret: created.secret, id: sent[:headers]["webhook-id"],
                        timestamp: sent[:headers]["webhook-timestamp"].to_i,
                        payload: sent[:body], header: sent[:headers]["webhook-signature"],
                        now: @now)).to be(true)
    end

    it "is rejected when the body is altered in flight" do
      created = subscribe
      emit(body: "watched")
      endpoint = FakeEndpoint.new
      pump_for(endpoint).call(pump_job(created.row.id))

      sent = endpoint.requests.first
      expect(Sig.verify(secret: created.secret, id: sent[:headers]["webhook-id"],
                        timestamp: sent[:headers]["webhook-timestamp"].to_i,
                        payload: "#{sent[:body]}tampered",
                        header: sent[:headers]["webhook-signature"], now: @now)).to be(false)
    end

    it "is rejected when it is replayed outside the tolerance" do
      created = subscribe
      emit
      endpoint = FakeEndpoint.new
      pump_for(endpoint).call(pump_job(created.row.id))

      sent = endpoint.requests.first
      expect(Sig.verify(secret: created.secret, id: sent[:headers]["webhook-id"],
                        timestamp: sent[:headers]["webhook-timestamp"].to_i,
                        payload: sent[:body], header: sent[:headers]["webhook-signature"],
                        now: @now + Sig::TOLERANCE + 1)).to be(false)
    end

    it "carries the three headers the format defines" do
      created = subscribe
      emit
      endpoint = FakeEndpoint.new
      pump_for(endpoint).call(pump_job(created.row.id))

      expect(endpoint.requests.first[:headers].keys)
        .to contain_exactly("webhook-id", "webhook-timestamp", "webhook-signature")
    end
  end

  describe "rotating the signing secret" do
    it "signs with both secrets while the window is open" do
      created = subscribe
      old_secret = created.secret
      rotated = webhooks.rotate(community_id: community.id, public_id: created.row.public_id,
                                overlap: 3600)
      emit
      endpoint = FakeEndpoint.new
      pump_for(endpoint).call(pump_job(created.row.id))

      sent = endpoint.requests.first
      header = sent[:headers]["webhook-signature"]
      expect(header.split(" ").length).to eq(2)
      # Both sides of the cutover verify, so nobody has to coordinate a switch.
      [old_secret, rotated.secret].each do |secret|
        expect(Sig.verify(secret: secret, id: sent[:headers]["webhook-id"],
                          timestamp: sent[:headers]["webhook-timestamp"].to_i,
                          payload: sent[:body], header: header, now: @now)).to be(true)
      end
    end

    it "stops signing with the old secret once the window has closed" do
      created = subscribe
      old_secret = created.secret
      rotated = webhooks.rotate(community_id: community.id, public_id: created.row.public_id,
                                overlap: 3600)
      travel(3601)
      emit
      endpoint = FakeEndpoint.new
      pump_for(endpoint).call(pump_job(created.row.id))

      sent = endpoint.requests.first
      header = sent[:headers]["webhook-signature"]
      expect(header.split(" ").length).to eq(1)
      expect(Sig.verify(secret: old_secret, id: sent[:headers]["webhook-id"],
                        timestamp: sent[:headers]["webhook-timestamp"].to_i,
                        payload: sent[:body], header: header, now: @now)).to be(false)
      expect(Sig.verify(secret: rotated.secret, id: sent[:headers]["webhook-id"],
                        timestamp: sent[:headers]["webhook-timestamp"].to_i,
                        payload: sent[:body], header: header, now: @now)).to be(true)
    end

    # Rotating a leaked secret is the case where an overlap is the wrong
    # favour: the old one has to stop working now.
    it "retires the old secret immediately on a zero overlap" do
      created = subscribe
      webhooks.rotate(community_id: community.id, public_id: created.row.public_id, overlap: 0)

      expect(webhooks.rotating?(created.row.refresh, now: @now || now)).to be(false)
    end

    it "refuses to rotate a subscription in another community" do
      created = subscribe
      other = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                      settings: "{}", created_at: now, updated_at: now)

      expect { webhooks.rotate(community_id: other.id, public_id: created.row.public_id) }
        .to raise_error(described_class::Invalid)
    end
  end

  describe "the per-subscription queue" do
    it "delivers in the order the events were queued" do
      created = subscribe
      emit(body: "first")
      emit(body: "second")
      emit(body: "third")
      endpoint = FakeEndpoint.new
      pump_for(endpoint).call(pump_job(created.row.id))

      bodies = endpoint.requests.map { |request| YAMLCamel.load(request[:body]).dig("data", "body") }
      expect(bodies).to eq(%w[first second third])
    end

    it "holds the queue behind a delivery that has not landed" do
      created = subscribe
      emit(body: "first")
      emit(body: "second")
      endpoint = FakeEndpoint.new(codes: %w[500])
      pump_for(endpoint).call(pump_job(created.row.id))

      expect(endpoint.requests.length).to eq(1)
      expect(YAMLCamel.load(endpoint.requests.first[:body]).dig("data", "body")).to eq("first")
    end

    it "waits out the backoff before trying again" do
      created = subscribe
      emit
      endpoint = FakeEndpoint.new(codes: %w[500 200])
      pump = pump_for(endpoint)
      pump.call(pump_job(created.row.id))

      # Immediately again: nothing is due, so nothing is sent.
      pump.call(pump_job(created.row.id))
      expect(endpoint.requests.length).to eq(1)

      travel(webhooks.backoff(1) + 1)
      pump.call(pump_job(created.row.id))
      expect(endpoint.requests.length).to eq(2)
      expect(delivery_rows(created).first[:status]).to eq("delivered")
    end

    it "dead letters a delivery once the attempts run out, and moves on" do
      created = subscribe
      emit(body: "poison")
      emit(body: "after")
      endpoint = FakeEndpoint.new(codes: Array.new(described_class::MAX_ATTEMPTS, "500") + %w[200])
      pump = pump_for(endpoint)

      described_class::MAX_ATTEMPTS.times do |attempt|
        pump.call(pump_job(created.row.id))
        travel(webhooks.backoff(attempt + 1) + 1)
      end

      rows = delivery_rows(created)
      expect(rows.first[:status]).to eq("failed")
      expect(rows.first[:attempts]).to eq(described_class::MAX_ATTEMPTS)
      expect(rows.first[:response_status]).to eq(500)
      # The event behind it is released rather than stuck forever.
      pump.call(pump_job(created.row.id))
      expect(rows_for(created).last[:status]).to eq("delivered")
    end

    it "records the response code and the error for the admin view" do
      created = subscribe
      emit
      pump_for(FakeEndpoint.new(codes: %w[503])).call(pump_job(created.row.id))

      row = delivery_rows(created).first
      expect(row[:response_status]).to eq(503)
      expect(row[:last_error]).to include("503")
    end

    it "records a subscriber that never answered at all" do
      created = subscribe
      emit
      pump_for(FakeEndpoint.new(codes: [:refused])).call(pump_job(created.row.id))

      row = delivery_rows(created).first
      expect(row[:response_status]).to be_nil
      expect(row[:last_error]).to include("ECONNREFUSED")
    end
  end

  describe "two subscriptions, one of them broken" do
    it "delivers to the healthy one while the broken one backs off" do
      broken = subscribe(url: "https://broken.invalid/hook", label: "broken")
      healthy = subscribe(url: "https://healthy.invalid/hook", label: "healthy")
      emit(body: "shared")

      broken_endpoint = FakeEndpoint.new(codes: %w[500])
      healthy_endpoint = FakeEndpoint.new
      pump_for(broken_endpoint).call(pump_job(broken.row.id))
      pump_for(healthy_endpoint).call(pump_job(healthy.row.id))

      expect(delivery_rows(healthy).first[:status]).to eq("delivered")
      expect(delivery_rows(broken).first[:status]).to eq("queued")
      expect(delivery_rows(broken).first[:attempts]).to eq(1)
    end

    it "leaves the healthy subscription untouched when the broken one dies for good" do
      broken = subscribe(url: "https://broken.invalid/hook")
      healthy = subscribe(url: "https://healthy.invalid/hook")
      emit(body: "shared")

      broken_endpoint = FakeEndpoint.new(codes: Array.new(described_class::MAX_ATTEMPTS, "500"))
      broken_pump = pump_for(broken_endpoint)
      described_class::MAX_ATTEMPTS.times do |attempt|
        broken_pump.call(pump_job(broken.row.id))
        travel(webhooks.backoff(attempt + 1) + 1)
      end

      healthy_endpoint = FakeEndpoint.new
      pump_for(healthy_endpoint).call(pump_job(healthy.row.id))

      expect(delivery_rows(broken).first[:status]).to eq("failed")
      expect(delivery_rows(healthy).first[:status]).to eq("delivered")
    end
  end

  describe "community scoping" do
    let(:other) do
      models.community.create(slug: "other-co", name: "Other Co", status: "active",
                              settings: "{}", created_at: now, updated_at: now)
    end

    it "never queues one community's message for another community's subscriber" do
      subscribe
      webhooks.create(community_id: other.id, url: "https://other.invalid/hook",
                      event_types: [described_class::MESSAGE_RELAYED])
      emit(body: "sample only")

      expect(models.webhook_delivery.where(community_id: other.id).count).to eq(0)
      expect(models.webhook_delivery.where(community_id: community.id).count).to eq(1)
    end

    it "does not list another community's subscriptions" do
      subscribe
      expect(webhooks.list(community_id: other.id)).to be_empty
    end

    # The API can only answer 404 rather than 403 if the lookup itself comes
    # back empty.
    it "finds nothing for an id belonging to another community" do
      created = subscribe
      expect(webhooks.find(community_id: other.id, public_id: created.row.public_id)).to be_nil
    end

    it "does not delete another community's subscription" do
      created = subscribe
      expect(webhooks.delete(community_id: other.id, public_id: created.row.public_id)).to be(false)
      expect(webhooks.list(community_id: community.id).length).to eq(1)
    end

    it "shows only this community's deliveries" do
      subscribe
      emit
      expect(webhooks.deliveries(community_id: other.id)).to be_empty
      expect(webhooks.deliveries(community_id: community.id).length).to eq(1)
    end
  end

  describe "which subscriptions an event reaches" do
    it "skips a subscription that is switched off" do
      created = subscribe
      webhooks.set_active(community_id: community.id, public_id: created.row.public_id, active: false)
      emit

      expect(models.webhook_delivery.count).to eq(0)
    end

    it "honours a subscription narrowed to one room" do
      subscribe(room_key: "general")
      emit(room_key: "gaming")
      expect(models.webhook_delivery.count).to eq(0)

      emit(room_key: "general")
      expect(models.webhook_delivery.count).to eq(1)
    end

    it "refuses an event type nobody emits, at creation rather than in silence" do
      expect do
        webhooks.create(community_id: community.id, url: "https://example.invalid/hook",
                        event_types: ["message.invented"])
      end.to raise_error(described_class::Invalid, /unknown event type/)
    end

    it "refuses a URL that is not https" do
      expect do
        webhooks.create(community_id: community.id, url: "http://example.invalid/hook",
                        event_types: [described_class::MESSAGE_RELAYED])
      end.to raise_error(described_class::Invalid, /https/)
    end

    # A queue that cannot be written to must not cost a room its bridging.
    it "never raises out of emit, whatever the database does" do
      subscribe
      allow(models.webhook_delivery).to receive(:create).and_raise(Sequel::Error, "gone")

      expect { emit }.not_to raise_error
    end
  end

  describe "the address guard" do
    it "refuses a subscriber whose host resolves somewhere private" do
      created = subscribe(url: "https://internal.invalid/hook")
      emit
      pump = Rubotty::ControlPlane::WebhookPump.new(
        webhooks: webhooks, models: models, logger: Rubotty::Log.null,
        http: FakeEndpoint.new.to_proc, clock: clock,
        resolver: ->(_host) { ["169.254.169.254"] }
      )
      pump.call(pump_job(created.row.id))

      row = delivery_rows(created).first
      expect(row[:status]).to eq("queued")
      expect(row[:last_error]).to include("refused")
    end
  end

  it "drops delivery rows past the retention, which is what bounds the message text kept" do
    subscribe
    emit
    travel(described_class::RETENTION + 1)

    expect(webhooks.prune(now: @now)).to eq(1)
    expect(models.webhook_delivery.count).to eq(0)
  end

  # Alerts really does evict the oldest per community on every write; this table
  # does not, and a constant saying otherwise reads as a bound somebody is
  # relying on.
  it "declares no row cap it does not enforce" do
    expect(described_class.constants).not_to include(:COMMUNITY_LIMIT)
  end

  it "keeps a queued delivery a retention sweep has no reason to take" do
    subscribe
    emit
    travel(described_class::RETENTION - 1)

    expect(webhooks.prune(now: @now)).to eq(0)
    expect(models.webhook_delivery.where(status: "queued").count).to eq(1)
  end

  # The durable job row the scheduler would hand the pump.
  def pump_job(subscription_id)
    Rubotty::Core::DurableSchedulerStore::Row.new(
      id: 1, kind: described_class::PUMP_KIND, payload: { "subscription_id" => subscription_id },
      status: "claimed", attempts: 0
    )
  end

  def rows_for(created)
    db[:webhook_deliveries].where(subscription_id: created.row.id).order(:id).all
  end
  alias delivery_rows rows_for
end
