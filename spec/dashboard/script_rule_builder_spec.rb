# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

# The condition rule builder, driven as the real compiled module. A
# script may carry several conditions tried in order; the list UI
# replaces the old select-plus-checkboxes presentation and nothing
# else, so every edit must still land in trigger_type/trigger_also[].
RSpec.describe "the script condition rule builder", :control_plane do
  RULES_ROOT = File.expand_path("../..", __dir__)
  RULES_SUPPORT = File.expand_path("../support", __dir__)
  RULES_TOOLS = %w[node civet esbuild].freeze

  def run!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

    out
  end

  # The same two build steps package.json runs, over the real source, so this
  # never checks yesterday's bundle.
  def build_rules_bundle
    FileUtils.mkdir_p(File.join(RULES_ROOT, "tmp"))
    dir = Dir.mktmpdir("rule-builder", File.join(RULES_ROOT, "tmp"))
    compiled = File.join(dir, "civet")
    FileUtils.mkdir_p(compiled)
    run!(ThemeToolchain.path("civet"), "--js", "-c",
         *Dir.glob(File.join(RULES_ROOT, "assets/themes/runtime/*.civet")), "-o", "#{compiled}/.js")
    bundle = File.join(dir, "script-rules.js")
    run!(ThemeToolchain.path("esbuild"), File.join(compiled, "script-rules.js"), "--bundle",
         "--format=iife", "--global-name=rubottyScriptRules", "--outfile=#{bundle}")
    { dir: dir, bundle: bundle }
  end

  # Every trigger as the wire sends it, off the real classes rather than a
  # hand-written list, so a new trigger is covered the day it lands.
  def catalogue
    Rubotty::Scripting::Triggers::TYPES.map do |type|
      { "name" => type.type_name, "summary" => type.summary,
        "fields" => type.fields, "hands" => type.hands_over }
    end
  end

  if ThemeToolchain.ready?(RULES_TOOLS)
    before(:context) { @build = build_rules_bundle }
    after(:context) { FileUtils.remove_entry(@build[:dir], true) }

    def drive(trigger_type:, trigger_also: [], act: [], max_conditions: 4)
      path = File.join(@build[:dir], "case.json")
      File.write(path, JSON.generate(
        "trigger_type" => trigger_type, "trigger_also" => trigger_also,
        "triggers" => catalogue, "max_conditions" => max_conditions, "act" => act
      ))
      JSON.parse(run!(ThemeToolchain.path("node"),
                      File.join(RULES_SUPPORT, "script_rules_harness.js"), @build[:bundle], path))
    end

    it "reads the real controls as one ordered list, the primary first" do
      drawn = drive(trigger_type: "command", trigger_also: %w[contains recurring])

      expect(drawn["rules"]).to eq(%w[command contains recurring])
    end

    it "draws one row per rule out of the ordinary Field and Button vocabulary" do
      html = drive(trigger_type: "command", trigger_also: ["contains"]).fetch("html")

      expect(html.scan(%(class="rb-field rb-field--medium")).length).to eq(2)
      expect(html).to include("Runs when")
      expect(html).to include("Or when")
      expect(html).to include("Add condition")
      bespoke = html.scan(/\bclass="([^"]*)"/).flatten.flat_map(&:split).uniq -
                Rubotty::Dashboard::Primitives::CLASSES
      expect(bespoke).to be_empty, "class(es) outside the vocabulary: #{bespoke.join(', ')}"
    end

    it "says what the set adds up to, in order, rather than leaving it to be inferred" do
      html = drive(trigger_type: "command", trigger_also: ["contains"]).fetch("html")

      expect(html).to include("rb-notice--info")
      expect(html).to include(Rubotty::Scripting::Triggers::BY_NAME.fetch("command").summary[0, 30])
    end

    it "offers no Remove on the first rule, since a script with no condition never runs" do
      html = drive(trigger_type: "command", trigger_also: ["contains"]).fetch("html")

      expect(html.scan(%(name="rule-remove")).length).to eq(1)
    end

    it "adds a condition into trigger_also[] and never into trigger_type" do
      drawn = drive(trigger_type: "command", act: [{ "click" => "rule-add" }])

      expect(drawn["triggerType"]).to eq("command")
      expect(drawn["triggerAlso"].length).to eq(1)
      expect(drawn["rules"].first).to eq("command")
    end

    it "removes the rule at the position asked for, leaving the rest in order" do
      drawn = drive(trigger_type: "command", trigger_also: %w[contains recurring],
                    act: [{ "click" => "rule-remove", "value" => "1" }])

      expect(drawn["rules"]).to eq(%w[command recurring])
      expect(drawn["triggerAlso"]).to eq(["recurring"])
    end

    it "keeps the first rule as trigger_type when somebody changes it" do
      drawn = drive(trigger_type: "command", trigger_also: ["contains"],
                    act: [{ "pick" => 0, "value" => "always" }])

      expect(drawn["triggerType"]).to eq("always")
      expect(drawn["triggerAlso"]).to eq(["contains"])
    end

    it "refuses to add past the ceiling the server declared" do
      drawn = drive(trigger_type: "command", trigger_also: ["contains"], max_conditions: 2,
                    act: [{ "click" => "rule-add" }])

      expect(drawn["rules"].length).to eq(2)
      expect(drawn["html"]).to include("A script may carry 2 conditions")
    end

    it "never lets the same condition sit in the list twice" do
      drawn = drive(trigger_type: "command", trigger_also: ["contains"],
                    act: [{ "pick" => 1, "value" => "command" }])

      expect(drawn["rules"].uniq).to eq(drawn["rules"])
    end
  else
    it "is skipped: the theme toolchain is not installed" do |example|
      ThemeToolchain.report_gap!(example, RULES_TOOLS, "the condition rule builder")
    end
  end

  # The half the server owns: whatever the list produces still has to be a
  # request the existing route understands, with no new parameter.
  describe "the request the list posts", :control_plane do
    include Rack::Test::Methods

    let(:seeded) { seeded_sample }
    let(:db) { seeded[0] }
    let(:secret) { "open-sesame" }
    let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret }) }
    let(:community) { deps.models.community.where(slug: "sample").first }

    before { post("/login", secret: secret) }

    it "still takes trigger_type plus trigger_also[], in the order the list showed" do
      post "/communities/sample/scripts",
           name: "ordered", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "command", trigger_also: %w[contains recurring], trigger_name: "roll"
      row = deps.scripts.find_by_name(community, "ordered")

      expect(row).not_to be_nil
      declared = Rubotty::Scripting::Triggers.declared(row.trigger_type, deps.scripts.trigger_config(row))
      expect(declared.map(&:first)).to eq(%w[command contains recurring])
    end

    it "drops a rule the list removed rather than keeping it because it was there before" do
      post "/communities/sample/scripts",
           name: "trimmed", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "command", trigger_also: %w[contains recurring], trigger_name: "roll"
      row = deps.scripts.find_by_name(community, "trimmed")
      post "/communities/sample/scripts",
           id: row.id, name: "trimmed", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "command", trigger_also: ["recurring"], trigger_name: "roll"
      row = deps.scripts.find_by_name(community, "trimmed")

      declared = Rubotty::Scripting::Triggers.declared(row.trigger_type, deps.scripts.trigger_config(row))
      expect(declared.map(&:first)).to eq(%w[command recurring])
    end

    it "reads the whole ordered set back onto the editor, primary and extras alike" do
      post "/communities/sample/scripts",
           name: "reread", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "command", trigger_also: ["contains"], trigger_name: "roll"
      row = deps.scripts.find_by_name(community, "reread")
      view = Rubotty::Dashboard::ViewData.new(deps: deps, role: Rubotty::Dashboard::Role.administrator)
      script = view.script_edit("sample", id: row.id)["script"]

      expect(script["trigger_type"]).to eq("command")
      expect(script["trigger_also"]).to eq(["contains"])
    end

    it "says the order on the page itself, so a reader knows the first match wins" do
      post "/communities/sample/scripts",
           name: "listed", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "command", trigger_also: ["contains"], trigger_name: "roll"
      row = deps.scripts.find_by_name(community, "listed")
      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).to include("Tried in order: 1. command, 2. contains")
      expect(last_response.body).to include("The first that matches wins")
    end
  end
end
