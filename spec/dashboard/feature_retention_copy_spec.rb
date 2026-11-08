# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# What a feature KEEPS has to be visible where an operator turns it on. Enabling
# redirection for a room makes rubotty hold that room's last messages so a run can
# be reposted. The numbers in the copy are read off RedirectionWindow's own
# constants, so this fails if the retention changes and the page does not.
module FeatureRetentionCopySupport
end

RSpec.describe "Rubotty::Dashboard::App feature retention copy", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  let(:days) { Rubotty::ControlPlane::RedirectionWindow::TTL_SECONDS / 86_400 }

  # A feature's own row is its own collapsible Section: data-chevron="end"
  # tells one apart from the "About scopes and defaults" disclosure above the
  # list, which draws chevron-first (the default) instead.
  FeatureRetentionCopySupport::FEATURE_ROW_OPEN = '<details class="rb-section rb-section--collapsible" data-chevron="end">'

  def feature_row(body, feature)
    body.split(/(?=#{Regexp.escape(FeatureRetentionCopySupport::FEATURE_ROW_OPEN)})/)
        .select { |chunk| chunk.start_with?(FeatureRetentionCopySupport::FEATURE_ROW_OPEN) }
        .find { |row| row.include?(%(data-feature="#{feature}">)) }
  end

  def redirection_row(body) = feature_row(body, "redirection")

  before { post "/login", secret: secret }

  describe "the Features page, where a room's toggle actually lives" do
    it "says what enabling redirection makes rubotty keep, in the row with its own toggle" do
      get "/communities/sample/features", scope: "general"
      row = redirection_row(last_response.body)

      expect(row).to include("What this keeps")
      expect(row).to include("messages for #{days} days")
      expect(row).to include(%(value="enable"))
    end

    it "says that switching it off stops the keeping" do
      get "/communities/sample/features", scope: "general"

      expect(redirection_row(last_response.body)).to include("Switching the feature off stops the keeping")
    end

    it "still says it once the feature is on, so the disclosure is not only a sales pitch" do
      post "/communities/sample/features", selector: "general", feature: "redirection", op: "enable"

      get "/communities/sample/features", scope: "general"
      expect(redirection_row(last_response.body)).to include("messages for #{days} days")
    end

    # Every other feature reads a message and forgets it, and the page must not
    # imply otherwise by putting the same line everywhere.
    it "says nothing of the sort for a feature that keeps nothing" do
      get "/communities/sample/features", scope: "general"

      expect(feature_row(last_response.body, "word_filter")).not_to include("What this keeps")
    end
  end

  describe "the redirection config page" do
    it "carries the same disclosure, so an operator arriving there sees it too" do
      get "/communities/sample/features/redirection/config", scope: "general"

      expect(last_response.body).to include("What this keeps")
      expect(last_response.body).to include("messages for #{days} days")
    end
  end
end
