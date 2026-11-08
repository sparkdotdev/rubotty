# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The script editor pages. The flow worth pinning end to end is save, check, then
# turn on, and that the middle step cannot be skipped or outlived by an edit.
RSpec.describe "Rubotty::Dashboard::App scripts", :control_plane do
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

  def create(name: "guard", kind: "processor", source: 'return { action = "allow" }',
             trigger_type: "always", **rest)
    post "/communities/sample/scripts", { name: name, kind: kind, source: source,
                                        trigger_type: trigger_type, language: "lua" }.merge(rest)
    deps.scripts.find_by_name(community, name)
  end

  describe "the list" do
    it "renders with nothing saved" do
      get "/communities/sample/scripts"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("No scripts yet")
    end

    it "shows a saved script as off and unchecked" do
      create

      get "/communities/sample/scripts"
      expect(last_response.body).to include("guard").and include("not checked since it was last edited")
    end
  end

  # A script may carry several conditions and may ask to hear edits. Both have to be
  # reachable from the editor, or the feature exists only for whoever drives the API.
  describe "conditions, more than one of them" do
    it "saves the extra conditions the form ticked" do
      row = create(trigger_type: "command", trigger_name: "deal", trigger_also: %w[always])

      expect(deps.scripts.trigger_config(row)["triggers"]).to eq(["always"])
    end

    it "drops a tick that repeats the first condition, rather than folding twice" do
      row = create(trigger_type: "always", trigger_also: %w[always])

      expect(deps.scripts.trigger_config(row)).not_to have_key("triggers")
    end

    it "ignores a condition that is not in the catalog" do
      row = create(trigger_type: "always", trigger_also: %w[arbitrary_lookback])

      expect(deps.scripts.trigger_config(row)).not_to have_key("triggers")
    end

    it "ticks them again when the page is loaded back" do
      row = create(trigger_type: "command", trigger_name: "deal", trigger_also: %w[always])

      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).to match(/trigger_also\[\]" value="always"\s+checked/)
    end

    # The form has one set of boxes, so building the list from the checkboxes
    # alone would throw away settings the API gave a second condition.
    it "keeps settings an API-written condition carried, through a save here" do
      row = create(trigger_type: "always")
      deps.scripts.save(community: community, id: row.id, name: "guard", kind: "processor",
                        source: 'return { action = "allow" }', trigger_type: "always",
                        trigger_config: { "triggers" => [{ "type" => "contains", "words" => %w[bingo] }] })

      create(trigger_type: "always", trigger_also: %w[contains])

      expect(deps.scripts.trigger_config(deps.scripts.find(community, row.id))["triggers"])
        .to eq([{ "type" => "contains", "words" => %w[bingo] }])
    end

    it "saves the edits tick, and loads it back ticked" do
      row = create(trigger_edits: "true")

      expect(deps.scripts.trigger_config(row)["edits"]).to eq("true")
      get "/communities/sample/scripts/#{row.id}"
      expect(last_response.body).to include(%(<option value="true" selected>Yes</option>))
    end

    it "leaves it off when nobody ticked it" do
      expect(deps.scripts.trigger_config(create)).not_to have_key("edits")
    end
  end

  # A guide can be installed privately, but is optional in a release snapshot.
  describe "the documentation page" do
    before { install_dashboard_guide_fixture }
    after { remove_dashboard_guide_fixtures }

    it "renders the scripting reference inline" do
      get "/documentation"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Scripting reference").and include("What wakes a script")
    end

    it "is linked from the scripts page" do
      get "/communities/sample/scripts"

      expect(last_response.body).to include("Read the scripting reference").and include("/documentation")
    end

    it "keeps every supplied host function entry in the rendered guide" do
      get "/documentation"

      body = last_response.body
      missing = Rubotty::Scripting::HostFunctions::CATALOG.each_key.reject { |name| body.include?(name.to_s) }

      expect(missing).to be_empty, "the reference never mentions #{missing.join(', ')}"
    end

    it "preserves the installed guide's state and HTTP function references" do
      get "/documentation"

      body = last_response.body
      expect(body).to include("remember")
      expect(body).to include("async_http")
    end

    # Both documents share a renderer, but warming its README cache must not
    # replace the scripting reference with another copy of that document.
    it "keeps the scripting reference after the README has been rendered" do
      get "/"
      get "/documentation"

      expect(last_response.body).to include(%(<h1 id="scripting-reference">Scripting reference</h1>))
      expect(last_response.body).to include("async_http")
    end
  end

  describe "without an installed scripting guide" do
    before { install_dashboard_guide_fixture(present: false) }
    after { remove_dashboard_guide_fixtures }

    it "shows an honest empty state and keeps the project README available" do
      get "/documentation"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("The scripting reference is not shipped alongside this build")
      expect(last_response.body).to include("Forking and Contributions")
      expect(last_response.body).not_to include(%(<h1 id="scripting-reference">))
    end

    it "reports an absent guide and keeps the README through the internal endpoint" do
      get "/internal/documentation"

      expect(last_response.status).to eq(200)
      document = YAMLCamel.load(last_response.body)
      expect(document["markup"]).to be_nil
      expect(document["document"]).to eq("scripting")
      expect(document["readme_markup"]).to include("Forking and Contributions")
    end
  end

  describe "the editor" do
    it "offers every trigger in the catalog and nothing else" do
      get "/communities/sample/scripts/new"

      Rubotty::Scripting::Triggers.type_names.each do |type|
        expect(last_response.body).to include(%(<option value="#{type}"))
      end
    end

    # The list is generated from the sandbox definition, so the page cannot offer a
    # function the runtime lacks.
    it "embeds a completion list built from the sandbox and the host catalog" do
      get "/communities/sample/scripts/new"

      body = last_response.body
      expect(body).to include('id="script-completions"')
      expect(body).to include("rubotty.classify").and include("string.gsub")
      expect(body).not_to include('"label":"io"')
    end

    # Picking one has to fill the trigger too, since an example only works with the
    # rule it was written for.
    it "embeds every shipped example with the trigger it expects" do
      get "/communities/sample/scripts/new"

      payload = JSON.parse(last_response.body[%r{<script type="application/json" id="script-examples">(.*?)</script>}m, 1])
      expect(payload.length).to eq(Rubotty::Scripting::Examples.all.length)
      expect(payload.map { |e| e["id"] }).to include("commands/roll", "processors/softener")

      roll = payload.find { |e| e["id"] == "commands/roll" }
      expect(roll["kind"]).to eq("command")
      expect(roll["trigger_type"]).to eq("command")
      expect(roll["sources"]["lua"]).to include("Usage: /roll 2d6")
    end

    # The page carries every hand written source and the picker chooses by language.
    # Compiled output is never among them.
    it "carries each example's hand written dialects, and no compiler output" do
      get "/communities/sample/scripts/new"

      payload = JSON.parse(last_response.body[%r{<script type="application/json" id="script-examples">(.*?)</script>}m, 1])

      payload.each do |example|
        sources = example["sources"]
        expect(sources.keys).to include("lua"), "#{example["id"]} has no Lua"
        expect(sources.keys - Rubotty::Scripting::Dialects.names).to be_empty
        expect(sources.values).to all(satisfy { |body| !body.include?("local _class_0") })
      end
    end

    it "loads an existing script back into the form" do
      row = create(source: 'return { action = "reject", reason = "no" }')

      get "/communities/sample/scripts/#{row.id}"
      expect(last_response.body).to include("reason = &quot;no&quot;")
    end

    # The data file beside the code: two documents, one form, one POST, which is
    # what lets the toggle save nothing by itself.
    describe "the Data pane" do
      it "offers a toggle and a box for the data file" do
        get "/communities/sample/scripts/new"

        expect(last_response.body).to include("script-pane-toggle")
          .and include("data-pane-body=\"code\"")
          .and include("data-pane-body=\"data\"")
          .and include("name=\"yaml_data\"")
      end

      it "saves the data beside the code and loads it back, comments and all" do
        row = create(yaml_data: "# the list\nwords:\n  - airdrop\n")

        expect(deps.scripts.yaml_data(row)).to eq({ "words" => ["airdrop"] })
        get "/communities/sample/scripts/#{row.id}"
        expect(last_response.body).to include("# the list")
      end

      it "refuses a broken document at save and leaves the draft on screen" do
        post "/communities/sample/scripts", { name: "guard", kind: "processor", language: "lua",
                                            source: 'return { action = "allow" }',
                                            trigger_type: "always",
                                            yaml_data: "words:\n  - a\n bad: yes\n" }

        follow_redirect!
        expect(last_response.body).to include("not valid YAML")
        expect(deps.scripts.find_by_name(community, "guard")).to be_nil
      end
    end

    # A page showing only "checked" reads as though the script were running, so both
    # states are on the page with the switch beside them.
    it "shows whether it is on, not just whether it passed the check" do
      row = create

      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).to include(">off<").and include("/enable")
      expect(last_response.body).to include("A new script starts off")
    end

    it "sends the switch back to the script rather than the list" do
      row = create
      post "/communities/sample/scripts/#{row.id}/enable", back: "script"

      expect(last_response.headers["Location"]).to end_with("/scripts/#{row.id}")
    end

    it "still returns to the list when the switch was thrown from there" do
      row = create
      post "/communities/sample/scripts/#{row.id}/enable"

      expect(last_response.headers["Location"]).to end_with("/scripts")
    end

    # Rendered from the trigger classes themselves, so the page cannot offer a field
    # the code ignores.
    # One list, in the order the editor offers them, which is the same payload
    # the internal surface sends a themed editor.
    def trigger_help
      body = last_response.body[%r{<script type="application/json" id="trigger-help">(.*?)</script>}m, 1]
      JSON.parse(body).to_h { |entry| [entry["name"], entry] }
    end

    it "explains every trigger, from the triggers themselves" do
      get "/communities/sample/scripts/new"

      help = trigger_help

      expect(help.keys).to match_array(Rubotty::Scripting::Triggers.type_names)
      Rubotty::Scripting::Triggers::TYPES.each do |type|
        expect(help[type.type_name]["summary"]).not_to be_empty, "#{type.type_name} explains nothing"
        expect(help[type.type_name]["fields"]).to eq(type.fields)
      end
    end

    it "asks for a command name only where a command name is read" do
      get "/communities/sample/scripts/new"

      help = trigger_help

      expect(help["command"]["fields"]).to eq(["name"])
      expect(help["always"]["fields"]).to be_empty
    end

    # The reference itself moved off this page: it ran to hundreds of rows under
    # the editor and buried the thing an operator came here to do. What has to
    # survive that move is the guarantee, so the coverage of every function is
    # asserted against the page it moved to, further down this file.
    it "sends an operator to the reference rather than printing it under the editor" do
      get "/communities/sample/scripts/new"

      body = last_response.body
      expect(body).to include("Read the scripting reference")
      expect(body).to include("/documentation")
      expect(body).not_to include(%(<table class="host-functions">))
    end

    # A new tab, because the link sits under a half-written script and losing it
    # to a navigation is exactly the thing that makes somebody not click.
    it "opens the reference in its own tab, so an unsaved script survives" do
      get "/communities/sample/scripts/new"

      anchor = last_response.body[/<a[^>]*documentation[^>]*>/]

      expect(anchor).not_to be_nil
      expect(anchor).to include(%(target="_blank"))
      expect(anchor).to include(%(rel="noopener"))
    end

    it "says pcall is not needed, since that is the first thing people reach for" do
      get "/communities/sample/scripts/new"

      expect(last_response.body).to include("You do not need <code>pcall</code>")
    end

    it "404s a script id from another community" do
      row = create
      models.community.create(slug: "other", name: "Other", status: "active",
                              created_at: Time.now, updated_at: Time.now)

      get "/communities/other/scripts/#{row.id}"
      expect(last_response.status).to eq(404)
    end
  end

  describe "saving" do
    it "keeps a broken script rather than refusing it" do
      row = create(source: "this is not lua")

      expect(row).not_to be_nil
      expect(row.enabled).to be_falsey
    end

    # Every enabled processor runs on every message, so a room's traffic cost is
    # multiplied by how many there are.
    it "refuses a new script past the per community cap, and says why" do
      stub_const("Rubotty::ControlPlane::Scripts::MAX_SCRIPTS", 2)
      create(name: "one")
      create(name: "two")

      post "/communities/sample/scripts", name: "three", kind: "processor",
                                        source: "return 1", trigger_type: "always"
      follow_redirect! if last_response.redirect?

      expect(last_response.body).to include("which is the limit")
      expect(deps.scripts.list(community).length).to eq(2)
    end

    it "still lets an existing script be edited at the cap" do
      stub_const("Rubotty::ControlPlane::Scripts::MAX_SCRIPTS", 1)
      row = create(name: "one")

      post "/communities/sample/scripts", id: row.id, name: "one", kind: "processor",
                                        source: 'return { action = "reject" }',
                                        trigger_type: "always", language: "lua"

      expect(deps.scripts.find(community, row.id).source).to include("reject")
    end

    it "reports a name it will not take" do
      post "/communities/sample/scripts", name: "  ", kind: "processor", source: "return 1",
                                        trigger_type: "always"
      follow_redirect! if last_response.redirect?

      expect(last_response.body).to include("needs a name")
    end
  end

  describe "check then turn on" do
    it "refuses to turn on a script that has not been checked" do
      row = create

      post "/communities/sample/scripts/#{row.id}/enable"
      follow_redirect!

      expect(last_response.body).to include("has not passed its smoke test")
      expect(deps.scripts.find(community, row.id).enabled).to be_falsey
    end

    context "with an interpreter" do
      before do
        skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
      end

      it "passes a sound script, then lets it go live" do
        row = create

        post "/communities/sample/scripts/#{row.id}/verify"
        follow_redirect!
        expect(last_response.body).to include("No obvious errors")

        post "/communities/sample/scripts/#{row.id}/enable"
        expect(deps.scripts.runnable?(deps.scripts.find(community, row.id))).to be(true)
      end

      it "reports what a broken script did wrong and leaves it off" do
        row = create(source: 'return { action = m.nothing.here }')

        post "/communities/sample/scripts/#{row.id}/verify"
        follow_redirect!

        expect(last_response.body).to include("Not ready")
        expect(deps.scripts.verified?(deps.scripts.find(community, row.id))).to be(false)
      end

      # The check answers whether it falls over; this answers what it does, without
      # turning it on and waiting for a member to say the magic word.
      describe "trying it against your own message" do
        it "shows what the script answered" do
          row = create(kind: "command", trigger_type: "command", trigger_name: "roll",
                       source: 'return "you rolled " .. rubotty.args()')

          post "/communities/sample/scripts/#{row.id}/try", try_text: "/roll 2d6"

          expect(last_response.body).to include("you rolled 2d6")
        end

        it "says the trigger did not match rather than blaming the code" do
          row = create(kind: "command", trigger_type: "command", trigger_name: "roll",
                       source: 'return "never reached"')

          post "/communities/sample/scripts/#{row.id}/try", try_text: "just talking"

          expect(last_response.body).to include("did not match")
          # The source is on the page in the editor, so only a missing answer proves
          # the script never ran.
          expect(last_response.body).not_to include("the script answered")
        end

        # It runs a rule that is still off and unverified, so it must not reach a room.
        it "posts nothing anywhere, even for a script that calls notify" do
          row = create(trigger_type: "always",
                       source: 'rubotty.notify("hello room"); return { action = "allow" }')

          post "/communities/sample/scripts/#{row.id}/try", try_text: "anything"

          expect(last_response.status).to eq(200)
          expect(deps.scripts.runnable?(deps.scripts.find(community, row.id))).to be(false)
        end
      end

      # The property the digest scheme exists for, through the pages an operator uses.
      it "puts a live script back to off when it is edited" do
        row = create
        post "/communities/sample/scripts/#{row.id}/verify"
        post "/communities/sample/scripts/#{row.id}/enable"
        expect(deps.scripts.runnable?(deps.scripts.find(community, row.id))).to be(true)

        post "/communities/sample/scripts", id: row.id, name: "guard", kind: "processor",
                                          source: 'return { action = "reject" }',
                                          trigger_type: "always", language: "lua"

        edited = deps.scripts.find(community, row.id)
        expect(edited.enabled).to be_falsey
        expect(deps.scripts.verified?(edited)).to be(false)
      end
    end
  end

  describe "authorization" do
    it "keeps an operator out, since running code is not an operator action" do
      post "/logout"
      operator = models.operator.first
      post "/login", secret: "wrong" if operator.nil?

      get "/communities/sample/scripts"
      expect(last_response.status).to eq(302).or eq(403)
    end
  end

  describe "archiving" do
    it "takes it out of the list without losing the text" do
      row = create

      post "/communities/sample/scripts/#{row.id}/delete"

      expect(deps.scripts.list(community)).to be_empty
      kept = deps.scripts.find(community, row.id)
      expect(kept.source).to include("allow")
      expect(kept.archived_at).not_to be_nil
    end

    # Deleting archives rather than destroys, and the flash says so, so the archive
    # has to be reachable.
    it "lists a deleted script so it can be brought back" do
      row = create(name: "guard")
      post "/communities/sample/scripts/#{row.id}/delete"

      get "/communities/sample/scripts"
      expect(last_response.body).to include("Deleted").and include("/restore")
    end

    it "brings one back, off and unchecked" do
      row = create(name: "guard")
      post "/communities/sample/scripts/#{row.id}/delete"

      post "/communities/sample/scripts/#{row.id}/restore"

      back = deps.scripts.find(community, row.id)
      expect(back.archived_at).to be_nil
      expect(back.enabled).to be_falsey
      expect(deps.scripts.verified?(back)).to be(false)
      expect(deps.scripts.list(community).map(&:id)).to include(row.id)
    end

    it "says nothing about an archive that is empty" do
      create(name: "guard")

      get "/communities/sample/scripts"
      expect(last_response.body).not_to include("/restore")
    end

    # The unique index would otherwise keep the old name reserved.
    it "frees the name for a replacement" do
      row = create(name: "guard")
      post "/communities/sample/scripts/#{row.id}/delete"

      replacement = create(name: "guard")

      expect(replacement).not_to be_nil
      expect(replacement.id).not_to eq(row.id)
      expect(deps.scripts.find(community, row.id).name).to include("archived")
    end
  end

  # What a script has been doing belongs beside the script rather than on the
  # alerts board and the analytics page, which is what an operator asking "is
  # this rule working" had to visit before.
  describe "the activity on a script's own page" do
    it "shows the failure counter and what it last went wrong with" do
      row = create(name: "guard")
      deps.scripts.record_error(deps.scripts.find(community, row.id), "attempt to index a nil value")

      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).to include("consecutive failures")
        .and include("attempt to index a nil value")
    end

    it "counts every failure since the last clean run rather than only the last one" do
      row = create(name: "guard")
      3.times { deps.scripts.record_error(deps.scripts.find(community, row.id), "boom") }

      get "/communities/sample/scripts/#{row.id}"
      stats = last_response.body.scan(
        %r{<div class="rb-stat-value">(\d+)</div><div class="rb-stat-label">([^<]+)</div>}
      )
      counter = stats.find { |_value, caption| caption == "consecutive failures" }&.first

      expect(counter).to eq("3")
    end

    it "says nothing has failed when nothing has" do
      row = create(name: "guard")

      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).to include("This script has not failed on real traffic.")
    end

    it "shows the alerts this script raised and none another script raised" do
      row = create(name: "guard")
      deps.alerts.record(community_id: community.id, text: "a link from a new account",
                         room_key: "general", script: "guard")
      deps.alerts.record(community_id: community.id, text: "somebody said hello", script: "welcome")

      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).to include("a link from a new account").and include("general")
      expect(last_response.body).not_to include("somebody said hello")
    end

    it "says a loud alert reached nobody, which is the case only this page carries" do
      row = create(name: "guard")
      deps.alerts.record(community_id: community.id, text: "a slur in general", script: "guard",
                         mode: Rubotty::ControlPlane::Alerts::LOUD)

      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).to include("loud, reached nobody")
    end

    it "counts how many times the script has actually run" do
      row = create(name: "guard")
      script = deps.scripts.find(community, row.id)
      2.times { deps.scripts.record_run(script) }
      deps.scripts.record_run(script, failed: true)
      deps.scripts.flush_runs

      get "/communities/sample/scripts/#{row.id}"
      stats = last_response.body.scan(
        %r{<div class="rb-stat-value">(\d+)</div><div class="rb-stat-label">([^<]+)</div>}
      )
      counter = stats.find { |_value, caption| caption == "runs" }&.first

      expect(counter).to eq("3")
    end

    # Room games are a different board and stay one: this page is about one
    # script's own traffic.
    it "draws nothing about room games" do
      row = create(name: "guard")

      get "/communities/sample/scripts/#{row.id}"

      expect(last_response.body).not_to include("room games")
    end
  end

  # A stat carries no script name, so it cannot go on one script's page. It
  # sits with the scripts rather than among the numbers rubotty counts itself.
  describe "the numbers scripts recorded for themselves" do
    before do
      deps.script_stats.increment(community: community, stat: "commands", row: "roll", step: 4)
      deps.script_stats.flush
    end

    it "draws them on the scripts page" do
      get "/communities/sample/scripts"

      expect(last_response.body).to include("What your scripts recorded")
        .and include("commands").and include("roll")
    end

    it "no longer draws them on the analytics page" do
      get "/communities/sample/analytics"

      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include("Script Supplied Analytics")
      expect(last_response.body).not_to include("What your scripts recorded")
    end

    it "says nothing on a page where no script has recorded anything" do
      other = models.community.create(slug: "quiet", name: "Quiet", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)

      get "/communities/#{other.slug}/scripts"

      expect(last_response.body).not_to include("What your scripts recorded")
    end
  end
end
