# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"

# The screen manifest, checked against the route table both ways: a
# page the app serves and the manifest does not name fails, and so
# does a manifest entry no route serves. This is what stops a new
# screen from appearing quietly, with no claim that it is a good one.
RSpec.describe "the dashboard screen manifest" do
  SCREEN_VIEWS_DIR = File.expand_path("../../lib/rubotty/dashboard/views", __dir__)

  # Every page: its route, the title it carries, the view files that draw it
  # today, and the primitives it is meant to compose from once ported.
  SCREENS = {
    "GET /" =>
      { title: "Communities", views: %w[index.erb],
        primitives: %i[page section table notice button] },
    "GET /accounts" =>
      { title: "Accounts", views: %w[accounts.erb],
        primitives: %i[page section table form field button notice] },
    "GET /administrators" =>
      { title: "Administrators", views: %w[administrators.erb],
        primitives: %i[page section table form field button state notice] },
    "GET /analytics" =>
      { title: "Analytics", views: %w[analytics_overview.erb],
        primitives: %i[page section table tab_links notice] },
    "GET /api-keys" =>
      { title: "API keys", views: %w[api_keys.erb],
        primitives: %i[page section table form field button notice code] },
    "GET /audit" =>
      { title: "Audit log", views: %w[audit.erb],
        primitives: %i[page section form field table notice] },
    "GET /backfill-proposals" =>
      { title: "Backfill proposals", views: %w[backfill_proposals.erb],
        primitives: %i[page section stat_row table button notice] },
    "GET /jobs" =>
      { title: "Jobs", views: %w[jobs.erb],
        primitives: %i[page section form field table notice button] },
    "GET /logs" =>
      { title: "Logs", views: %w[logs.erb],
        primitives: %i[page section form field table notice button] },
    "GET /communities/{slug}" =>
      { title: "Overview", views: %w[community.erb request_access.erb],
        primitives: %i[page section stat_row state button notice] },
    "GET /communities/{slug}/alerts" =>
      { title: "Alerts", views: %w[alerts.erb],
        primitives: %i[page section table state button notice] },
    "GET /communities/{slug}/analytics" =>
      { title: "Analytics", views: %w[analytics.erb],
        primitives: %i[page section tab_links stat_row chart notice] },
    "GET /communities/{slug}/audit" =>
      { title: "Audit log", views: %w[audit.erb],
        primitives: %i[page section form field table notice] },
    "GET /communities/{slug}/endpoints" =>
      { title: "Script endpoints", views: %w[endpoints.erb],
        primitives: %i[page section table state button notice] },
    "GET /communities/{slug}/endpoints/new" =>
      { title: "New endpoint", views: %w[endpoint_edit.erb],
        primitives: %i[page section form field button code notice] },
    "GET /communities/{slug}/endpoints/{id}" =>
      { title: "Endpoint", views: %w[endpoint_edit.erb],
        primitives: %i[page section form field button code notice] },
    "GET /communities/{slug}/events" =>
      { title: "Scheduled", views: %w[events.erb],
        primitives: %i[page section table form field button state notice] },
    "GET /communities/{slug}/faq" =>
      { title: "FAQ", views: %w[faq.erb],
        primitives: %i[page section table form field button state notice] },
    "GET /communities/{slug}/features" =>
      { title: "Features", views: %w[features.erb],
        primitives: %i[page section state button form field notice] },
    "GET /communities/{slug}/features/{feature}/config" =>
      { title: "Feature config", views: %w[feature_config.erb],
        primitives: %i[page section form field button notice] },
    "GET /communities/{slug}/files" =>
      { title: "Files", views: %w[files.erb],
        primitives: %i[page section table button notice] },
    "GET /communities/{slug}/guests" =>
      { title: "Guest portal", views: %w[guests.erb],
        primitives: %i[page section table form field button state notice code] },
    "GET /communities/{slug}/content-policy/misfires" =>
      { title: "Policy misfires", views: %w[content_policy_misfires.erb],
        primitives: %i[page section table button notice] },
    "GET /communities/{slug}/moderation" =>
      { title: "Moderation", views: %w[moderation.erb],
        primitives: %i[page section form field table button state notice] },
    "GET /communities/{slug}/operators" =>
      { title: "Operators", views: %w[operators.erb],
        primitives: %i[page section table form field button state notice] },
    "GET /communities/{slug}/participation" =>
      { title: "Room games", views: %w[participation.erb],
        primitives: %i[page section table button notice] },
    "GET /communities/{slug}/people" =>
      { title: "People", views: %w[people.erb],
        primitives: %i[page section form field table tag notice] },
    "GET /communities/{slug}/platforms" =>
      { title: "Connections", views: %w[platforms.erb],
        primitives: %i[page section table form field button state key_values notice] },
    "GET /communities/{slug}/polls" =>
      { title: "Polls", views: %w[polls.erb],
        primitives: %i[page section table button tag notice] },
    "GET /communities/{slug}/redirections" =>
      { title: "Redirections", views: %w[redirections.erb],
        primitives: %i[page section table button notice] },
    "GET /communities/{slug}/rooms" =>
      { title: "Rooms", views: %w[rooms.erb],
        primitives: %i[page section table form field button notice] },
    "GET /communities/{slug}/rooms/channels/{id}" =>
      { title: "Channel", views: %w[room_channel.erb],
        primitives: %i[page section key_values form field table button notice] },
    "GET /communities/{slug}/rooms/automatic-mapping" =>
      { title: "Automatic mapping", views: %w[automatic_mapping.erb],
        primitives: %i[page section form field table button notice] },
    "GET /communities/{slug}/rooms/{room_key}" =>
      { title: "Room", views: %w[room_detail.erb],
        primitives: %i[page section key_values form field table button notice] },
    "GET /communities/{slug}/scripts" =>
      { title: "Scripts", views: %w[scripts.erb],
        primitives: %i[page section table button notice] },
    "GET /communities/{slug}/scripts/new" =>
      { title: "New script", views: %w[script_edit.erb],
        primitives: %i[page section form field button code notice] },
    "GET /communities/{slug}/scripts/{id}" =>
      { title: "Script", views: %w[script_edit.erb],
        primitives: %i[page section form field button code state notice] },
    "GET /communities/{slug}/webhooks" =>
      { title: "Webhooks", views: %w[webhooks.erb],
        primitives: %i[page section table button notice] },
    "GET /communities/{slug}/word-filter" =>
      { title: "Word filter", views: %w[word_filter.erb],
        primitives: %i[page section table form field button state notice] },
    "GET /documentation" =>
      { title: "Documentation", views: %w[documentation.erb],
        primitives: %i[page section prose notice] },
    "GET /integrations" =>
      { title: "Integrations", views: %w[integrations.erb],
        primitives: %i[page section form field button state notice] },
    "GET /licence" =>
      { title: "Licence", views: %w[licence.erb],
        primitives: %i[page section prose notice] },
    "GET /login" =>
      { title: "Sign in", views: %w[login.erb],
        primitives: %i[page section form field button notice] },
    "GET /onboarding" =>
      { title: "Onboarding", views: %w[onboarding.erb],
        primitives: %i[page section table form field button tag key_values notice] },
    "GET /operator-login" =>
      { title: "Sign in", views: %w[operator_login.erb],
        primitives: %i[page section form button notice] },
    "GET /operator-tokens" =>
      { title: "Operator login links", views: %w[operator_tokens.erb],
        primitives: %i[page section table button notice] },
    "GET /settings/datastore" =>
      { title: "Datastore", views: %w[datastore_settings.erb],
        primitives: %i[page section form field button notice] },
    "GET /viewers" =>
      { title: "Viewers", views: %w[viewers.erb],
        primitives: %i[page section table form field button state notice] }
  }.freeze

  # A GET route that is not a page, with why it draws nothing.
  SCREENS_NOT_A_PAGE = {
    "GET /healthz" => "answers plain text for a load balancer and renders no view",
    "GET /communities/{slug}/discovered" => "redirects legacy bookmarks to Rooms filtered to unroomed channels",
    "GET /internal/shell" =>
      "the navigation catalogue a theme draws its own chrome from, which is not a page",
    "GET /internal/communities" =>
      "the internal YAML surface a themed section is drawn from, which renders no view of its own",
    "GET /internal/communities/{slug}" => "the same surface, one community",
    "GET /internal/communities/{slug}/rooms" => "the same surface, one community's rooms",
    "GET /internal/communities/{slug}/rooms/channels/{id}" =>
      "the same surface, one channel's Rooms details",
    "GET /internal/communities/{slug}/rooms/automatic-mapping" =>
      "the same surface, one Rooms mapping confirmation",
    "GET /internal/communities/{slug}/rooms/{room_key}" =>
      "the same surface, one room's Rooms details",
    "GET /internal/communities/{slug}/endpoints" => "the same surface, one community's endpoints",
    "GET /internal/communities/{slug}/endpoints/new" => "the same surface, a blank endpoint editor",
    "GET /internal/communities/{slug}/endpoints/{id}" => "the same surface, one endpoint's editor",
    "GET /internal/audit" => "the same surface, the deployment audit history",
    "GET /internal/communities/{slug}/audit" => "the same surface, one community's audit history",
    "GET /internal/communities/{slug}/redirections" => "the same surface, one community's redirections",
    "GET /internal/communities/{slug}/webhooks" => "the same surface, one community's webhooks",
    "GET /internal/communities/{slug}/scripts" => "the same surface, one community's scripts",
    "GET /internal/communities/{slug}/scripts/new" => "the same surface, a blank script editor",
    "GET /internal/communities/{slug}/scripts/{id}" => "the same surface, one script's authoring flow",
    "GET /internal/communities/{slug}/features" => "the same surface, one community's features",
    "GET /internal/communities/{slug}/features/{feature}/config" => "the same surface, one feature's config",
    "GET /internal/onboarding" => "the same surface, the deployment-wide onboarding queue",
    "GET /internal/operator-tokens" => "the same surface, the deployment-wide login links",
    "GET /internal/administrators" => "the same surface, the deployment-wide administrator roster",
    "GET /internal/analytics" => "the same surface, the deployment-wide activity totals",
    "GET /internal/api-keys" => "the same surface, the deployment-wide API key list",
    "GET /internal/viewers" => "the same surface, the deployment-wide viewer roster",
    "GET /internal/accounts" => "the same surface, the deployment-wide gateway account roster",
    "GET /internal/integrations" => "the same surface, the deployment-wide integration list",
    "GET /internal/communities/{slug}/participation" => "the same surface, one community's room games",
    "GET /internal/communities/{slug}/alerts" => "the same surface, one community's alerts",
    "GET /internal/communities/{slug}/files" => "the same surface, one community's files",
    "GET /internal/communities/{slug}/people" => "the same surface, one community's people",
    "GET /internal/communities/{slug}/moderation" => "the same surface, one community's moderation",
    "GET /internal/communities/{slug}/events" => "the same surface, one community's events",
    "GET /internal/communities/{slug}/word-filter" => "the same surface, one community's word filter",
    "GET /internal/communities/{slug}/faq" => "the same surface, one community's FAQ",
    "GET /internal/communities/{slug}/platforms" => "the same surface, one community's connections",
    "GET /internal/communities/{slug}/operators" => "the same surface, one community's operators and viewers",
    "GET /internal/communities/{slug}/analytics" => "the same surface, one community's activity report",
    "GET /internal/communities/{slug}/polls" => "the same surface, one community's open polls",
    "GET /internal/communities/{slug}/guests" => "the same surface, one community's guest portal",
    "GET /internal/settings/datastore" => "the same surface, the datastore snapshot controls",
    "GET /internal/backfill-proposals" => "the same surface, every pending, awaiting-relay and expired proposal",
    "GET /internal/logs" => "the same surface, each process's recent lines",
    "GET /internal/documentation" => "the same surface, the scripting reference as rendered markup",
    "GET /internal/licence" => "the same surface, the licence as rendered markup",
    "GET /search.json" => "the command bar's JSON lookup, which renders no view",
    "GET /settings/datastore/export" => "streams the snapshot as a gzip download, which renders no view"
  }.freeze

  # A view file no GET route names, with why it exists anyway.
  SCREENS_OFF_ROUTE = {
    "layout.erb" => "the page shell, which every screen renders inside",
    "_config_fields.erb" => "the generic schema form, included by other views",
    "_config_input.erb" => "one scalar control, included by _config_fields.erb and mapping-list rows",
    "_config_mapping_list.erb" => "a mapping-list field's rows, included by _config_fields.erb",
    "_config_mapping_row.erb" => "one mapping-list row, included by _config_mapping_list.erb",
    "_feature_row.erb" => "one Features row's collapsed body, included once per feature",
    "_leftover_config.erb" => "the same form embedded under a bespoke page",
    "not_found.erb" => "the 404 body, halted into from any route",
    "forbidden.erb" => "the 403 body, halted into from any route"
  }.freeze

  # Sinatra keeps the compiled patterns, so this reads what the app will really
  # serve, with ":slug" written the way the manifest writes it.
  def app_screens
    Rubotty::Dashboard::App.routes.fetch("GET").map do |pattern|
      "GET #{pattern[0].to_s.gsub(/:(\w+)/, '{\1}')}"
    end.sort
  end

  def declared = (SCREENS.keys + SCREENS_NOT_A_PAGE.keys).sort

  def view_files = Dir.children(SCREEN_VIEWS_DIR).select { |name| name.end_with?(".erb") }.sort

  it "names every page the app serves" do
    missing = app_screens - declared

    expect(missing).to be_empty, lambda {
      "#{missing.length} GET route(s) the app serves are absent from SCREENS:\n  #{missing.join("\n  ")}"
    }
  end

  it "serves every page the manifest names" do
    invented = declared - app_screens

    expect(invented).to be_empty, lambda {
      "#{invented.length} manifest entr(ies) name a route the app does not serve:\n  #{invented.join("\n  ")}"
    }
  end

  # Both sets going empty would make the two above pass while proving nothing.
  it "reads a real route table on both sides" do
    expect(app_screens.length).to be > 30
    expect(declared.length).to eq(app_screens.length)
  end

  it "names a view file that exists for every screen" do
    absent = SCREENS.flat_map { |route, screen| screen[:views].map { |view| [route, view] } }
                    .reject { |_, view| view_files.include?(view) }

    expect(absent).to be_empty, lambda {
      "screens naming a view that is not there:\n  #{absent.map { |r, v| "#{r} -> #{v}" }.join("\n  ")}"
    }
  end

  it "accounts for every view file, on a route or with a reason" do
    on_route = SCREENS.values.flat_map { |screen| screen[:views] }.uniq
    stray = view_files - on_route - SCREENS_OFF_ROUTE.keys

    expect(stray).to be_empty, lambda {
      "#{stray.length} view file(s) belong to no screen and have no stated reason:\n  #{stray.join("\n  ")}"
    }
  end

  it "keeps the off-route list to views that exist" do
    expect(SCREENS_OFF_ROUTE.keys - view_files).to be_empty
  end

  it "composes every screen out of the fifteen and nothing else" do
    known = Rubotty::Dashboard::Primitives::NAMES.values
    outside = SCREENS.filter_map do |route, screen|
      unknown = screen[:primitives] - known
      "#{route}: #{unknown.join(", ")}" unless unknown.empty?
    end

    expect(outside).to be_empty, lambda {
      "screens declaring something outside the primitive set:\n  #{outside.join("\n  ")}"
    }
  end

  it "gives every screen a title" do
    untitled = SCREENS.reject { |_, screen| screen[:title].to_s.length.positive? }.keys

    expect(untitled).to be_empty, "screens with no title: #{untitled.join(", ")}"
  end
end
