# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "cgi"

# The Features page: a per-scope toggle matrix over every catalog
# feature. Each feature is its own collapsible Section row (mirroring
# renderFeatures in assets/dashboard/runtime/screens.civet), rather than
# the flat table it used to be (#1398).
module FeaturesMatrixSupport
end

RSpec.describe "Rubotty::Dashboard::App features matrix", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def login!
    post "/login", secret: secret
  end

  def feature_row(feature:, room_id: nil)
    models.feature_setting
          .where(community_id: community.id, room_id: room_id, feature: feature).first
  end

  # A feature's own row is its own collapsible Section: data-chevron="end"
  # tells one apart from the "About scopes and defaults" disclosure above the
  # list, and from a category's own collapsible, which both draw
  # chevron-first (the default) instead.
  FeaturesMatrixSupport::FEATURE_ROW_OPEN = '<details class="rb-section rb-section--collapsible" data-chevron="end">'

  def feature_rows_in(html)
    html.split(/(?=#{Regexp.escape(FeaturesMatrixSupport::FEATURE_ROW_OPEN)})/).select { |chunk| chunk.start_with?(FeaturesMatrixSupport::FEATURE_ROW_OPEN) }
  end

  # A row by its stable feature_name, the data-feature attribute carries
  # regardless of what display name and category it renders under.
  def rendered_feature_row(body, feature)
    feature_rows_in(body).find { |row| row.include?(%(data-feature="#{feature}">)) }
  end

  # file_rehosting's own two rows, distinguished by their split key.
  def rendered_split_row(body, key)
    feature_rows_in(body).find { |row| row.include?(%(data-feature-key="#{key}")) }
  end

  before { login! }

  it "lists every catalog feature for the chosen scope, not just the ones with a row" do
    get "/communities/sample/features", scope: "all"
    expect(last_response.status).to eq(200)

    Rubotty::Features::Catalog.names.each do |feature|
      expect(last_response.body).to include(%(value="#{feature}"))
    end
  end

  it "shows each feature's own description, not the fallback placeholder" do
    get "/communities/sample/features", scope: "all"

    expect(last_response.body).to include("Relays messages between every platform bridged into a room.")
    expect(last_response.body).not_to include("No description yet.")
  end

  it "puts each feature's state marker before its name and keeps a live toggle in the row" do
    get "/communities/sample/features", scope: "all"
    body = last_response.body

    bridge_row = rendered_feature_row(body, "bridge")
    expect(bridge_row).to include('data-feature-toggle="on"')
    expect(bridge_row).to match(%r{<strong>\[x\] Message Bridge</strong>})
    expect(bridge_row).not_to include('class="pill')

    backfill_row = rendered_feature_row(body, "backfill")
    expect(backfill_row).to include('data-feature-toggle="off"')
    expect(backfill_row).to match(%r{<strong>\[ \] Message Backfill</strong>})
  end

  it "shows an always-enabled feature as on with no toggle, since a row for it would toggle nothing" do
    get "/communities/sample/features", scope: "all"
    body = last_response.body

    identify_topic_row = rendered_feature_row(body, "identify_topic")
    expect(identify_topic_row).to include('data-feature-toggle="on"')
    expect(identify_topic_row).to match(%r{<strong>\[x\] Room Topic Identification</strong>})
    expect(identify_topic_row).to include("Always on")
    expect(identify_topic_row).not_to include('name="op"')
  end

  it "refuses a direct attempt to toggle an always-enabled feature" do
    post "/communities/sample/features", selector: "all", feature: "identify_topic", op: "enable"

    expect(last_response.status).to eq(302)
    expect(feature_row(feature: "identify_topic")).to be_nil
  end

  it "offers a scope selector: community all plus every room" do
    get "/communities/sample/features"
    expect(last_response.body).to include(%(<option value="all"))
    expect(last_response.body).to include(%(<option value="general"))
  end

  it "shows a per-room scope's own state, distinct from the community default" do
    post "/communities/sample/features", selector: "general", feature: "word_filter", op: "enable"

    get "/communities/sample/features", scope: "all"
    all_row = rendered_feature_row(last_response.body, "word_filter")
    expect(all_row).to include('data-feature-toggle="off"')

    get "/communities/sample/features", scope: "general"
    room_row = rendered_feature_row(last_response.body, "word_filter")
    expect(room_row).to include('data-feature-toggle="on"')
  end

  it "toggles a feature in place from the matrix, through the existing FeatureControls path" do
    get "/communities/sample/features", scope: "all"
    faq_row = rendered_feature_row(last_response.body, "faq")
    expect(faq_row).to include('name="op" value="enable"')

    post "/communities/sample/features", selector: "all", feature: "faq", op: "enable"
    expect(feature_row(feature: "faq").enabled).to be(true)

    get "/communities/sample/features", scope: "all"
    faq_row = rendered_feature_row(last_response.body, "faq")
    expect(faq_row).to include('data-feature-toggle="on"')
    expect(faq_row).to include('name="op" value="disable"')
  end

  it "renders a feature's config human-readably, never as a raw JSON blob" do
    deps.feature_controls.set(community: community, selector: "all", feature: "moderation",
                              key: "cleanup_after", value: "15")
    deps.feature_controls.set(community: community, selector: "all", feature: "moderation",
                              key: "acknowledge", value: "true")
    deps.feature_controls.set(community: community, selector: "all", feature: "moderation",
                              key: "prefixes", value: "/,!")

    get "/communities/sample/features", scope: "all"
    body = last_response.body
    # Read off moderation's own row rather than the whole page: another
    # feature's schema legitimately carries a field of the same name, and a
    # page-wide match makes this pass or fail on that instead.
    row = rendered_feature_row(body, "moderation")

    expect(row).not_to include('"cleanup_after"')
    expect(row).not_to include('"acknowledge"')
    expect(body).to include("Cleanup after")
    expect(body).to include("15s")
    expect(body).to include("Yes")
    expect(body).to include(%(<span class="chip">/</span>))
  end

  it "shows a muted placeholder, not an empty cell, for a feature with nothing configured" do
    get "/communities/sample/features", scope: "all"
    backfill_row = rendered_feature_row(last_response.body, "backfill")

    expect(backfill_row).to include("Defaults")
  end

  it "shows a real display name instead of raw feature_name in every row" do
    get "/communities/sample/features", scope: "all"
    body = last_response.body

    expect(body).not_to match(%r{<strong>\[.\] <code>})
    expect(rendered_feature_row(body, "word_filter")).to include("Word Blacklist")
    expect(rendered_feature_row(body, "translation")).to include("LibreTranslate Message Translation")
  end

  describe "category grouping" do
    # A category's own collapsible carries the default chevron
    # (data-chevron="start"), which a single feature row never does.
    FeaturesMatrixSupport::CATEGORY_OPEN = '<details class="rb-section rb-section--collapsible" data-chevron="start">'

    # Every category and its members, each already written in alphabetical
    # order, so an expectation can compare against it as-is.
    FeaturesMatrixSupport::CATEGORY_MEMBERS = {
      "Bridging and Delivery" => ["Channel Management", "File Rehosting", "File Uploads", "Message Backfill",
                                   "Message Bridge", "Message Redirection"],
      "Community Tools" => ["Events & Scheduling", "FAQ Responses", "Keyword Watches", "Polls",
                             "Scheduled Announcements"],
      "Identity and Access" => ["Guest Portal", "Identity History", "Nicknames", "Operator Requests",
                                 "Operator Startup DM", "Restricted Room Access", "Room Topic Identification",
                                 "Telegram Avatar Sync"],
      "Semantic Message Redirection" => ["Topic Auto-Correction", "Topic Detection"],
      "Semantic Analysis" => ["Content Policy Filter", "Semantic FAQ Matching"],
      "Room Summaries" => ["Room Summaries"],
      "Moderation and Safety" => ["Anti-Raid Lockdown", "Anti-Spam Detection", "Link Filter",
                                   "Mass Mention Protection", "Member Reports", "Moderation Commands",
                                   "Multi-Post Prevention", "Warnings", "Word Blacklist"],
      "Platform and System" => ["Command Prefixes", "Disabled Command Notice", "Greetings",
                                 "Guided Command Builder", "Lua Scripting", "Startup Banner",
                                 "Utility Commands"],
      "Translation" => ["Foreign Link Translation", "LibreTranslate Message Translation"]
    }.freeze

    # data-chevron="start" is also what the page's own "About scopes and
    # defaults" disclosure carries, so this keeps only a block whose title is
    # a real category, in the order they actually appear on the page.
    def category_blocks(body)
      body.split(/(?=#{Regexp.escape(FeaturesMatrixSupport::CATEGORY_OPEN)})/)
          .select { |chunk| chunk.start_with?(FeaturesMatrixSupport::CATEGORY_OPEN) && FeaturesMatrixSupport::CATEGORY_MEMBERS.key?(chunk[/rb-section-title">([^<]+)<\/summary>/, 1]) }
    end

    def category_block(body, title)
      category_blocks(body).find { |chunk| chunk.include?(%(rb-section-title">#{title}</summary>)) }
    end

    it "draws all nine categories, alphabetised top to bottom" do
      get "/communities/sample/features", scope: "all"
      titles = category_blocks(last_response.body).map { |block| block[/rb-section-title">([^<]+)<\/summary>/, 1] }

      expect(titles).to eq(FeaturesMatrixSupport::CATEGORY_MEMBERS.keys)
    end

    it "puts every feature into its own category, alphabetised inside it, none left in a flat list" do
      get "/communities/sample/features", scope: "all"
      body = last_response.body

      FeaturesMatrixSupport::CATEGORY_MEMBERS.each do |title, members|
        block = category_block(body, title)
        names = feature_rows_in(block).map { |row| CGI.unescape_html(row[/<strong>\[.\] (.+?)<\/strong>/, 1]) }

        expect(names).to eq(members)
      end

      expect(feature_rows_in(body).size).to eq(FeaturesMatrixSupport::CATEGORY_MEMBERS.values.flatten.size)
    end
  end

  it "keeps a feature's config summary inside its own row, opened on demand rather than always showing" do
    get "/communities/sample/features", scope: "all"

    faq_row = rendered_feature_row(last_response.body, "faq")
    expect(faq_row).to match(%r{</summary><div class="rb-section-body">.*<div class="cfg-summary">}m)
  end

  it "wraps a list-valued config key's badges across the full row width, not one per line" do
    deps.feature_controls.set(community: community, selector: "all", feature: "events",
                              key: "default_reminder_intervals",
                              value: "604800,259200,172800,86400,43200,21600,10800,7200,3600,1800,900")

    get "/communities/sample/features", scope: "all"
    events_row = rendered_feature_row(last_response.body, "events")

    expect(events_row).to include('<span class="chip-list">')
    expect(events_row.scan('class="chip"').size).to eq(11)
  end

  describe "Config link in a feature's row summary" do
    def summary_and_body(row)
      row.split("</summary>", 2)
    end

    it "puts the Config link in the row summary, beside the toggle, not behind the disclosure" do
      get "/communities/sample/features", scope: "all"
      summary, body = summary_and_body(rendered_feature_row(last_response.body, "word_filter"))

      expect(summary).to include('<a class="button secondary" href="/communities/sample/word-filter">Config</a>')
      expect(body).not_to include(">Config<")
    end

    # Only where the link goes differs for a feature on the generic form:
    # the row still shows one rather than making an operator open the row to
    # find out there is anything to configure at all.
    it "puts one there for a feature on the generic config form too, inline editing kept as well" do
      get "/communities/sample/features", scope: "all"
      summary, body = summary_and_body(rendered_feature_row(last_response.body, "redirection"))

      expect(summary).to include(
        '<a class="button secondary" href="/communities/sample/features/redirection/config?scope=all">Config</a>'
      )
      expect(body).to include('action="/communities/sample/features/redirection/config"')
    end

    # The reported row: File Rehosting is one of file_rehosting's two split
    # halves, so its summary link is looked up by the split key rather than
    # by the feature name both halves share.
    it "puts one on each half of file_rehosting's split row" do
      get "/communities/sample/features", scope: "all"
      body = last_response.body

      %w[rehost_inbound enable_upload_command].each do |key|
        summary, = summary_and_body(rendered_split_row(body, key))

        expect(summary).to include(
          '<a class="button secondary" href="/communities/sample/features/file_rehosting/config?scope=all">Config</a>'
        )
      end
    end
  end

  describe "file_rehosting split into File Rehosting and File Uploads" do
    it "renders two independent rows instead of one file_rehosting row" do
      get "/communities/sample/features", scope: "all"
      body = last_response.body

      expect(rendered_split_row(body, "rehost_inbound")).to include("File Rehosting")
      expect(rendered_split_row(body, "enable_upload_command")).to include("File Uploads")
      expect(rendered_feature_row(body, "file_rehosting")).to be_nil
    end

    it "turns both halves on together the first time either is enabled, matching the old single flag" do
      post "/communities/sample/features", selector: "all", feature: "file_rehosting",
                                         op: "enable_flag", key: "rehost_inbound"

      get "/communities/sample/features", scope: "all"
      body = last_response.body
      expect(rendered_split_row(body, "rehost_inbound")).to include('data-feature-toggle="on"')
      expect(rendered_split_row(body, "enable_upload_command")).to include('data-feature-toggle="on"')
      expect(feature_row(feature: "file_rehosting").enabled).to be(true)
    end

    it "turning off File Uploads leaves File Rehosting on, one shared row split by config" do
      post "/communities/sample/features", selector: "all", feature: "file_rehosting",
                                         op: "enable_flag", key: "rehost_inbound"
      post "/communities/sample/features", selector: "all", feature: "file_rehosting",
                                         op: "disable_flag", key: "enable_upload_command"

      get "/communities/sample/features", scope: "all"
      body = last_response.body
      expect(rendered_split_row(body, "rehost_inbound")).to include('data-feature-toggle="on"')
      expect(rendered_split_row(body, "enable_upload_command")).to include('data-feature-toggle="off"')

      row = feature_row(feature: "file_rehosting")
      expect(row.enabled).to be(true)
      expect(row.json_value(:config)).to include("enable_upload_command" => false)
    end

    it "refuses enable_flag/disable_flag for a key that is not one of file_rehosting's own two" do
      post "/communities/sample/features", selector: "all", feature: "file_rehosting",
                                         op: "enable_flag", key: "strategy"
      expect(last_response.status).to eq(403)
    end

    it "refuses enable_flag/disable_flag against a feature that is not file_rehosting" do
      post "/communities/sample/features", selector: "all", feature: "faq", op: "enable_flag", key: "rehost_inbound"
      expect(last_response.status).to eq(403)
    end
  end
end
