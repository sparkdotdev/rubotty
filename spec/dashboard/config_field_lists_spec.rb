# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The generic config form's list fields. Save used to rewrite every
# list entry as a string, so a mapping-typed setting (the bridge's
# timezone pairs, the warning ladder) could not survive the round trip.
# A blank box writes an explicit empty list: the deliberate "off" signal.
RSpec.describe "Rubotty::Dashboard::App config list fields", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  ZONES = Rubotty::Features::TimestampExpansion::DEFAULT_ZONES

  before { post "/login", secret: secret }

  # One scope's stored config for a feature, straight off the row.
  def stored(feature, selector: "all")
    deps.feature_controls.list(community, selector: selector)
        .find { |entry| entry[:feature] == feature }&.dig(:config) || {}
  end

  def config_page(feature, scope: "all")
    get "/communities/sample/features/#{feature}/config?scope=#{scope}"
    last_response.body
  end

  # What the page put in one field's box, unescaped, which is exactly what a
  # browser sends back when nobody touches it.
  def textarea(body, name)
    markup = body[/<textarea[^>]*\bname="#{Regexp.escape(name)}"[^>]*>(.*?)<\/textarea>/m, 1]
    markup && CGI.unescapeHTML(markup)
  end

  # A mapping-list field's rows as the browser would submit them back
  # untouched: one {index => {sub_field => value}} entry per row, read
  # straight off the labelled inputs the page rendered rather than assumed.
  def mapping_list_rows(body, name)
    body.scan(/name="#{Regexp.escape(name)}\[(\d+)\]\[(\w+)\]" value="([^"]*)"/)
        .each_with_object({}) { |(index, key, value), out| (out[index] ||= {})[key] = CGI.unescapeHTML(value) }
  end

  def save(feature, **fields)
    selector = fields.delete(:selector) || "all"
    post "/communities/sample/features/#{feature}/config", { selector: selector }.merge(fields)
  end

  describe "a list of mappings" do
    it "draws the bridge's timezone pairs as labelled rows, one per zone" do
      rows = mapping_list_rows(config_page("bridge"), "timestamp_timezones")

      expect(rows.length).to eq(ZONES.length)
      expect(rows["0"]).to eq(ZONES.first)
    end

    it "survives a save nobody touched" do
      submitted = mapping_list_rows(config_page("bridge"), "timestamp_timezones")

      save("bridge", timestamp_timezones: submitted)

      expect(stored("bridge")["timestamp_timezones"]).to eq(ZONES)
    end

    it "still expands timestamps after that save, rather than reading as no zones at all" do
      submitted = mapping_list_rows(config_page("bridge"), "timestamp_timezones")

      save("bridge", timestamp_timezones: submitted)
      zones = Rubotty::Features::TimestampExpansion.zones_for_config(stored("bridge"))

      expect(zones.map(&:label)).to eq(ZONES.map { |zone| zone["label"] })
    end

    it "keeps an edited pair a mapping" do
      save("bridge", timestamp_timezones: %({"label":"Lisbon","iana_timezone":"Europe/Lisbon"}))

      expect(stored("bridge")["timestamp_timezones"])
        .to eq([{ "label" => "Lisbon", "iana_timezone" => "Europe/Lisbon" }])
    end

    it "refuses a line it cannot read, writing nothing at all" do
      save("bridge", timestamp_timezones: %({"label":"Lisbon"), thread_reply_notices: "true")

      expect(stored("bridge")).to eq({})
      follow_redirect!
      expect(last_response.body).to include("cannot read")
    end
  end

  describe "an emptied box against a blank one" do
    it "reads a cleared list as the deliberate empty list that turns expansion off" do
      save("bridge", timestamp_timezones: "")

      expect(stored("bridge")["timestamp_timezones"]).to eq([])
      expect(Rubotty::Features::TimestampExpansion.zones_for_config(stored("bridge"))).to be_empty
    end

    it "leaves a key alone when the box was already blank, so no default gets pinned" do
      save("warnings", ladder: "", max: "3")

      expect(stored("warnings")).to include("max" => 3)
      expect(stored("warnings")).not_to have_key("ladder")
    end

    it "leaves a deliberate empty list standing when the blank box is saved again" do
      save("bridge", timestamp_timezones: "")
      save("bridge", timestamp_timezones: "")

      expect(stored("bridge")["timestamp_timezones"]).to eq([])
    end

    it "clears a list the scope itself wrote" do
      save("link_filter", whitelist: "example.com")
      save("link_filter", whitelist: "")

      expect(stored("link_filter")["whitelist"]).to eq([])
    end
  end

  describe "a list the schema declares an element type for" do
    it "keeps a string list a list of strings, digits and all" do
      save("moderated_room", approved_users: "12345\nalice")

      expect(stored("moderated_room")["approved_users"]).to eq(%w[12345 alice])
    end

    it "reads an integer list as numbers, which is what the reminder ladder is" do
      save("events", default_reminder_intervals: "3600\n900")

      expect(stored("events")["default_reminder_intervals"]).to eq([3600, 900])
    end

    it "leaves a bare word in a free list a bare word" do
      save("word_filter", entries: "badger\n{\"pattern\":\"mushroom\",\"action\":\"warn\"}")

      expect(stored("word_filter")["entries"])
        .to eq(["badger", { "pattern" => "mushroom", "action" => "warn" }])
    end
  end
end
