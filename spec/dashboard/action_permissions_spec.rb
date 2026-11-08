# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rubotty/dashboard/action_permissions"
require "rubotty/dashboard/role"
require "rack/test"

# The database-backed half of the per-setting operator/admin-only toggle, which is
# what lets an administrator move a setting between the two without a deploy.
# {Rubotty::Dashboard::Role} still holds the allow list, and the Sinatra wiring is
# covered in authorization_spec.rb and app_spec.rb.
RSpec.describe Rubotty::Dashboard::ActionPermissions, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  subject(:permissions) { described_class.new(models: models) }

  # Every grant an administrator can hand out. The per-feature pairs are generated
  # from the catalog rather than listed out.
  describe "the grants on offer" do
    it "offers two grants for every feature, turning it on and editing it" do
      Rubotty::Features::Catalog.names.each do |feature|
        expect(described_class::ACTIONS).to have_key(:"toggle_#{feature}"), "no toggle grant for #{feature}"
        expect(described_class::ACTIONS).to have_key(:"configure_#{feature}"), "no config grant for #{feature}"
      end
    end

    it "offers the whole section grants too" do
      expect(described_class::ACTIONS.keys).to include(:manage_rooms, :manage_discovered, :moderate_user)
    end

    it "labels every one of them, since this list is a page somebody reads" do
      expect(described_class::ACTIONS.values).to all(satisfy { |label| !label.to_s.strip.empty? })
    end

    it "splits features from sections, so the page can list them apart" do
      grouped = permissions.grouped_rows

      expect(grouped.keys).to contain_exactly("Features", "Sections")
      expect(grouped["Sections"].map { |row| row[:action] }).to include(:moderate_user)
    end
  end

  describe "with no stored rows (a database that has never been touched)" do
    # Every grant is a deliberate act, so an operator arrives able to do nothing.
    it "grants nothing at all" do
      expect(permissions.operator_write_actions).to be_empty
    end

    it "reports every known action as denied" do
      expect(permissions.rows.map { |row| row[:operator_writable] }).to all(be(false))
    end
  end

  describe "#update" do
    it "turns on exactly what was ticked, and nothing else" do
      permissions.update({ "configure_faq" => "1" })

      expect(permissions.operator_write_actions).to eq([:configure_faq])
      expect(db[:dashboard_action_permissions].where(action: "configure_word_filter").first[:operator_writable])
        .to be(false)
    end

    it "keeps turning a feature on separate from editing what it does" do
      permissions.update({ "toggle_word_filter" => "1" })

      expect(permissions.operator_write_actions).to eq([:toggle_word_filter])
    end

    it "persists across a fresh instance, the live-without-a-deploy point of the feature" do
      permissions.update({ "configure_events" => "1" })

      reloaded = described_class.new(models: models)
      expect(reloaded.operator_write_actions).to eq([:configure_events])
    end

    it "updates an existing row instead of erroring on a second save" do
      permissions.update({ "configure_faq" => "1" })
      permissions.update({ "configure_faq" => "1", "moderate_user" => "1" })

      expect(permissions.operator_write_actions).to contain_exactly(:configure_faq, :moderate_user)
      expect(db[:dashboard_action_permissions].where(action: "configure_faq").count).to eq(1)
    end

    it "ignores a key that is not a grant it knows" do
      permissions.update({ "delete_everything" => "1" })

      expect(db[:dashboard_action_permissions].where(action: "delete_everything").count).to eq(0)
      expect(permissions.operator_write_actions).to eq([])
    end
  end
end

# The page an administrator hands grants out on.
RSpec.describe "the operator permissions page", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret }) }

  before { post "/login", secret: secret }

  it "offers both grants for a feature, separately" do
    get "/communities/sample/operators"

    expect(last_response.body).to include("permissions[toggle_word_filter]")
    expect(last_response.body).to include("permissions[configure_word_filter]")
  end

  it "shows the whole section grants under their own heading" do
    get "/communities/sample/operators"

    expect(last_response.body).to include("Sections").and include("permissions[manage_rooms]")
  end

  it "starts with every box unticked, since nothing is granted by default" do
    get "/communities/sample/operators"

    expect(last_response.body).not_to include("value=\"1\" checked")
  end

  it "says what the two halves of a feature grant mean" do
    get "/communities/sample/operators"

    expect(last_response.body).to include("reading as on while it catches nothing")
  end

  # The themed matrix draws each grant as its own one-entry checklist, so a
  # ticked box arrives as permissions[<action>][] rather than a flat pair. The
  # route decides on the key being there at all, and both shapes have to mean
  # the same thing to it.
  it "honours the nested shape the themed grant matrix submits" do
    post "/operator-permissions",
         permissions: { "moderate_user" => ["1"] }, back: "/communities/sample/operators"

    expect(deps.action_permissions.operator_write_actions).to eq([:moderate_user])
  end

  it "reads an unticked grant as denied, since an unticked box submits nothing at all" do
    post "/operator-permissions",
         permissions: { "moderate_user" => ["1"] }, back: "/communities/sample/operators"
    post "/operator-permissions", permissions: {}, back: "/communities/sample/operators"

    expect(deps.action_permissions.operator_write_actions).to be_empty
  end
end

# The page offers a checkbox per grant, and a grant no route consults reads as a
# decision that was made when nothing was.
RSpec.describe Rubotty::Dashboard::ActionPermissions, "every grant reaches a route", :control_plane do
  # The dashboard's own source, since the question is whether any route or view
  # asks about the grant at all.
  def source
    @source ||= Dir[File.expand_path("../../lib/rubotty/dashboard/**/*.{rb,erb}", __dir__)]
                .reject { |path| path.end_with?("action_permissions.rb") }
                .map { |path| File.read(path) }.join("\n")
  end

  described_class::SECTION_ACTIONS.each_key do |action|
    it "consults #{action} somewhere" do
      expect(source).to include(":#{action}")
    end
  end

  # The feature grants are consulted through interpolation rather than by
  # name, so they are checked as a pair against the generic routes instead.
  it "consults the feature grants through the routes that toggle and configure" do
    expect(source).to include(':"toggle_#{')
    expect(source).to include(':"configure_#{')
  end
end
