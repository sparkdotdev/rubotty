# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The rule these examples hold: for every bespoke config page, the keys
# the page draws itself plus the keys the generic schema form underneath
# it draws add up to the whole config_schema, with nothing in both and
# nothing outside them, checked per feature since the failure is quiet.
RSpec.describe "Rubotty::Dashboard::App bespoke config coverage", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  def login! = post("/login", secret: secret)

  # The page each feature's Config link actually opens.
  PAGES = Rubotty::Dashboard::App::BESPOKE_CONFIG_PAGE

  # A bit of markup that proves the bespoke page draws its own control for a key
  # it claims to handle. Named per feature because these controls are the whole
  # reason the page exists: the word filter's operator exemption is a checkbox
  # per scope, the FAQ's entries are add and remove forms rather than a list
  # field, so neither is found by looking for the key's own name.
  OWN_CONTROL = {
    "word_filter" => {
      "mode" => 'name="mode"', "action" => 'name="action"',
      "exempt_operators" => 'name="exempt[all]"', "custom" => 'name="custom"'
    },
    "faq" => { "entries" => 'name="trigger"' },
    "events" => {},
    "guest_portal" => { "who_can_invite" => 'name="who_can_invite"' },
    "nickname" => { "who_can_set" => 'name="who_can_set"' }
  }.freeze

  def schema_keys(feature)
    Rubotty::Features::Catalog.class_for(feature).config_schema.fields.keys.map(&:to_s)
  end

  def handled_keys(feature)
    Rubotty::Dashboard::App::BESPOKE_CONFIG_HANDLED.fetch(feature)
  end

  # The schema form the bespoke page renders underneath its own controls,
  # sliced off the page by its own id so a control elsewhere on the page is
  # never mistaken for one of its fields.
  def schema_form(body)
    start = body.index('<form id="schema-config-form"')
    return "" if start.nil?

    body[start..].split("</form>", 2).first.to_s
  end

  # The form's own plumbing, which names no config key.
  PLUMBING = %w[selector return_to config_scope].freeze

  # A mapping-list field's own row inputs carry a bracketed, indexed name
  # ("entries[0][pattern]"), so the key itself is everything before the
  # first bracket.
  def field_names(markup)
    markup.scan(/<(?:input|select|textarea)\b[^>]*\bname="([^"\[]+)(?:\[[^"]*)?"/)
          .flatten.uniq - PLUMBING
  end

  # Everything the pages need visible: rooms mapped, and a row per feature so
  # the word filter and FAQ render their per-scope cards.
  before do
    login!
    post "/communities/sample/word-filter", selector: "all", op: "enable"
    post "/communities/sample/faq", selector: "all", op: "enable"
  end

  PAGES.each do |feature, page|
    describe "the #{page} page" do
      it "reaches every key #{feature} declares" do
        get "/communities/sample/#{page}"

        rendered = field_names(schema_form(last_response.body))
        expect(handled_keys(feature) + rendered).to match_array(schema_keys(feature))
      end

      it "draws its own control for every key it claims to handle" do
        get "/communities/sample/#{page}"

        handled_keys(feature).each do |key|
          expect(last_response.body).to include(OWN_CONTROL.fetch(feature).fetch(key))
        end
      end

      it "leaves a key it handles out of the schema form, so nothing is drawn twice" do
        get "/communities/sample/#{page}"

        expect(field_names(schema_form(last_response.body)) & handled_keys(feature)).to be_empty
      end
    end
  end

  # The report that opened this: who_can_set and prefixes were declared,
  # defaulted and documented, and the People page offered neither.
  describe "the People page and the nickname feature" do
    it "offers who_can_set once, in its own words rather than as a bare key" do
      get "/communities/sample/people"
      body = last_response.body

      expect(body).to include("Who may set a nickname")
      expect(body.scan(/<select name="who_can_set"/).length).to eq(1)
      Rubotty::Features::Nickname::WHO_CAN_SET.each do |option|
        expect(body).to include(%(<option value="#{option}"))
      end
    end

    it "sets who_can_set from the People page and comes back to it" do
      post "/communities/sample/features/nickname/config",
           selector: "all", return_to: "bespoke", who_can_set: "everyone"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to include("/communities/sample/people")
      stored = deps.feature_controls.list(community, selector: "all")
                   .find { |entry| entry[:feature] == "nickname" }
      expect(stored[:config]["who_can_set"]).to eq("everyone")
    end

    it "sets the leftover keys from the same page without disturbing who_can_set" do
      post "/communities/sample/features/nickname/config",
           selector: "all", return_to: "bespoke", who_can_set: "everyone"
      post "/communities/sample/features/nickname/config",
           selector: "all", return_to: "bespoke",
           ack_ttl_seconds: "5", delete_command_message: "false"

      config = deps.feature_controls.list(community, selector: "all")
                   .find { |entry| entry[:feature] == "nickname" }[:config]
      expect(config["ack_ttl_seconds"]).to eq(5)
      expect(config["delete_command_message"]).to be(false)
      expect(config["who_can_set"]).to eq("everyone")
    end
  end

  # A boolean used to submit as an empty string when the form did not carry it,
  # which stored "" and read back as truthy. A page posting only its leftover
  # keys would have flipped every boolean it does not draw.
  it "leaves a boolean the posted form did not carry alone" do
    post "/communities/sample/features/word_filter/config",
         selector: "all", return_to: "bespoke", exempt_operators: "false"
    post "/communities/sample/features/word_filter/config",
         selector: "all", return_to: "bespoke", removal_reason: "House rules."

    config = deps.feature_controls.list(community, selector: "all")
                 .find { |entry| entry[:feature] == "word_filter" }[:config]
    expect(config["exempt_operators"]).to be(false)
    expect(config["removal_reason"]).to eq("House rules.")
  end

  it "sends a save with no return_to back to the generic form, as before" do
    post "/communities/sample/features/nickname/config", selector: "all", ack_ttl_seconds: "9"

    expect(last_response.headers["location"]).to include("/features/nickname/config?scope=all")
  end

  # A return_to naming anything other than the token is ignored: the redirect is
  # looked up from the feature, so the parameter can never carry a destination.
  it "ignores a return_to that names somewhere else" do
    post "/communities/sample/features/nickname/config",
         selector: "all", return_to: "//evil.example/", ack_ttl_seconds: "9"

    expect(last_response.headers["location"]).to include("/features/nickname/config?scope=all")
    expect(last_response.headers["location"]).not_to include("evil.example")
  end

  describe "a community-scoped viewer" do
    let(:viewer_session) do
      dashboard_session(role: "operator", operator_communities: [], viewer_communities: [community.id])
    end

    PAGES.each do |feature, page|
      it "reads the #{page} page with the schema form flat" do
        get "/communities/sample/#{page}", {}, "rack.session" => viewer_session

        expect(last_response.status).to eq(200)
        form = schema_form(last_response.body)
        next if form.empty?

        expect(form).to include("Read only: you cannot change this here.")
        expect(form).to include("<button type=\"submit\" class=\"disabled\"")
      end

      it "is refused a #{feature} config write server-side" do
        post "/communities/sample/features/#{feature}/config",
             { selector: "all", return_to: "bespoke" }, "rack.session" => viewer_session

        expect(last_response.status).to eq(403)
      end
    end

    it "sees the People page's who_can_set control flat and writes nothing through it" do
      get "/communities/sample/people", {}, "rack.session" => viewer_session
      expect(last_response.body).to include("Who may set a nickname")
      expect(last_response.body).to include("<button type=\"submit\" class=\"disabled\"")

      post "/communities/sample/features/nickname/config",
           { selector: "all", return_to: "bespoke", who_can_set: "everyone" },
           "rack.session" => viewer_session

      expect(last_response.status).to eq(403)
      expect(deps.feature_controls.list(community, selector: "all")
                 .find { |entry| entry[:feature] == "nickname" }).to be_nil
    end
  end
end
