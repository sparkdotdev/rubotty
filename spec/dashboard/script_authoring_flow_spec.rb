# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "json"

# The order somebody writes a script in: when it runs, then the code
# and data, then the check and the switch. A rule saved before anybody
# decided what wakes it is a rule nobody can check. What is optional
# stays folded: an ordinary script starts from a blank box.
RSpec.describe "the script authoring flow", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { deps.models.community.where(slug: "sample").first }

  before { post("/login", secret: secret) }

  def saved_script
    deps.scripts.save(
      community: community, name: "greeter", kind: "processor",
      source: 'return { action = "allow" }', trigger_type: "command",
      trigger_config: { "name" => "roll" }, created_by: "administrator"
    )
  end

  def body_of(path)
    get path
    raise "#{path} answered #{last_response.status}" unless last_response.status == 200

    last_response.body
  end

  # Where each named step starts, so "before" and "after" mean position on the
  # page rather than order in the source.
  def step_positions(body)
    %w[When\ it\ runs Code\ and\ data Check\ and\ turn\ on].to_h { |step| [step, body.index(">#{step}<")] }
  end

  describe "the server-rendered editor" do
    it "runs the three steps in order, so nothing is asked for before it can be answered" do
      at = step_positions(body_of("/communities/sample/scripts/new"))

      expect(at.values).to all(be_a(Integer)), "missing step(s): #{at.select { |_, v| v.nil? }.keys.join(', ')}"
      expect(at["When it runs"]).to be < at["Code and data"]
      expect(at["Code and data"]).to be < at["Check and turn on"]
    end

    it "asks what wakes the script inside the first step rather than after the code" do
      body = body_of("/communities/sample/scripts/new")
      at = step_positions(body)

      expect(body.index(%(id="rb-field-trigger_type"))).to be > at["When it runs"]
      expect(body.index(%(id="rb-field-trigger_type"))).to be < at["Code and data"]
      expect(body.index(%(name="name"))).to be < body.index(%(id="rb-field-trigger_type"))
    end

    it "folds the examples and the extra conditions away until somebody wants them" do
      body = body_of("/communities/sample/scripts/new")
      folded = body.scan(%r{<details class="rb-section rb-section--collapsible"[^>]*>.*?</details>}m)
      summaries = folded.map { |one| one[%r{<summary class="rb-section-title">(.*?)</summary>}m, 1] }

      expect(summaries).to include("Start from an example").and include("More conditions")
      expect(folded).to all(satisfy { |one| !one.match?(/<details[^>]*\bopen\b/) })
    end

    it "keeps the example picker and the extra conditions inside the fold, not beside the code box" do
      body = body_of("/communities/sample/scripts/new")
      folded = body.scan(%r{<details class="rb-section rb-section--collapsible"[^>]*>.*?</details>}m)
      inside = folded.join

      expect(inside).to include(%(id="example-picker"))
      expect(inside).to include(%(name="trigger_also[]"))
    end

    # The behaviour moved to assets/dashboard/runtime/script-triggers.civet, which
    # reads the same table off the page. What must not come back is a second
    # copy of the deciding logic written inline.
    it "carries the trigger table as data and no behaviour of its own" do
      body = body_of("/communities/sample/scripts/new")
      inline = body.scan(%r{<script(?![^>]*\bsrc=)(?![^>]*type="application/json")[^>]*>(.*?)</script>}m).flatten

      expect(body).to include(%(<script type="application/json" id="trigger-help">))
      expect(inline.join).not_to include("data-trigger-field")
      expect(inline.join).not_to include("trigger_also[]")
    end

    it "draws every condition box the trigger classes declare, for the module to narrow" do
      body = body_of("/communities/sample/scripts/new")
      declared = Rubotty::Scripting::Triggers::TYPES.flat_map(&:fields).uniq

      missing = declared.reject { |name| body.include?(%(id="rb-field-trigger_#{name}")) }
      expect(missing).to be_empty, "no box for: #{missing.join(', ')}"
    end
  end

  describe "the themed editor" do
    let(:administrator) { Rubotty::Dashboard::Role.administrator }
    let(:view_data) { Rubotty::Dashboard::ViewData.new(deps: deps, role: administrator) }

    it "serves the authoring flow off the internal surface, for a saved script and a blank one" do
      row = saved_script

      %W[/internal/communities/sample/scripts/new /internal/communities/sample/scripts/#{row.id}].each do |path|
        get path

        expect(last_response.status).to eq(200), "#{path} answered #{last_response.status}"
        expect(last_response.body).to include("section: script_edit")
      end
    end

    it "hands the client every trigger's own summary and fields, rather than a second copy of them" do
      payload = view_data.script_edit("sample")
      names = payload["triggers"].map { |entry| entry["name"] }

      expect(names).to eq(Rubotty::Scripting::Triggers::TYPES.map(&:type_name))
      payload["triggers"].each do |entry|
        type = Rubotty::Scripting::Triggers::BY_NAME.fetch(entry["name"])
        expect(entry["fields"]).to eq(type.fields)
        expect(entry["hands"]).to eq(type.hands_over)
      end
    end

    it "unpacks a saved script's conditions into the primary, the extras and the shared boxes" do
      row = deps.scripts.save(
        community: community, name: "watcher", kind: "processor",
        source: 'return { action = "allow" }', trigger_type: "command",
        trigger_config: { "name" => "roll", "words" => %w[free mint], "edits" => "true",
                          Rubotty::Scripting::Triggers::EXTRA_KEY => ["contains"] },
        created_by: "administrator"
      )
      script = view_data.script_edit("sample", id: row.id)["script"]

      expect(script["trigger_type"]).to eq("command")
      expect(script["trigger_also"]).to eq(["contains"])
      expect(script["trigger_edits"]).to be(true)
      expect(script["trigger_config"]["name"]).to eq("roll")
      expect(script["trigger_config"]["words"]).to eq("free\nmint")
    end

    it "404s a script id from another community rather than drawing it" do
      other = deps.models.community.where(slug: "sample").first
      row = saved_script
      expect(row.community_id).to eq(other.id)

      get "/internal/communities/sample/scripts/#{row.id + 999}"

      expect(last_response.status).to eq(404)
    end
  end

  # The toggle the themed editor draws submits the word either way, and an off
  # toggle used to read as on because any non-empty value did.
  describe "the edits tick, whichever control sent it" do
    it "reads an off toggle as off" do
      post "/communities/sample/scripts",
           name: "edits off", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "always", trigger_edits: "false"
      row = deps.scripts.find_by_name(community, "edits off")

      expect(row).not_to be_nil
      expect(deps.scripts.trigger_config(row)).not_to have_key("edits")
    end

    it "reads an on toggle as on" do
      post "/communities/sample/scripts",
           name: "edits on", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "always", trigger_edits: "true"
      row = deps.scripts.find_by_name(community, "edits on")

      expect(deps.scripts.trigger_config(row)["edits"]).to eq("true")
    end
  end
end
