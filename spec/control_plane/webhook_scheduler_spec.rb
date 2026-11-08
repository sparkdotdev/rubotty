# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "rubotty/api"

# The feature has to be carried by the durable scheduler itself rather than by a
# handler somebody could call by hand, so this drives a real scheduler over a real
# table and steps it with #run_due.
RSpec.describe "webhooks on the durable scheduler", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:webhooks) { Rubotty::ControlPlane::Webhooks.new(models: models, logger: Rubotty::Log.null) }

  let(:store) { Rubotty::Core::DurableSchedulerStore.for(double_storage) }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "spec", logger: Rubotty::Log.null)
  end

  # DurableSchedulerStore.for reads nothing but #db, and this is the control plane's own.
  def double_storage
    Struct.new(:db).new(db)
  end

  # Every request the fake subscriber was handed.
  def recorder
    @recorder ||= []
  end

  def pump
    Rubotty::ControlPlane::WebhookPump.new(
      webhooks: webhooks, models: models, logger: Rubotty::Log.null,
      http: lambda { |uri, headers, body|
        recorder << { uri: uri, headers: headers, body: body }
        Struct.new(:code, :body).new("200", "")
      },
      resolver: ->(_host) { ["93.184.216.34"] }
    )
  end

  before do
    scheduler.register(Rubotty::ControlPlane::Webhooks::PUMP_KIND) { |job| pump.call(job) }
    scheduler.register(Rubotty::ControlPlane::Webhooks::RECONCILE_KIND) do |_job|
      webhooks.reconcile_pumps(scheduler: scheduler)
    end
  end

  def subscribe(**rest)
    webhooks.create(community_id: community.id, url: "https://example.invalid/hook",
                    event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED], **rest)
  end

  def emit(body: "hello")
    webhooks.emit(community_id: community.id,
                  event_type: Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED,
                  room_key: "general", data: { "body" => body })
  end

  def reconcile_now
    scheduler.schedule(kind: Rubotty::ControlPlane::Webhooks::RECONCILE_KIND,
                       run_at: Time.now - 1, payload: {})
    scheduler.run_due(now: Time.now)
  end

  describe "the reconcile job" do
    it "creates one pump per active subscription" do
      subscribe(label: "one")
      subscribe(label: "two")
      reconcile_now

      expect(scheduler.pending(kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND)).to eq(2)
    end

    # A subscription is created by the API or the dashboard, and only the bot holds the
    # scheduler, so nothing would create the pump if creation had to.
    it "picks up a subscription created while the scheduler was already running" do
      reconcile_now
      expect(scheduler.pending(kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND)).to eq(0)

      subscribe
      reconcile_now
      expect(scheduler.pending(kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND)).to eq(1)
    end

    it "drops the pump for a subscription that has been deleted" do
      created = subscribe
      reconcile_now
      webhooks.delete(community_id: community.id, public_id: created.row.public_id)
      reconcile_now

      expect(scheduler.pending(kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND)).to eq(0)
    end

    it "drops the pump for a subscription that has been switched off" do
      created = subscribe
      reconcile_now
      webhooks.set_active(community_id: community.id, public_id: created.row.public_id, active: false)
      reconcile_now

      expect(scheduler.pending(kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND)).to eq(0)
    end

    it "does not pile up a second pump for a subscription that already has one" do
      subscribe
      3.times { reconcile_now }

      expect(scheduler.pending(kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND)).to eq(1)
    end
  end

  describe "a delivery going out through the scheduler's own drain" do
    it "sends what was queued, without anybody calling the pump directly" do
      subscribe
      reconcile_now
      emit(body: "through the scheduler")

      # Far enough ahead that the recurring pump is due.
      scheduler.run_due(now: Time.now + Rubotty::ControlPlane::Webhooks::PUMP_INTERVAL + 1)

      expect(recorder.length).to eq(1)
      expect(YAMLCamel.load(recorder.first[:body]).dig("data", "body")).to eq("through the scheduler")
      expect(db[:webhook_deliveries].first[:status]).to eq("delivered")
    end

    # The pump recurs, so a one-shot would deliver the first event and never wake again.
    it "stays pending after it has run, so the next event is picked up too" do
      subscribe
      reconcile_now
      emit(body: "first")
      scheduler.run_due(now: Time.now + Rubotty::ControlPlane::Webhooks::PUMP_INTERVAL + 1)

      expect(scheduler.pending(kind: Rubotty::ControlPlane::Webhooks::PUMP_KIND)).to eq(1)

      emit(body: "second")
      scheduler.run_due(now: Time.now + (Rubotty::ControlPlane::Webhooks::PUMP_INTERVAL * 3))

      expect(recorder.map { |r| YAMLCamel.load(r[:body]).dig("data", "body") }).to eq(%w[first second])
    end

    # The jobs are rows, so a fresh session finds the pump and the queued delivery
    # exactly where the dead one left them.
    it "survives a restart, because the pump and the queue are both rows" do
      subscribe
      reconcile_now
      emit(body: "queued before the crash")

      fresh = Rubotty::Core::DurableScheduler.new(
        store: Rubotty::Core::DurableSchedulerStore.for(double_storage),
        session_id: "a-later-session", logger: Rubotty::Log.null
      )
      fresh.register(Rubotty::ControlPlane::Webhooks::PUMP_KIND) { |job| pump.call(job) }
      fresh.register(Rubotty::ControlPlane::Webhooks::RECONCILE_KIND) { |_job| nil }
      fresh.recover(now: Time.now + Rubotty::ControlPlane::Webhooks::PUMP_INTERVAL + 1)

      expect(recorder.length).to eq(1)
      expect(db[:webhook_deliveries].first[:status]).to eq("delivered")
    end
  end
end

# The privilege boundary and the 404-not-403 rule are the two things a webhook route
# getting them wrong would leak.
RSpec.describe "the webhook admin API", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 100_000) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer(on: community)
    { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'developer', community: on, label: 'd').token}" }
  end

  def other_community
    models.community.create(slug: "other-co", name: "Other Co", status: "active", settings: "{}",
                            created_at: Time.now, updated_at: Time.now)
  end

  def create_webhook(headers = admin, slug: "sample")
    post "/admin/communities/#{slug}/webhooks",
         { url: "https://example.invalid/events", event_types: "message.relayed", label: "spec" }, headers
    YAMLCamel.load(last_response.body)
  end

  it "hands back the signing secret exactly once, on creation" do
    created = create_webhook
    expect(last_response.status).to eq(201)
    expect(created["secret"]).to start_with("whsec_")

    get "/admin/communities/sample/webhooks", {}, admin
    listed = YAMLCamel.load(last_response.body)["webhooks"].first
    expect(listed).not_to have_key("secret")

    get "/admin/communities/sample/webhooks/#{created['public_id']}", {}, admin
    expect(YAMLCamel.load(last_response.body)).not_to have_key("secret")
  end

  it "hands back a new secret on rotation, and a different one" do
    created = create_webhook
    post "/admin/communities/sample/webhooks/#{created['public_id']}/rotate", { overlap: 3600 }, admin

    rotated = YAMLCamel.load(last_response.body)
    expect(rotated["secret"]).to start_with("whsec_")
    expect(rotated["secret"]).not_to eq(created["secret"])
    expect(rotated["rotating"]).to be(true)
  end

  # A subscription forwards a community's conversation out of the deployment, so no
  # developer key reaches one whatever community it names.
  it "refuses a developer key with 403 on every webhook route" do
    created = create_webhook
    [
      [:get, "/admin/communities/sample/webhooks"],
      [:get, "/admin/communities/sample/webhooks/#{created['public_id']}"],
      [:post, "/admin/communities/sample/webhooks"],
      [:post, "/admin/communities/sample/webhooks/#{created['public_id']}/rotate"],
      [:delete, "/admin/communities/sample/webhooks/#{created['public_id']}"],
      [:get, "/admin/communities/sample/webhook-deliveries"]
    ].each do |verb, path|
      public_send(verb, path, {}, developer)
      expect(last_response.status).to eq(403), "#{verb.upcase} #{path} answered #{last_response.status}"
    end
  end

  # An administrator key naming another community's subscription gets the same answer
  # as one naming nothing, since a 403 would confirm the subscription exists.
  it "404s, never 403, for a subscription in another community" do
    created = create_webhook
    other = other_community

    get "/admin/communities/#{other.slug}/webhooks/#{created['public_id']}", {}, admin
    expect(last_response.status).to eq(404)

    get "/admin/communities/#{other.slug}/webhooks/does-not-exist", {}, admin
    expect(last_response.status).to eq(404)
  end

  it "does not delete a subscription through another community's path" do
    created = create_webhook
    other = other_community

    delete "/admin/communities/#{other.slug}/webhooks/#{created['public_id']}", {}, admin
    expect(last_response.status).to eq(404)
    expect(models.webhook_subscription.count).to eq(1)
  end

  it "refuses a URL that is not https, with the reason" do
    post "/admin/communities/sample/webhooks",
         { url: "http://example.invalid/events", event_types: "message.relayed" }, admin

    expect(last_response.status).to eq(422)
    expect(YAMLCamel.load(last_response.body)["error"]).to include("https")
  end

  it "lists only this community's deliveries" do
    create_webhook
    other = other_community
    webhooks = Rubotty::ControlPlane::Webhooks.new(models: models, logger: Rubotty::Log.null)
    webhooks.emit(community_id: community.id, event_type: "message.relayed",
                  room_key: "general", data: { "body" => "mine" })

    get "/admin/communities/#{other.slug}/webhook-deliveries", {}, admin
    expect(YAMLCamel.load(last_response.body)["deliveries"]).to be_empty

    get "/admin/communities/sample/webhook-deliveries", {}, admin
    expect(YAMLCamel.load(last_response.body)["deliveries"].length).to eq(1)
  end
end
