# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The formatting rules the primitives own, and the burn-down of what the pages
# still say without them. These are the failures a reader sees as visible
# nonsense (eleven raw second counts where a reminder ladder should be, a
# timestamp in two shapes one click apart) rather than as slight ugliness.
RSpec.describe "dashboard value formatting" do
  PRIM_FORMAT = Rubotty::Dashboard::Primitives::Format

  # A surface that draws primitives, for the unit half. Everything is permitted
  # here so what is under test is the control rather than the gate.
  let(:surface) do
    Class.new do
      include Rubotty::Dashboard::Primitives::Identity
      include Rubotty::Dashboard::Primitives::Layout

      def may?(_action, community: nil) = true
    end.new
  end

  describe "durations" do
    it "reads a second count as human text" do
      expect(PRIM_FORMAT.duration(604_800)).to eq("1 week")
      expect(PRIM_FORMAT.duration(90)).to eq("1m 30s")
      expect(PRIM_FORMAT.duration(0)).to eq("0s")
    end

    it "reads a LIST of second counts as human text, which is where they leaked out" do
      ladder = [604_800, 259_200, 172_800, 86_400, 43_200, 21_600, 10_800, 7200, 3600, 1800, 900]

      expect(PRIM_FORMAT.durations(ladder).first(3)).to eq(["1 week", "3 days", "2 days"])
      expect(PRIM_FORMAT.durations(ladder).join(" ")).not_to match(/\d{4,}/)
    end

    # The events feature declares its reminder ladder as an array of integers,
    # and a KeyValues row for it has to read as time either way. The humanizer's
    # own list branch is being closed separately; this holds the primitive to
    # the rule regardless of which side gets there first.
    it "draws a duration list through KeyValues as time rather than as numbers" do
      row = surface.key_values([["default_reminder_intervals", [604_800, 3600], :durations]])

      expect(row).to include("1 week")
      expect(row).to include("Default reminder intervals")
      expect(row).not_to include("604800")
    end
  end

  describe "timestamps" do
    let(:at) { Time.utc(2026, 8, 17, 9, 0, 0) }

    it "has exactly one absolute shape" do
      expect(PRIM_FORMAT.timestamp(at)).to eq("2026-08-17 09:00 UTC")
    end

    it "reads recency as a distance, up to a month" do
      now = Time.utc(2026, 8, 17, 12, 0, 0)

      expect(PRIM_FORMAT.relative(at, now: now)).to eq("3 hours ago")
      expect(PRIM_FORMAT.relative(now - 30, now: now)).to eq("just now")
      expect(PRIM_FORMAT.relative(now - (40 * 86_400), now: now)).to match(/UTC\z/)
    end
  end

  describe "counts, sizes and booleans" do
    it "pluralises once, rather than five times by hand" do
      expect(PRIM_FORMAT.count(1, "delivery", "deliveries")).to eq("1 delivery")
      expect(PRIM_FORMAT.count(3, "delivery", "deliveries")).to eq("3 deliveries")
      expect(PRIM_FORMAT.count(2, "round")).to eq("2 rounds")
    end

    it "reads a byte count the way a person does" do
      expect(PRIM_FORMAT.bytes(512)).to eq("512 B")
      expect(PRIM_FORMAT.bytes(2_400_000)).to eq("2.4 MB")
    end

    it "says Yes and No" do
      expect(PRIM_FORMAT.boolean(true)).to eq("Yes")
      expect(PRIM_FORMAT.boolean(false)).to eq("No")
    end
  end

  describe "labels" do
    it "puts an initialism in capitals, which is what External id was" do
      expect(PRIM_FORMAT.label("external id")).to eq("External ID")
      expect(PRIM_FORMAT.label("user_id")).to eq("User ID")
      expect(PRIM_FORMAT.label("api key")).to eq("API key")
    end

    it "keeps sentence case and drops a trailing colon" do
      expect(PRIM_FORMAT.label("who can invite:")).to eq("Who can invite")
      expect(PRIM_FORMAT.label("Fluxer instance")).to eq("Fluxer instance")
    end
  end

  describe "the rules a primitive refuses to break" do
    it "humanises a bare enum token rather than showing it" do
      control = surface.field(name: "action", label: "Action", type: :select,
                              options: %w[delete flag warn mute])

      expect(control).to include(">Delete<")
      expect(control).not_to include(">delete<")
      expect(control).to include('value="delete"')
    end

    it "cuts long help text for display and keeps the whole of it on hover" do
      long = "#{"x" * 200} and the example that makes the field usable"
      drawn = surface.field(name: "url", label: "URL", hint: long)
      shown = drawn[%r{<p class="rb-field-hint"[^>]*>([^<]*)<}, 1]

      expect(shown.length).to be <= 140
      expect(drawn).to include(%(title="#{long}"))
    end

    it "draws the whole of it, wrapped, for a field that asks the cut off" do
      long = "#{"x" * 200} and the example that makes the field usable"
      drawn = surface.field(name: "url", label: "URL", hint: long, hint_wrap: true)

      expect(drawn).to include(%(<p class="rb-field-hint">#{long}</p>))
      expect(drawn).not_to include("tabindex")
    end

    it "draws the hint under the control it explains, so a row of controls starts level" do
      drawn = surface.field(name: "url", label: "URL", hint: "Where the forecast comes from.")

      expect(drawn.index("rb-field-control")).to be < drawn.index("rb-field-hint")
    end

    it "keeps a long cell intact for the theme to lay out" do
      long = "a" * 200
      drawn = surface.table(columns: [{ key: :text, header: "Preview" }],
                            rows: [{ text: long }], empty: "Nothing.")
      shown = drawn[%r{<td[^>]*>([^<]*)</td>}, 1]

      expect(shown).to eq(long)
    end

    it "refuses an eighth column rather than drawing a table nobody reads" do
      columns = (1..8).map { |n| { key: :"c#{n}", header: "Column #{n}" } }

      expect { surface.table(columns: columns, rows: [], empty: "Nothing.") }
        .to raise_error(ArgumentError, /at most 7/)
    end

    it "draws the empty state through Notice, so no view writes one by hand" do
      drawn = surface.table(columns: [{ key: :a, header: "A" }], rows: [], empty: "No entries yet.")

      expect(drawn).to include("rb-notice--empty")
      expect(drawn).not_to include("rb-notice--info")
    end
  end

  describe "on the real pages", :control_plane do
    include Rack::Test::Methods

    let(:seeded) { seeded_sample }
    let(:db) { seeded[0] }
    let(:secret) { "open-sesame" }
    let(:env) { { "DASHBOARD_SECRET" => secret } }
    let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    FORMATTING_PAGES = Rubotty::Dashboard::App.routes.fetch("GET").map { |pattern| pattern[0].to_s }
                                  .grep_v(/:id|:feature|healthz|operator-login|^\/internal\//)
                                  .map { |path| path.gsub(":slug", "sample") }.freeze

    # A timestamp written by something other than the one format. Seconds are
    # the giveaway: the declared shape has none.
    FORMATTING_BARE_TIMESTAMP = /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/

    # Screens still writing a timestamp by hand, with how many; zero everywhere is the
    # target. This only bites where the seed has a row to draw, so a screen at zero
    # here is not proof it is clean, only that nothing on it has a date yet.
    FORMATTING_TIMESTAMP_BUDGET = { "/documentation" => 1, "/communities/sample/operators" => 1 }.freeze

    # The declared button lexicon: sentence case, verb first, no article, one
    # word per verb. A label outside this fails, which is the enforceable half
    # of the copy problem.
    BUTTON_LEXICON = [
      "Accept", "Add account", "Add connection", "Add endpoint", "Add entry", "Add instance",
      "Add network", "Add preset", "Add script", "Approve", "Cancel", "Close session", "Config", "Delete", "Disable",
      "Enable", "Filter", "Grant", "Issue key", "Log out", "Mark seen", "Mint", "Mute",
      "Reject", "Remove", "Restore snapshot", "Retry", "Revoke", "Save", "Search", "Send again", "Set",
      "Start", "Stop", "Test connection", "Warn"
    ].freeze

    # A label still drawn that the lexicon does not have, and what it becomes.
    BUTTON_UNVOCABULARY = {
      "Choose" => "a filter submit says Search or Filter",
      "Code" => "the editor's own pane switch, which becomes TabLinks",
      "Data" => "the editor's own pane switch, which becomes TabLinks",
      "Save connection" => "one Save, since the Section already names what is being saved",
      "Save links" => "one Save, since the Section already names what is being saved",
      "Save permissions" => "one Save, since the Section already names what is being saved",
      "Stop community" => "Stop, since the screen already names the community",
      "View" => "a filter submit says Search or Filter",
      "Write a script" => "the article goes and it becomes Add script"
    }.freeze

    # The features page's tally is its config-key picker naming every feature plus the all scope.
    FORMATTING_FEATURE_PICKER = Rubotty::Features::Catalog.names.size + 1

    # Selects still offering the raw token as its own label, per screen.
    FORMATTING_RAW_OPTION_BUDGET = {
      "/accounts" => 8, "/api-keys" => 1,
      "/communities/sample/events" => 1, "/communities/sample/faq" => 4,
      "/communities/sample/features" => FORMATTING_FEATURE_PICKER, "/communities/sample/guests" => 3,
      "/communities/sample/operators" => 8, "/communities/sample/people" => 4,
      "/communities/sample/platforms" => 9, "/communities/sample/polls" => 1,
      "/communities/sample/scripts/new" => 9, "/communities/sample/word-filter" => 6,
      "/viewers" => 8
    }.freeze

    # The guests page picked up one more: exposing ack_ttl_seconds and delete_command_message
    # (see Features::GuestPortal.config_schema) means it now has a leftover-config card of its
    # own, whose scope selector's "all" option is the same raw token every other leftover-config
    # card already contributes to its own page.
    FORMATTING_REMAINING = { timestamps: 2, raw_options: 62 }.freeze

    def bodies
      @bodies ||= begin
        post("/login", secret: secret)
        FORMATTING_PAGES.to_h { |path| [path, (get(path) && last_response.body)] }
      end
    end

    def raw_options(body)
      body.scan(%r{<option value="([^"]*)"[^>]*>(.*?)</option>}m).select do |value, text|
        value == text.strip && value.match?(/\A[a-z][a-z0-9_]{2,}\z/)
      end.map(&:first).uniq.length
    end

    # A destructive Button carries an aria-hidden "!" mark ahead of its text,
    # which is an affordance rather than part of the label, so it comes off
    # before the lexicon is consulted. Everything else about the label stands.
    def button_labels(body)
      body.scan(%r{<button\b[^>]*>(.*?)</button>}m).flatten.map do |label|
        label.gsub(%r{<span class="rb-button-mark".*?</span>}m, "").strip.gsub(/<[^>]+>/, "")
      end
    end

    it "drives a real set of pages" do
      expect(bodies.length).to be > 25
    end

    it "writes no timestamp outside the one declared format" do
      over = bodies.filter_map do |path, body|
        actual = body.scan(FORMATTING_BARE_TIMESTAMP).length
        budget = FORMATTING_TIMESTAMP_BUDGET.fetch(path, 0)
        "#{path}: #{budget} allowed, #{actual} drawn" if actual > budget
      end

      expect(over).to be_empty, lambda {
        "#{over.length} screen(s) print a raw time. Run it through PRIM_FORMAT.timestamp:\n  #{over.join("\n  ")}"
      }
    end

    it "draws every button label from the lexicon or from the list of ones still to fix" do
      outside = bodies.values.flat_map { |body| button_labels(body) }.uniq -
                BUTTON_LEXICON - BUTTON_UNVOCABULARY.keys

      expect(outside).to be_empty, lambda {
        "#{outside.length} button label(s) are in neither the lexicon nor BUTTON_UNVOCABULARY:\n" \
          "  #{outside.join("\n  ")}\n" \
          "Pick the lexicon's word for the verb, or argue for a new one by adding it there."
      }
    end

    it "delists a label once nothing draws it" do
      drawn = bodies.values.flat_map { |body| button_labels(body) }.uniq

      expect(BUTTON_UNVOCABULARY.keys - drawn).to be_empty
    end

    it "keeps the lexicon itself to sentence case, verb first, no article" do
      offenders = BUTTON_LEXICON.reject do |label|
        words = label.split
        first_ok = words.first == words.first.sub(/\A./, &:upcase)
        rest_ok = words.drop(1).none? { |word| word != word.downcase }
        first_ok && rest_ok && (words.map(&:downcase) & %w[a an the]).empty?
      end

      expect(offenders).to be_empty, "labels breaking the rule: #{offenders.join(", ")}"
    end

    it "offers no raw enum token as its own option label outside the budget" do
      over = bodies.filter_map do |path, body|
        actual = raw_options(body)
        budget = FORMATTING_RAW_OPTION_BUDGET.fetch(path, 0)
        "#{path}: #{budget} allowed, #{actual} drawn" if actual > budget
      end

      expect(over).to be_empty, lambda {
        "#{over.length} screen(s) show a reader an enum token:\n  #{over.join("\n  ")}\n" \
          "A Field select humanises its options, and a declared label table lives with the enum."
      }
    end

    it "adds the budgets up to the headline totals" do
      expect(FORMATTING_TIMESTAMP_BUDGET.values.sum).to eq(FORMATTING_REMAINING[:timestamps])
      # The feature and scope pickers name rows rather than enum values, so they
      # are counted apart from the enums that get a label table.
      expect(FORMATTING_RAW_OPTION_BUDGET.values.sum - FORMATTING_FEATURE_PICKER)
        .to eq(FORMATTING_REMAINING[:raw_options])
    end
  end
end
