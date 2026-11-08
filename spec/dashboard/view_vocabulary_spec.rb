# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"

# The vocabulary, checked statically: a ported view emits no HTML tag
# of its own, only primitive calls, ERB control flow and text. This is
# a burn-down: every view still drawing markup is listed below, its
# recorded count a ceiling, so adding markup to a listed view fails.
RSpec.describe "the dashboard view vocabulary" do
  VIEW_SOURCE_DIR = File.expand_path("../../lib/rubotty/dashboard/views", __dir__)

  # What a view is allowed to still draw itself, per file, with the reason. An
  # entry marks a view not yet ported; delete it once it is.
  VIEW_EXCEPTIONS = {
      "_config_fields.erb" =>
        { tags: 5, styles: 0, buttons: 0,
          why: "the generic schema form, ported with Form and Field" },
      "_config_input.erb" =>
        { tags: 8, styles: 0, buttons: 0,
          why: "one scalar control, factored out of _config_fields.erb so a mapping-list row can " \
               "reuse it under a bracketed name; the textarea branch is a multiline field's own control" },
      "_config_mapping_list.erb" =>
        { tags: 10, styles: 0, buttons: 2,
          why: "the row list, its add control and template, the named preset picker beside it for a " \
               "field with any, plus the inline script that adds and removes a row client-side" },
      "_config_mapping_row.erb" =>
        { tags: 12, styles: 0, buttons: 1,
          why: "one mapping-list row's labelled controls and its own remove button" },
      "_feature_row.erb" =>
        { tags: 8, styles: 0, buttons: 0,
          why: "one feature row's collapsed body: the retention note, the config summary, and its " \
               "inline editor form for a feature with no bespoke page, included by features.erb " \
               "once per row" },
      "_leftover_config.erb" =>
        { tags: 17, styles: 2, buttons: 1,
          why: "the same generic form embedded, ported with Form and Field" },
      "accounts.erb" =>
        { tags: 63, styles: 2, buttons: 4,
          why: "platform account CRUD, and the two step platform picker goes with it" },
      "alerts.erb" =>
        { tags: 5, styles: 0, buttons: 0,
          why: "a lede and one table assembled in app.rb, ported with Notice and Table" },
      "analytics.erb" =>
        { tags: 164, styles: 0, buttons: 0,
          why: "ten sections and twenty charts, ported with TabLinks and Chart" },
      "analytics_overview.erb" =>
        { tags: 31, styles: 0, buttons: 0,
          why: "one table of per community counts, merging into the communities index" },
      "api_keys.erb" =>
        { tags: 64, styles: 1, buttons: 2,
          why: "the key list and the mint form, ported with Table and Form" },
      "audit.erb" =>
        { tags: 12, styles: 0, buttons: 1,
          why: "one scope-aware filter form plus a table assembled in app.rb" },
      "backfill_proposals.erb" =>
        { tags: 12, styles: 0, buttons: 0,
          why: "the cards are assembled in app.rb, ported with Section and Table" },
      "community.erb" =>
        { tags: 24, styles: 0, buttons: 0,
          why: "five stats and a start/stop, merging into the nav landing and Connections" },
      "endpoint_edit.erb" =>
        { tags: 48, styles: 0, buttons: 0,
          why: "four cards of labelled controls, ported with Form and Field the way the themed editor is" },
      "endpoints.erb" =>
        { tags: 32, styles: 0, buttons: 1,
          why: "one table plus the anchor wrapping a button" },
      "events.erb" =>
        { tags: 97, styles: 5, buttons: 0,
          why: "the event list and its form, absorbing polls.erb" },
      "faq.erb" =>
        { tags: 81, styles: 4, buttons: 0,
          why: "the same scope drawn three times, becoming one list of scopes" },
      "feature_config.erb" =>
        { tags: 21, styles: 0, buttons: 1,
          why: "one feature at one scope, merging into Features as a row expansion" },
      "features.erb" =>
        { tags: 35, styles: 0, buttons: 1,
          why: "every feature as its own collapsible Section row (#1398); the scope-select and " \
               "escape-hatch forms and their raw View button are the rest" },
      "files.erb" =>
        { tags: 29, styles: 0, buttons: 1,
          why: "one table plus a usage-against-quota summary (#1772), ported with Table" },
      "forbidden.erb" =>
        { tags: 3, styles: 0, buttons: 0,
          why: "merging with not_found.erb into one error screen" },
      "guests.erb" =>
        { tags: 81, styles: 2, buttons: 0,
          why: "guest invites and portal settings, ported with Form and Table" },
      "index.erb" =>
        { tags: 28, styles: 0, buttons: 0,
          why: "the communities index, absorbing analytics_overview.erb and request_access.erb" },
      "integrations.erb" =>
        { tags: 108, styles: 2, buttons: 4,
          why: "one connection card drawn once for both connections, plus OpenArc's loaded-models " \
               "table and load-a-model form, ported with Form, Field and Table, and beside them " \
               "the standing reload instruction: what gets put back when the server drops the " \
               "model, and the one button that forgets it" },
      "layout.erb" =>
        { tags: 27, styles: 0, buttons: 0,
          why: "the page shell rather than a screen: loading assets, the unthemed floor the panel falls " \
               "back to before a theme draws, the hidden staging document, and the JSON shell document " \
               "consumed by the required Civet boot module. None of those belong to a screen, so no " \
               "primitive can draw them" },
      "moderation.erb" =>
        { tags: 76, styles: 4, buttons: 1,
          why: "search plus tables, ported with Form and Table" },
      "not_found.erb" =>
        { tags: 3, styles: 0, buttons: 0,
          why: "merging with forbidden.erb into one error screen" },
      "operators.erb" =>
        { tags: 196, styles: 0, buttons: 0,
          why: "five jobs on one screen, splitting into Operators and Access" },
      "participation.erb" =>
        { tags: 17, styles: 0, buttons: 0,
          why: "script telemetry nobody configures, merging into Alerts or the room row" },
      "people.erb" =>
        { tags: 61, styles: 2, buttons: 2,
          why: "the people list and the nickname control, ported with Table and Field" },
      "platforms.erb" =>
        { tags: 301, styles: 19, buttons: 0,
          why: "five jobs (IRC networks now included), a per-connection fetch ceiling (#1771) and " \
               "nineteen inline table widths, splitting into Connections and a bespoke join links page" },
      "polls.erb" =>
        { tags: 32, styles: 0, buttons: 0,
          why: "merging into events.erb as one Scheduled screen" },
      "redirections.erb" =>
        { tags: 4, styles: 0, buttons: 0,
          why: "a lede and one table assembled in app.rb" },
      "request_access.erb" =>
        { tags: 10, styles: 0, buttons: 1,
          why: "one button and two dead classes, merging into the communities index" },
      "rooms.erb" =>
        { tags: 49, styles: 0, buttons: 0,
          why: "the room list and a delete form on every card, ported with Table" },
      "script_edit.erb" =>
        { tags: 83, styles: 3, buttons: 2,
          why: "the code and data panes, which keep the editor bundle's own hooks until it mounts on " \
               "a themed draw" },
      "scripts.erb" =>
        { tags: 48, styles: 0, buttons: 1,
          why: "the script list, ported with Table and Button" },
      "viewers.erb" =>
        { tags: 124, styles: 0, buttons: 6,
          why: "six raw buttons and not one act_button call" },
      "webhooks.erb" =>
        { tags: 8, styles: 0, buttons: 0,
          why: "a lede and two tables assembled in app.rb" },
      "word_filter.erb" =>
        { tags: 68, styles: 2, buttons: 0,
          why: "the same scope drawn three times, the same shape as faq.erb" },
  }.freeze

  # The headline. Adding a file to VIEW_EXCEPTIONS means raising one of these in the
  # same change, which is the point: the list can only ever shrink quietly.
  VIEW_REMAINING = { tags: 2105, styles: 48, buttons: 32 }.freeze

  # ERB tags carry Ruby, not markup, so they come out before anything is
  # counted. What is left is what the view file itself puts on the page.
  def scan(path)
    body = File.read(path, encoding: "UTF-8").gsub(/<%.*?%>/m, "")
    {
      tags: body.scan(/<([a-zA-Z][a-zA-Z0-9]*)/).flatten,
      styles: body.scan(/\bstyle="/),
      buttons: body.scan(/<button\b/)
    }
  end

  def views = Dir.children(VIEW_SOURCE_DIR).select { |name| name.end_with?(".erb") }.sort

  def counts(name) = scan(File.join(VIEW_SOURCE_DIR, name)).transform_values(&:length)

  it "reads a real set of view files, so nothing here passes vacuously" do
    expect(views.length).to be >= 40
    expect(views.sum { |name| counts(name)[:tags] }).to be > 1000
  end

  it "leaves no view drawing its own markup without saying why" do
    unaccounted = views.reject { |name| VIEW_EXCEPTIONS.key?(name) }
                       .select { |name| counts(name).values.any?(&:positive?) }

    expect(unaccounted).to be_empty, lambda {
      "#{unaccounted.length} view(s) draw their own markup and are not in VIEW_EXCEPTIONS:\n" \
        "  #{unaccounted.join("\n  ")}"
    }
  end

  it "keeps the stated exceptions to views that exist" do
    expect(VIEW_EXCEPTIONS.keys - views).to be_empty
  end

  it "never lets a listed view draw more than it already does" do
    grown = VIEW_EXCEPTIONS.filter_map do |name, budget|
      actual = counts(name)
      over = %i[tags styles buttons].select { |kind| actual[kind] > budget[kind] }
      next nil if over.empty?

      "#{name}: #{over.map { |kind| "#{kind} #{budget[kind]} -> #{actual[kind]}" }.join(", ")}"
    end

    expect(grown).to be_empty, lambda {
      "#{grown.length} view(s) grew past their recorded burn-down budget:\n" \
        "  #{grown.join("\n  ")}\n" \
        "Draw it with a primitive instead, or lower nothing and explain in review."
    }
  end

  it "delists a view once it has nothing left to burn down" do
    done = VIEW_EXCEPTIONS.keys.select { |name| counts(name).values.none?(&:positive?) }

    expect(done).to be_empty, lambda {
      "#{done.length} view(s) are ported and still listed. Delete the entry and lower VIEW_REMAINING:\n" \
        "  #{done.join("\n  ")}"
    }
  end

  it "adds the list up to the headline totals" do
    VIEW_REMAINING.each_key do |kind|
      recorded = VIEW_EXCEPTIONS.values.sum { |budget| budget[kind] }
      expect(recorded).to eq(VIEW_REMAINING[kind]), "#{kind}: VIEW_EXCEPTIONS sums to #{recorded}, VIEW_REMAINING says #{VIEW_REMAINING[kind]}"
    end
  end

  it "gives every exception a reason" do
    silent = VIEW_EXCEPTIONS.reject { |_, budget| budget[:why].to_s.length > 20 }.keys

    expect(silent).to be_empty, "exceptions with no real reason: #{silent.join(", ")}"
  end

  # The rule that makes the widths structural rather than discouraged. A
  # primitive taking a style, class or width would let a screen put the three
  # widths of the new script page back one argument at a time.
  describe "the primitive signatures" do
    def primitive_methods
      [Rubotty::Dashboard::Primitives::Identity, Rubotty::Dashboard::Primitives::Layout]
        .flat_map { |mod| mod.public_instance_methods(false).map { |name| [mod, name] } }
    end

    it "draws all fifteen primitives and nothing else" do
      drawn = primitive_methods.map { |_, name| name }
      expect(drawn).to match_array(Rubotty::Dashboard::Primitives::NAMES.values + %i[tags may?])
    end

    it "takes no style, class or width argument anywhere in the set" do
      offenders = primitive_methods.flat_map do |mod, name|
        mod.instance_method(name).parameters.map(&:last)
           .select { |argument| Rubotty::Dashboard::Primitives::FORBIDDEN_ARGUMENTS.include?(argument) }
           .map { |argument| "#{mod}##{name} takes #{argument}" }
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end
  end
end
