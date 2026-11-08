# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# One hierarchy in every edit form, checked on the rendered page: the
# validation a reader needs, then subordinate controls, then one primary
# submit, last and nothing after it. A destructive control is never in
# that row; it posts elsewhere in its own action Form.
RSpec.describe "the dashboard form action hierarchy", :control_plane do
  include Rack::Test::Methods

  # The editors this rule was written for, blank and with a record saved.
  EDITORS = {
    "the new endpoint editor" => "/communities/sample/endpoints/new",
    "the new script editor" => "/communities/sample/scripts/new",
    "the connections editor" => "/communities/sample/platforms",
    "the feature config editor" => "/communities/sample/features/word_filter/config"
  }.freeze

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { deps.models.community.where(slug: "sample").first }

  # A saved endpoint, a saved script and a Fluxer instance, so the editors are
  # driven holding a record as well as blank. The instance is what gives the
  # connections page a genuine destructive control, and a page with none would
  # satisfy the rule below by having nothing to get wrong.
  before do
    deps.script_endpoints.save(
      community: community, name: "weather", url: "https://api.example.com/forecast",
      http_method: "GET", timeout_seconds: 5, enabled: true, created_by: "administrator"
    )
    deps.scripts.save(
      community: community, name: "greeter", kind: "processor", source: 'return { action = "allow" }',
      trigger_type: "always", trigger_config: {}, created_by: "administrator"
    )
    deps.fluxer_instances.create(
      community: community, label: "Flagship", kind: "flagship",
      endpoint_url: nil, api_key_env: "FLUXER_FLAGSHIP_API_KEY"
    )
    post("/login", secret: secret)
  end

  def endpoint_id = deps.script_endpoints.list(community).first.id

  def script_id = deps.scripts.list(community).first.id

  def body_of(path)
    get path
    raise "#{path} answered #{last_response.status}" unless last_response.status == 200

    last_response.body
  end

  # Forms are never nested, so a non-greedy scan is the whole of one each time.
  def forms(body) = body.scan(%r{<form\b.*?</form>}m)

  # A form somebody fills in, as opposed to the action Forms wrapping a lone
  # button and the shell's own log out.
  def edit_forms(body)
    forms(body).select do |one|
      one.include?(%(method="post")) && one.match?(/<(?:input(?! type="hidden")|select|textarea)\b/)
    end
  end

  def buttons(html) = html.scan(/<(?:button|a)\b[^>]*class="rb-button[^"]*"/)

  def primaries(html) = buttons(html).grep(/rb-button--primary/)

  def footer(html) = html[%r{<div class="rb-form-actions">.*?</div>\s*</div>}m].to_s

  # What is left of a form once the last submit row starts: anything that is a
  # control means the footer was not last after all.
  def after_footer(html)
    at = html.rindex(%(<div class="rb-form-submit">))
    at.nil? ? html : html[at..]
  end

  def trailing_control?(html)
    tail = after_footer(html).sub(%r{\A<div class="rb-form-submit">.*?</div>}m, "")
    tail.match?(/<(?:input(?! type="hidden")|select|textarea)\b/) || tail.include?("rb-button")
  end

  EDITORS.each do |name, path|
    context name do
      let(:body) { body_of(path) }

      it "draws at least one edit form, so nothing below passes vacuously" do
        expect(edit_forms(body).length).to be_positive
      end

      it "ends every edit form on its submit row, with no control after it" do
        stray = edit_forms(body).reject { |one| one.include?("rb-form-submit") && !trailing_control?(one) }

        expect(stray).to be_empty, lambda {
          "#{stray.length} form(s) do not end on the action footer:\n#{stray.join("\n\n")}"
        }
      end

      it "offers exactly one primary action per edit form, after any subordinate one" do
        wrong = edit_forms(body).reject do |one|
          last_secondary = one.rindex("rb-button--secondary") || -1
          primaries(one).length == 1 && one.rindex("rb-button--primary") > last_secondary
        end

        expect(wrong).to be_empty, lambda {
          "#{wrong.length} form(s) do not end on exactly one primary action:\n#{wrong.join("\n\n")}"
        }
      end

      it "says what pressing it does beside the control, rather than in paragraphs above it" do
        silent = edit_forms(body).reject { |one| footer(one).include?("rb-notice") }

        expect(silent).to be_empty, lambda {
          "#{silent.length} form(s) carry no validation in their footer:\n#{silent.join("\n\n")}"
        }
      end

      it "keeps every destructive control out of an edit form" do
        armed = edit_forms(body).select { |one| one.include?(%(data-destructive="true")) }

        expect(armed).to be_empty, lambda {
          "#{armed.length} edit form(s) put a destructive control beside the submit:\n#{armed.join("\n\n")}"
        }
      end
    end
  end

  # The two editors that only exist once a record does, held to the same rule
  # as the blank ones next door.
  it "holds a saved record's editor to the same footer as a blank one" do
    { "endpoints" => -> { endpoint_id }, "scripts" => -> { script_id } }.each do |section, id|
      path = "/communities/sample/#{section}/#{id.call}"
      found = edit_forms(body_of(path))

      expect(found.length).to be_positive, "#{path} drew no edit form"
      found.each do |one|
        expect(primaries(one).length).to eq(1), "#{path} drew #{primaries(one).length} primary controls in one form"
        expect(footer(one)).to include("rb-notice"), "#{path} drew a form with no validation beside its submit"
        expect(one).not_to include(%(data-destructive="true"))
      end
    end
  end

  # The destructive control the connections editor does draw, which is what
  # makes the rule above a move rather than an absence.
  it "draws a destructive control as its own action Form, apart from any edit form" do
    body = body_of("/communities/sample/platforms")
    destructive = forms(body).select { |one| one.include?(%(data-destructive="true")) }

    expect(destructive).not_to be_empty, "the connections editor drew no destructive control at all"
    expect(destructive).to all(include("rb-form--action"))
    expect(destructive).to all(satisfy { |one| !one.match?(/<(?:select|textarea)\b/) })
  end
end
