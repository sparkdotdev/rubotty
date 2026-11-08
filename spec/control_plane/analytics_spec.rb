# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rubotty/storage/schema"
require "rack/test"

# Driven in-process with rack-test, against seeded data in the same durable
# tables the bot itself writes.
RSpec.describe "Dashboard analytics", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  let(:community) { models.community.where(slug: "sample").first }
  let(:now) { Time.now }

  def login!
    post "/login", secret: secret
  end

  def channel_id_for(endpoint_key)
    models.channel.where(community_id: community.id, endpoint_key: endpoint_key).first.id
  end

  # Controlled offsets from now, so 24h / 7d / 30d each see a different slice.
  def seed_analytics!
    Rubotty::Storage::Schema.apply(db)
    seed_audit!
    seed_directory!
    seed_relay!
    seed_reactions!
    seed_guests!
    seed_operations!
  end

  def audit
    Rubotty::Core::AuditLog::Sequel.new(db: db, logger: Rubotty::Log.null)
  end

  def seed_audit!
    audit.record(community: "sample", source: "moderation", action: "delete",
                 adapter: "telegram", channel: "tg-general", now: now - 3600)
    audit.record(community: "sample", source: "word_filter", action: "delete",
                 adapter: "discord", channel: "dc-general", now: now - 7200)
    audit.record(community: "sample", source: "moderation", action: "ban",
                 adapter: "telegram", channel: "tg-gaming", now: now - (2 * 86_400))
    audit.record(community: "sample", source: "anti_spam", action: "mute",
                 adapter: "discord", channel: nil, now: now - (10 * 86_400))
    # A different community's action must never leak into sample's counts.
    audit.record(community: "other", source: "moderation", action: "kick", now: now - 3600)
  end

  def seed_directory!
    rows = [
      { adapter: "telegram", native_id: "111", username: "alice", display_name: "Alice",
        first_seen_at: now - 3600, last_seen_at: now - 3600 },
      { adapter: "discord", native_id: "222", username: "bob", display_name: "Bob",
        first_seen_at: now - (40 * 86_400), last_seen_at: now - (2 * 86_400) },
      { adapter: "telegram", native_id: "333", username: "carol", display_name: "Carol",
        first_seen_at: now - (100 * 86_400), last_seen_at: now - (10 * 86_400) }
    ]
    rows.each { |row| db[:observed_identities].insert(row.merge(community_id: community.id)) }
  end

  def seed_relay!
    claim("tg-general", "m1", "new", now - 3600)
    claim("dc-general", "m2", "new", now - 7200)
    claim("tg-general", "m3", "new", now - 7200)
    # A non-'new' operation and a stale one outside the day must be excluded.
    claim("tg-general", "m1", "delete", now - 3600)
    claim("tg-general", "m9", "new", now - (2 * 86_400))
  end

  # Written by hand because the real writer stamps Time.now. The community key
  # is the community's row id, which is what Features::Bridge writes.
  def claim(endpoint, native, operation, at)
    db[:relay_claims].insert(
      community: community.id.to_s, source_endpoint: endpoint, source_native_id: native,
      operation: operation, expires_at: at + 86_400, claimed_at: at
    )
  end

  def seed_reactions!
    db[:reaction_state].insert(
      endpoint_id: "tg-general", native_id: "m1", reaction_key: "emoji:up",
      emoji: "up", actor_id: "111", expires_at: now + 86_400, created_at: now - 3600
    )
    db[:reaction_state].insert(
      endpoint_id: "dc-general", native_id: "m2", reaction_key: "emoji:heart",
      emoji: "heart", actor_id: "222", expires_at: now + 86_400, created_at: now - 3600
    )
  end

  def seed_guests!
    channel_id = channel_id_for("tg-general")
    invite(channel_id, "g1", revoked_at: nil, expires_at: now + 3600,
           joined_at: now - 1800, created_at: now - 3600)
    invite(channel_id, "g2", revoked_at: now - 1800, expires_at: now + 3600,
           joined_at: now - 5400, created_at: now - 7200)
    invite(channel_id, "g3", revoked_at: nil, expires_at: now - 60, created_at: now - (2 * 86_400))
  end

  def invite(channel_id, hash, revoked_at:, expires_at:, created_at:, joined_at: nil)
    db[:guest_invites].insert(
      community_id: community.id, channel_id: channel_id, nickname: hash,
      token_hash: hash, revoked_at: revoked_at, expires_at: expires_at, joined_at: joined_at,
      created_at: created_at, updated_at: created_at
    )
  end

  def seed_operations!
    room = models.room.where(community_id: community.id).first
    db[:warnings].insert(community: "sample", adapter: "telegram", subject_native_id: "111",
                         active: true, issued_by: "op", issued_at: now - 3600)
    db[:warnings].insert(community: "sample", adapter: "discord", subject_native_id: "222",
                         active: false, issued_by: "op", issued_at: now - (2 * 86_400), deactivated_at: now - 3600)
    db[:warnings].insert(community: "sample", adapter: "telegram", subject_native_id: "111",
                         active: true, issued_by: "op", issued_at: now - 1800)
    db[:warnings].insert(community: "other", adapter: "telegram", subject_native_id: "333",
                         active: true, issued_at: now - 3600)
    db[:active_sanctions].insert(community: "sample", adapter: "telegram", subject_native_id: "111",
                                 action: "mute", endpoints: "[]", until_at: now + 3600,
                                 active: true, created_at: now - 3600)
    # Lapsed but still flagged active: the durable scheduler's expire_sanction
    # job has not run yet. Must not count as an active sanction.
    db[:active_sanctions].insert(community: "sample", adapter: "discord", subject_native_id: "222",
                                 action: "ban", endpoints: "[]", until_at: now - 60,
                                 active: true, created_at: now - 7200)
    event_id = db[:events].insert(community_id: community.id, room_id: room.id, title: "Raid night",
                                  starts_at: now + 86_400, kind: "gaming", status: "scheduled",
                                  created_at: now - 3600, updated_at: now - 3600)
    db[:event_rsvps].insert(event_id: event_id, identity: "alice", platform: "telegram",
                            response: "yes", responded_at: now - 1800)
    db[:event_rsvps].insert(event_id: event_id, identity: "bob", platform: "discord",
                            response: "no", responded_at: now - 1700)
    # The watchdog writes this table keyed by the community's slug, not its id
    # (Watchdog::Multipost#community_key), so the fixture matches that.
    db[:multipost_fingerprints].insert(community: community.slug, author: "telegram:111",
                                       fingerprint: "abc", channel: "tg-general",
                                       expires_at: now + 3600, recorded_at: now - 1200)
    db[:multipost_fingerprints].insert(community: community.slug, author: "telegram:111",
                                       fingerprint: "abc", channel: "dc-general",
                                       expires_at: now + 3600, recorded_at: now - 900)
    db[:operator_requests].insert(community_id: community.id, adapter: "telegram",
                                  requester_native_id: "req-1", state: "approved",
                                  requested_at: now - 3600, decided_at: now - 1800)
    db[:operator_requests].insert(community_id: community.id, adapter: "discord",
                                  requester_native_id: "req-2", state: "pending",
                                  requested_at: now - 1200)
    db[:pending_spaces].insert(adapter: "discord", account: "main", external_id: "guild-1",
                               name: "Guild One", state: "pending", community_id: community.id,
                               expires_at: now + 86_400, created_at: now - 3600, updated_at: now - 3600)
    db[:pending_spaces].insert(adapter: "telegram", account: "main", external_id: "chat-1",
                               name: "Chat One", state: "approved", community_id: community.id,
                               decided_at: now - 3600, expires_at: now + 86_400,
                               created_at: now - 7200, updated_at: now - 3600)
  end

  describe "authentication" do
    it "redirects an unauthenticated analytics landing to the login form" do
      get "/analytics"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    it "gates a community's analytics page behind the session" do
      get "/communities/sample/analytics"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end
  end

  describe "GET /analytics" do
    before { seed_analytics! }

    it "lists each community with window-scoped counts" do
      login!
      get "/analytics"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Analytics")
      expect(last_response.body).to include("sample")
      expect(last_response.body).to include("Active senders")
      expect(last_response.body).to include("Relayed (24h)")
    end

    it "defaults to the 7d window and marks it active" do
      login!
      get "/analytics"
      expect(last_response.body).to include(%(href="/analytics?window=7d" class="active"))
    end

    it "falls back to the default window for an unknown value" do
      login!
      get "/analytics", window: "bogus"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(%(href="/analytics?window=7d" class="active"))
    end
  end

  describe "GET /communities/:slug/analytics" do
    before { seed_analytics! }

    it "404s for an unknown community" do
      login!
      get "/communities/nope/analytics"
      expect(last_response.status).to eq(404)
    end

    it "renders the report with the community's own data" do
      login!
      get "/communities/sample/analytics"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Message volume")
      expect(last_response.body).to include("Moderation activity")
      expect(last_response.body).to include("Active senders")
      expect(last_response.body).to include("Guest portal")
      expect(last_response.body).to include("Warnings and sanctions")
      expect(last_response.body).to include("Events")
      expect(last_response.body).to include("Multipost watchdog")
      expect(last_response.body).to include("Onboarding")
      expect(last_response.body).to include("Operator requests")
      # Every chart on the page is the Chart primitive: the server names the
      # data's shape and leaves the figure empty, and the engine draws into it
      # in the browser.
      expect(last_response.body).to match(%r{<figure class="rb-chart">})
      expect(last_response.body).to match(%r{<div class="rb-chart-figure" id="rb-chart-[0-9a-f]+"})
      expect(last_response.body).to include('data-shape="categorical_distribution"')
      expect(last_response.body).to include('data-shape="time_series"')
      # The numbers ship with the page rather than waiting on a script, so the
      # report is readable with the engine blocked or still loading.
      expect(last_response.body).to include("rb-chart-table")
    end

    it "shows the day's relayed-message total regardless of the window" do
      login!
      get "/communities/sample/analytics", window: "30d"
      # 3 'new' claims in the last day; the delete op and the 2-day-old claim excluded.
      expect(last_response.body).to include(">3</div><div class=\"l\">relayed messages (last 24h)")
    end

    it "counts guest invites: 1 active, 3 all time" do
      login!
      get "/communities/sample/analytics"
      expect(last_response.body).to include(">1</div><div class=\"l\">active invites")
      expect(last_response.body).to include(">3</div><div class=\"l\">invites all time")
    end

    it "shows the by-channel view by default, issue #273" do
      login!
      get "/communities/sample/analytics"
      expect(last_response.body).to include(%(channel_view=channel" class="active"))
      expect(last_response.body).to include("tg-general")
    end

    it "switches the By channel panel to rooms when asked" do
      login!
      get "/communities/sample/analytics", channel_view: "room"
      expect(last_response.body).to include(%(channel_view=room" class="active"))
      expect(last_response.body).to include("GENERAL")
    end

    it "falls back to the channel view for an unknown channel_view value" do
      login!
      get "/communities/sample/analytics", channel_view: "bogus"
      expect(last_response.body).to include(%(channel_view=channel" class="active"))
    end
  end

  describe "windowed moderation counts" do
    before { seed_analytics! }

    def report(window)
      deps.analytics.overview(community: community, window: window)
    end

    it "counts only the last 24h in the 24h window" do
      expect(report("24h")[:moderation][:total]).to eq(2)
    end

    it "counts the last 7 days in the 7d window" do
      expect(report("7d")[:moderation][:total]).to eq(3)
    end

    it "counts the last 30 days in the 30d window" do
      expect(report("30d")[:moderation][:total]).to eq(4)
    end

    it "breaks moderation down by action, largest first" do
      by_action = report("7d")[:moderation][:by_action]
      expect(by_action.first).to eq(label: "delete", count: 2)
      expect(by_action.map { |row| row[:label] }).to include("ban")
    end

    it "lists known moderation sources even at zero" do
      labels = report("30d")[:moderation][:by_source].map { |row| row[:label] }
      expect(labels).to include("moderation", "word_filter", "link_filter", "anti_spam", "anti_raid")
    end

    it "folds a channel-less action into a community-wide bucket" do
      labels = report("30d")[:moderation][:by_channel].map { |row| row[:label] }
      expect(labels).to include("(community-wide)")
    end

    # An auto discovered Telegram topic's endpoint key is whatever Telegram
    # calls it, which reads as "-1008000000002/86" on a chart.
    describe "naming the channel a moderation action happened in" do
      def audit!(channel)
        db[:audit_events].insert(community: community.slug, source: "moderation", action: "delete",
                                 adapter: "telegram", channel: channel, created_at: Time.now - 60)
      end

      def labels_for(channel)
        audit!(channel)
        report("30d")[:moderation][:by_channel].map { |row| row[:label] }
      end

      it "shows the room a channel is bridged into, rather than its platform id" do
        room = models.room.where(community_id: community.id).first
        channel = models.channel.where(community_id: community.id).first
        channel.update(endpoint_key: "-1008000000002/86")
        models.room_channel.where(channel_id: channel.id).delete
        models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: Time.now)

        labels = labels_for("-1008000000002/86")

        expect(labels).to include(room.label.to_s.empty? ? room.room_key : room.label)
        expect(labels).not_to include("-1008000000002/86")
      end

      # Blanking an unmapped channel would hide the one place to go and look.
      it "keeps the raw key when nothing names that channel" do
        expect(labels_for("-100999/12")).to include("-100999/12")
      end
    end
  end

  describe "windowed member counts" do
    before { seed_analytics! }

    def members(window)
      deps.analytics.overview(community: community, window: window)[:members]
    end

    it "counts active senders per window" do
      expect(members("24h")[:active]).to eq(1)
      expect(members("7d")[:active]).to eq(2)
      expect(members("30d")[:active]).to eq(3)
    end

    it "reports total known senders independent of the window" do
      expect(members("24h")[:total]).to eq(3)
    end

    it "surfaces the most recently active senders, newest first" do
      recent = members("30d")[:recently_active]
      expect(recent.first[:username]).to eq("alice")
      expect(recent.map { |row| row[:username] }).to eq(%w[alice bob carol])
    end
  end

  describe "message volume" do
    before { seed_analytics! }

    let(:report) { deps.analytics.overview(community: community, window: "24h") }

    it "counts only 'new' relay claims in the last day" do
      expect(report[:messages]).to include(available: true, total: 3)
    end

    it "attributes messages to channels by endpoint" do
      by_channel = report[:messages][:by_channel]
      expect(by_channel).to include(label: "tg-general", count: 2)
      expect(by_channel).to include(label: "dc-general", count: 1)
    end

    it "attributes messages to platforms" do
      by_platform = report[:messages][:by_platform]
      expect(by_platform).to include(label: "telegram", count: 2)
      expect(by_platform).to include(label: "discord", count: 1)
    end

    it "rolls channel counts up into their room, issue #273" do
      # tg-general (2) and dc-general (1) both bridge into GENERAL.
      by_room = report[:messages][:by_room]
      expect(by_room).to include(label: "GENERAL", count: 3)
    end

    it "reports unavailable when the datastore has no message map" do
      fresh_db = migrated_db
      fresh_models = build_models(fresh_db)
      Rubotty::ControlPlane::Seed.from_model(sample_model, models: fresh_models, slug: "sample")
      analytics = Rubotty::ControlPlane::Analytics.new(db: fresh_db, models: fresh_models)
      row = fresh_models.community.where(slug: "sample").first
      expect(analytics.overview(community: row)[:messages]).to eq(available: false)
    end
  end

  describe "reactions and guests" do
    before { seed_analytics! }

    let(:report) { deps.analytics.overview(community: community, window: "7d") }

    it "counts live reactions on the community's channels" do
      expect(report[:reactions]).to include(available: true, total: 2)
    end

    it "counts active and issued guest invites" do
      expect(report[:guests][:active]).to eq(1)
      expect(report[:guests][:issued_in_window]).to eq(3)
      expect(report[:guests][:redeemed_in_window]).to eq(2)
      expect(report[:guests][:redemption_rate]).to eq(67)
      expect(report[:guests][:average_session_minutes]).to eq(45)
      expect(report[:guests][:total]).to eq(3)
    end
  end

  describe "operations summaries" do
    before { seed_analytics! }

    let(:report) { deps.analytics.overview(community: community, window: "7d") }

    it "summarises warnings and active sanctions" do
      expect(report[:warnings]).to include(available: true, total: 3, active: 2, repeat_offender_rate: 50)
      expect(report[:warnings][:by_platform]).to include(label: "telegram", count: 2)
      expect(report[:sanctions]).to include(available: true, active: 1)
      expect(report[:sanctions][:by_action]).to include(label: "mute", count: 1)
      expect(report[:sanctions][:by_action]).not_to include(label: "ban", count: 1)
    end

    it "summarises events and RSVPs" do
      expect(report[:events]).to include(available: true, created: 1, upcoming: 1, attendance: 1)
      expect(report[:events][:by_kind]).to include(label: "gaming", count: 1)
      expect(report[:events][:rsvps]).to include(label: "yes", count: 1)
    end

    it "summarises multipost fingerprints and operator request latency" do
      expect(report[:multiposts]).to include(available: true, detections: 1)
      expect(report[:multiposts][:by_channel]).to include(label: "tg-general", count: 1)
      expect(report[:operator_requests]).to include(available: true, pending: 1, decided: 1, average_minutes: 30)
    end

    it "summarises pending-space onboarding" do
      expect(report[:onboarding]).to include(available: true, pending: 1, approved: 1, denied: 0, approval_rate: 100)
      expect(report[:onboarding][:by_platform]).to include(label: "discord", count: 1)
    end
  end

  # Costs recorded by the model-backed features, plus what is queued for them
  # right now. Both halves have to stop at this community's boundary.
  describe "the model-backed features panel" do
    let(:report) { deps.analytics.overview(community: community, window: "7d") }
    let(:panel) { report[:model_calls] }

    let(:recorder) do
      Rubotty::ControlPlane::ModelCallStats.new(models: models, logger: Rubotty::Log.null)
    end

    def queue_job(kind, run_at, community_slug: "sample", status: "pending")
      db[:scheduled_jobs].insert(community: community_slug, kind: kind, payload: "{}", run_at: run_at,
                                 status: status, attempts: 0, created_at: now - 60)
    end

    it "reports what each feature cost and how it went" do
      recorder.record(community_id: community.id, feature: "content_policy", seconds: 1.2,
                      budget_tokens: 120, used_tokens: 90)
      recorder.record(community_id: community.id, feature: "content_policy", seconds: 30.0, failed: true)
      recorder.flush

      content_policy = panel[:features].find { |feature| feature[:key] == "content_policy" }
      expect(panel).to include(available: true)
      expect(content_policy).to include(calls: 2, failures: 1, budget_tokens: 120, used_tokens: 90)
      expect(content_policy[:slowest]).to eq("30s")
    end

    it "never counts another community's calls" do
      other = models.community.create(slug: "other-tenant", name: "Other", status: "active",
                                      created_at: now, updated_at: now)
      recorder.record(community_id: other.id, feature: "content_policy", seconds: 1.0)
      recorder.flush

      expect(panel[:features]).to be_empty
    end

    it "reads queue depth and the oldest wait live, per feature" do
      queue_job("content_policy", now - 90)
      queue_job("content_policy", now - 30)

      waiting = panel[:queue].find { |row| row[:feature] == "content_policy" }
      expect(waiting).to include(depth: 2, label: "Content policy")
      expect(waiting[:oldest_seconds]).to be_within(2).of(90)
    end

    it "leaves out work that is scheduled rather than backed up" do
      queue_job("room_summary", now + 86_400)

      expect(panel[:queue]).to be_empty
    end

    it "never counts another community's queue" do
      queue_job("content_policy", now - 90, community_slug: "other-tenant")

      expect(panel[:queue]).to be_empty
    end

    # The themed page walks the report list, so the panel reaching the internal
    # surface in the right shape is what puts it on the page.
    it "reaches the internal surface as a report of its own" do
      recorder.record(community_id: community.id, feature: "content_policy", seconds: 1.2)
      recorder.discarded(community_id: community.id, feature: "content_policy")
      recorder.flush
      queue_job("content_policy", now - 90)

      login!
      get "/internal/communities/sample/analytics"
      drawn = YAML.safe_load(last_response.body, permitted_classes: [Time, Date])["reports"]
                  .find { |entry| entry["id"] == "model_calls" }

      expect(drawn).to include("title" => "Model-backed features", "available" => true)
      expect(drawn["stats"]).to include([1, "jobs dropped as stale", "queued past their own age limit"])
      expect(drawn["stats"]).to include([1, "Content policy, waiting now", "oldest waiting 1.5m"])
      expect(drawn["charts"].map { |figure| figure["title"] }).to include("Response time, content policy")
    end

    # Every feature here shares one endpoint, so this report is where all of
    # them stopping at the same moment shows up as one fact rather than as
    # four separate failure counts nobody reads together.
    def model_call_stat_rows
      login!
      get "/internal/communities/sample/analytics"
      YAML.safe_load(last_response.body, permitted_classes: [Time, Date])["reports"]
          .find { |entry| entry["id"] == "model_calls" }["stats"]
    end

    it "says so when every feature that ran failed every call" do
      %w[content_policy room_summaries].each do |feature|
        recorder.record(community_id: community.id, feature: feature, seconds: 2.0, failed: true)
      end
      recorder.flush

      expect(model_call_stat_rows)
        .to include([2, "features failing every call",
                     "one shared endpoint; Integrations says whether it answers"])
    end

    it "says nothing of the sort while any call is still getting through" do
      recorder.record(community_id: community.id, feature: "content_policy", seconds: 2.0, failed: true)
      recorder.record(community_id: community.id, feature: "room_summaries", seconds: 1.0)
      recorder.flush

      expect(model_call_stat_rows.map { |row| row[1] }).not_to include("features failing every call")
    end
  end

  describe "community_rows for the landing table" do
    before { seed_analytics! }

    it "summarises each community for the selected window" do
      rows = deps.analytics.community_rows(window: "7d")
      sample = rows.find { |row| row[:community].slug == "sample" }
      expect(sample[:active_members]).to eq(2)
      expect(sample[:moderation_actions]).to eq(3)
      expect(sample[:messages_recent]).to eq(3)
      expect(sample[:active_guests]).to eq(1)
      expect(sample[:upcoming_events]).to eq(1)
      expect(sample[:pending_spaces]).to eq(1)
      expect(sample[:operator_request_minutes]).to eq(30)
    end

    it "reports on only the communities the caller named" do
      other_id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")

      rows = deps.analytics.community_rows(window: "7d", only: [other_id])

      expect(rows.map { |row| row[:community].slug }).to eq(["other-co"])
    end

    it "reports on nothing for a caller scoped to nothing" do
      expect(deps.analytics.community_rows(window: "7d", only: [])).to be_empty
    end

    it "still reports on every community when the caller names none" do
      Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")

      expect(deps.analytics.community_rows(window: "7d").length).to eq(2)
    end
  end
end
