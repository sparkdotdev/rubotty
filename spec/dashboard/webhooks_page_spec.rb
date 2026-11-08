# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The admin view of what failed: which subscriber missed which event, and why. The
# durable scheduler retries and gives up on its own, in a log nobody reads.
RSpec.describe "the webhooks dashboard page", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret }) }
  let(:webhooks) { deps.webhooks }

  before { post "/login", secret: secret }

  def subscribe(**rest)
    webhooks.create(community_id: community.id, url: "https://example.invalid/hook",
                    event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED], **rest)
  end

  def emit(body: "hello")
    webhooks.emit(community_id: community.id,
                  event_type: Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED,
                  room_key: "general", data: { "body" => body })
  end

  # Walk a delivery to the dead-letter state the page exists to surface.
  def dead_letter!
    row = models.webhook_delivery.order(:id).last
    Rubotty::ControlPlane::Webhooks::MAX_ATTEMPTS.times do
      webhooks.failed(row.refresh, error: "HTTP 500: down", response_status: 500)
    end
    row.refresh
  end

  it "lists a subscription with where it points and what it wants" do
    subscribe(label: "ticket filer")
    get "/communities/sample/webhooks"

    expect(last_response.body).to include("ticket filer")
      .and include("https://example.invalid/hook")
      .and include("message.relayed")
  end

  it "never shows the signing secret" do
    created = subscribe
    emit
    get "/communities/sample/webhooks"

    expect(last_response.body).not_to include(created.secret)
  end

  it "says a rotation window is still open, since nothing else would tell anybody" do
    created = subscribe
    webhooks.rotate(community_id: community.id, public_id: created.row.public_id, overlap: 3600)
    get "/communities/sample/webhooks"

    expect(last_response.body).to include("rotating")
  end

  it "shows a delivery that has been given up on, with the reason" do
    subscribe
    emit
    dead_letter!
    get "/communities/sample/webhooks"

    expect(last_response.body).to include("given up").and include("HTTP 500")
  end

  it "tells an operator how many have been given up on" do
    subscribe
    emit
    dead_letter!
    get "/communities/sample/webhooks"

    expect(last_response.body).to include("1 delivery has been given up on")
  end

  describe "sending a failed delivery again" do
    it "puts the delivery back on the queue with its attempts reset" do
      subscribe
      emit
      row = dead_letter!

      post "/communities/sample/webhooks/deliveries/#{row.id}/retry"

      expect(row.refresh.status).to eq("queued")
      expect(row.refresh.attempts).to eq(0)
    end

    it "refuses a delivery that has not been given up on" do
      subscribe
      emit
      row = models.webhook_delivery.order(:id).last

      post "/communities/sample/webhooks/deliveries/#{row.id}/retry"

      expect(row.refresh.status).to eq("queued")
      expect(last_response.status).to eq(302)
    end

    # Scoped in the query, so an id from another community changes nothing
    # rather than being caught by a check somebody could forget to write.
    it "changes nothing for a delivery belonging to another community" do
      subscribe
      emit
      row = dead_letter!
      models.community.create(slug: "other-co", name: "Other Co", status: "active", settings: "{}",
                              created_at: Time.now, updated_at: Time.now)

      post "/communities/other-co/webhooks/deliveries/#{row.id}/retry"

      expect(row.refresh.status).to eq("failed")
    end

    # Re-sending means a third party receives what is in the delivery, which is more
    # than a reader of the page is trusted with, so an operator needs the grant.
    describe "as an operator" do
      let(:operator_session) { dashboard_session(role: "operator", operator_communities: [community.id]) }

      # The button is there and flat without the grant, so a reader can see what an
      # operator here could do; the write is refused either way.
      it "offers a flat, disabled button, and refuses the write, without the grant" do
        subscribe
        emit
        row = dead_letter!

        get "/communities/sample/webhooks", {}, "rack.session" => operator_session
        expect(last_response.body).to include("Send again")
        expect(last_response.body).to include(%(class="secondary disabled" disabled))

        post "/communities/sample/webhooks/deliveries/#{row.id}/retry", {},
             "rack.session" => operator_session
        expect(row.refresh.status).to eq("failed")
      end

      it "offers the button and allows the write once the grant is handed out" do
        deps.action_permissions.update({ "manage_webhooks" => "1" })
        subscribe
        emit
        row = dead_letter!

        get "/communities/sample/webhooks", {}, "rack.session" => operator_session
        expect(last_response.body).to include(%(<button type="submit" class="secondary" data-grant="manage_webhooks">Send again</button>))

        post "/communities/sample/webhooks/deliveries/#{row.id}/retry", {},
             "rack.session" => operator_session
        expect(row.refresh.status).to eq("queued")
      end
    end
  end

  it "reaches the page from the community navigation" do
    get "/communities/sample"

    expect(last_response.body).to include("/communities/sample/webhooks")
  end
end
