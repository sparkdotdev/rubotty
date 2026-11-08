# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

RSpec.describe "Rubotty::Dashboard::App structured config lists", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  before { post "/login", secret: secret }

  def stored(feature)
    deps.feature_controls.list(community, selector: "all")
        .find { |entry| entry[:feature] == feature }&.dig(:config) || {}
  end

  def save(feature, fields)
    post "/communities/sample/features/#{feature}/config", { selector: "all" }.merge(fields)
  end

  it "describes a mapping list and its labelled entry fields to every theme" do
    get "/internal/communities/sample/features/bridge/config?scope=all"
    payload = YAMLCamel.load(last_response.body)
    zones = payload.fetch("fields").find { |field| field["name"] == "timestamp_timezones" }

    expect(zones).to include("type" => "mapping-list", "entry_variant" => "mapping")
    expect(zones.fetch("entry_fields").map { |field| field["name"] }).to eq(%w[label iana_timezone])
    expect(zones.fetch("entry_fields").map { |field| field["label"] }).to eq(["Label", "Iana timezone"])
  end

  it "marks content policy's description sub-field multiline for the themed payload, name and action plain" do
    get "/internal/communities/sample/features/content_policy/config?scope=all"
    payload = YAMLCamel.load(last_response.body)
    entries = payload.fetch("fields").find { |field| field["name"] == "entries" }
    by_name = entries.fetch("entry_fields").to_h { |field| [field["name"], field["type"]] }

    expect(by_name).to include("description" => "multiline", "name" => "text", "action" => "select")
  end

  # A one-line input is what talked operators into one-sentence subjects, and
  # a subject wants the same textarea content policy's own description gets.
  it "draws a room's topic routing subject as a wrapping field, not a single line" do
    get "/internal/communities/sample/features/topic_routing/config?scope=all"
    payload = YAMLCamel.load(last_response.body)
    subject = payload.fetch("fields").find { |field| field["name"] == "subject" }

    expect(subject).to include("type" => "multiline", "size" => "full")
    expect(subject.fetch("hint")).to include("Idealista")
  end

  it "keeps every clause of a subject an operator wrote across several lines" do
    written = "Buying or selling property in Portugal; renting and tenancy;\n" \
              "any links to Idealista or similar real estate websites"

    save("topic_routing", "subject" => written)

    expect(stored("topic_routing").fetch("subject")).to eq(written)
  end

  it "stores a typed mapping row rather than a JSON line" do
    save("bridge", "timestamp_timezones" => {
      "0" => { "label" => "Lisbon", "iana_timezone" => "Europe/Lisbon" }
    })

    expect(stored("bridge").fetch("timestamp_timezones"))
      .to eq([{ "label" => "Lisbon", "iana_timezone" => "Europe/Lisbon" }])
  end

  it "refuses a malformed mapping row without changing the feature config" do
    save("warnings", "ladder" => {
      "0" => { "threshold" => "1", "action" => "pause", "duration" => "1h" }
    }, "max" => "3")

    expect(stored("warnings")).to eq({})
    follow_redirect!
    expect(last_response.body).to include("must be one of mute, ban, kick")
  end

  it "writes either accepted word-filter entry form" do
    save("word_filter", "entries" => {
      "0" => { "_kind" => "word", "pattern" => "badger" },
      "1" => { "_kind" => "rule", "pattern" => "mushroom", "mode" => "literal", "action" => "warn" }
    })

    expect(stored("word_filter").fetch("entries"))
      .to eq(["badger", { "pattern" => "mushroom", "mode" => "literal", "action" => "warn" }])
  end

  it "enables content policy with no config and gets no entries at all, nothing enforced" do
    get "/communities/sample/features/content_policy/config?scope=all"

    expect(stored("content_policy")).to eq({})
    expect(last_response.body).not_to include('name="entries[0][name]"')
  end

  it "draws a labelled row per content policy entry on the plain dashboard, not a JSON textarea" do
    save("content_policy", "entries" => {
      "0" => { "name" => "Spam", "description" => "Promotional spam.", "action" => "delete" }
    })
    get "/communities/sample/features/content_policy/config?scope=all"

    expect(last_response.body).not_to include('textarea name="entries"')
    expect(last_response.body).to include('name="entries[0][name]" value="Spam"')
    expect(last_response.body).to include('name="entries[0][description]"')
    expect(last_response.body).to include('<option value="delete" selected>Delete</option>')
  end

  it "draws the long free-text description sub-field as a wrapping textarea, name and action as before" do
    save("content_policy", "entries" => {
      "0" => { "name" => "Spam", "description" => "Promotional spam.", "action" => "delete" }
    })
    get "/communities/sample/features/content_policy/config?scope=all"
    body = last_response.body

    expect(body).to match(%r{<textarea name="entries\[0\]\[description\]"[^>]*>[^<]+</textarea>})
    expect(body).to include('<input type="text" name="entries[0][name]"')
    expect(body).not_to match(%r{<textarea name="entries\[0\]\[name\]"})
  end

  it "stores an edited content policy entry submitted from its labelled row" do
    save("content_policy", "entries" => {
      "0" => { "name" => "Spam", "description" => "Promotional spam.", "action" => "delete" }
    })

    expect(stored("content_policy").fetch("entries"))
      .to eq([{ "name" => "Spam", "description" => "Promotional spam.", "action" => "delete" }])
  end

  it "offers every content policy preset in a select beside one Add preset button, not automatically applied" do
    get "/communities/sample/features/content_policy/config?scope=all"
    body = last_response.body

    expect(body).to include('<select class="cfg-mapping-preset-select">')
    expect(body).to include('<button type="button" class="secondary cfg-mapping-preset-add">Add preset</button>')
    expect(body.scan('data-preset-name="').length).to eq(Rubotty::ContentPolicy::Service::PRESETS.length)
    Rubotty::ContentPolicy::Service::PRESETS.each do |preset|
      expect(body).to include(%(data-preset-name="#{preset.fetch("name")}"))
      expect(body).to include(%(data-preset-description="#{Rack::Utils.escape_html(preset.fetch("description"))}"))
      expect(body).to include(%(data-preset-action="#{preset.fetch("action")}"))
      expect(body).to include(">#{Rack::Utils.escape_html(preset.fetch("name"))}</option>")
    end
    expect(body).not_to include('name="entries[0]')
  end

  it "saves a preset's exact name, description and action once its row is submitted like any other" do
    preset = Rubotty::ContentPolicy::Service::PRESETS.first
    save("content_policy", "entries" => {
      "0" => { "name" => preset.fetch("name"), "description" => preset.fetch("description"),
                "action" => preset.fetch("action") }
    })

    expect(stored("content_policy").fetch("entries")).to eq([preset])
  end

  it "shows word filter's stored entries as rows, hiding rule-only fields on a plain word" do
    save("word_filter", "entries" => {
      "0" => { "_kind" => "word", "pattern" => "badger" },
      "1" => { "_kind" => "rule", "pattern" => "mushroom", "mode" => "literal", "action" => "warn" }
    })

    get "/communities/sample/features/word_filter/config?scope=all"
    # Rows render one after another in entry order; splitting on each row's own
    # opening tag isolates entries[0]'s row from entries[1]'s.
    rows = last_response.body.split('<div class="cfg-mapping-row">')
    word_row = rows[1]
    rule_row = rows[2]

    expect(word_row).to include('<option value="word" selected>Simple word</option>')
    expect(word_row).to include('name="entries[0][pattern]" value="badger"')
    expect(word_row).to include('cfg-mapping-rule-only" hidden')

    expect(rule_row).to include('<option value="rule" selected>Full rule</option>')
    expect(rule_row).to include('name="entries[1][pattern]" value="mushroom"')
    expect(rule_row).to include('<option value="literal" selected>Literal</option>')
    expect(rule_row).not_to include('cfg-mapping-rule-only" hidden')
  end

  it "draws the same row editor for word filter's entries on its own bespoke page" do
    save("word_filter", "entries" => { "0" => { "_kind" => "word", "pattern" => "badger" } })

    get "/communities/sample/word-filter"

    expect(last_response.body).to include('name="entries[0][pattern]" value="badger"')
    expect(last_response.body).to include('class="cfg-mapping-kind"')
  end

  it "offers no preset picker for word filter's own entries, which has no preset bank of its own" do
    get "/communities/sample/features/word_filter/config?scope=all"

    expect(last_response.body).not_to include('<select class="cfg-mapping-preset-select">')
    expect(last_response.body).not_to include('class="secondary cfg-mapping-preset-add"')
  end
end
