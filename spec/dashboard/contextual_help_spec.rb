# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# Where help sits: what a control does, what it risks and what
# permission it spends belongs beside that control. Background, the
# alpha policy and reference prose fold into one disclosure instead of
# four screens of prose above the first control.
RSpec.describe "the dashboard's contextual help", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  # The screens the issue names, and the words the disclosure on each has to
  # have taken off the page above it.
  HELP_SCREENS = {
    "/communities/sample/scripts" => "About scripts",
    "/communities/sample/scripts/new" => "About scripts",
    "/communities/sample/features" => "About scopes and defaults",
    "/communities/sample/endpoints/new" => "How a script calls this"
  }.freeze

  before { post("/login", secret: secret) }

  def body_of(path)
    get path
    raise "#{path} answered #{last_response.status}" unless last_response.status == 200

    last_response.body
  end

  def disclosures(body) = body.scan(%r{<details class="rb-section rb-section--collapsible"[^>]*>.*?</details>}m)

  def summary_of(html) = html[%r{<summary class="rb-section-title">(.*?)</summary>}m, 1].to_s

  # The page with every disclosure taken out: what a reader meets before
  # opening anything.
  def outside(body) = disclosures(body).reduce(body) { |left, one| left.sub(one, "") }

  HELP_SCREENS.each do |path, title|
    context path do
      let(:body) { body_of(path) }

      it "draws one Help disclosure, titled and collapsible" do
        titled = disclosures(body).select { |one| summary_of(one) == title }

        expect(titled.length).to eq(1), "expected one #{title.inspect} disclosure, found #{titled.length}"
      end

      it "leaves it shut, so the controls are what the page opens on" do
        titled = disclosures(body).find { |one| summary_of(one) == title }

        expect(titled).not_to match(/<details[^>]*\bopen\b/)
      end

      it "keeps the background prose inside it rather than above the first control" do
        titled = disclosures(body).find { |one| summary_of(one) == title }

        expect(titled.length).to be > 200, "the disclosure holds no prose worth folding away"
        expect(outside(body)).not_to include("Do not build anything you would be upset to rewrite")
      end
    end
  end

  it "links the documentation from the disclosure on every screen that has a reference" do
    %w[/communities/sample/scripts /communities/sample/scripts/new /communities/sample/endpoints/new].each do |path|
      help = disclosures(body_of(path)).find { |one| summary_of(one).start_with?("About", "How") }

      expect(help).to match(%r{<a href="[^"]*/documentation"[^>]*class="rb-button}),
                      "#{path} folds the reference prose away without linking the reference"
    end
  end

  # The half that has to stay put: a consequence a reader needs while pressing
  # a control is no use folded shut behind a summary.
  it "keeps what a script does to real traffic beside the controls, outside any disclosure" do
    %w[/communities/sample/scripts /communities/sample/scripts/new].each do |path|
      body = body_of(path)

      expect(outside(body)).to include("runs on real messages"), "#{path} folded the risk away"
      expect(outside(body)).to match(/rb-notice--warning/)
    end
  end

  it "keeps the scope rule beside the scope picker rather than inside the disclosure" do
    body = body_of("/communities/sample/features")

    expect(outside(body)).to include("community-wide default every room inherits")
  end

  it "keeps the brace rule beside the URL field rather than inside the disclosure" do
    body = body_of("/communities/sample/endpoints/new")

    expect(outside(body)).to include("{braces}")
  end

  it "draws no worked example between the endpoint editor's heading and its fields" do
    body = body_of("/communities/sample/endpoints/new")

    expect(body).not_to include(%(class="worked-example"))
    expect(body).not_to include("rubotty.async_http({")
  end
end
