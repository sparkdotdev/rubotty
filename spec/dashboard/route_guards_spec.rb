# frozen_string_literal: true

require "spec_helper"
require "prism"

# Reads the parse tree rather than the text, because comment prose mentioning a
# guard satisfies a grep and does not satisfy a route.
RSpec.describe "Rubotty::Dashboard::App route guards" do
  ROUTE_SOURCE = File.expand_path("../../lib/rubotty/dashboard/app.rb", __dir__)
  ROUTE_VERBS = %i[get post put patch delete].freeze
  MUTATING_VERBS = %i[post put patch delete].freeze
  ROUTE_GUARDS = %i[require_admin! authorize!].freeze

  # Routes that are deliberately reachable without a guard, each for a reason
  # that would not survive being forgotten.
  UNGUARDED_ROUTES = {
    "/login" => "issues the session, so it cannot require one",
    "/logout" => "clears the session and nothing else",
    "/operator-login" => "issues the session from a token, so it cannot require one either",
    "/communities/:slug/request-access" => "guards on current_role.operator? directly"
  }.freeze

  # Every route in the file as {verb:, path:, line:, guarded:}.
  def routes
    body = Prism.parse_file(ROUTE_SOURCE).value
    calls(body).filter_map do |node|
      next unless ROUTE_VERBS.include?(node.name)

      path = node.arguments&.arguments&.first
      next unless path.is_a?(Prism::StringNode) && node.block

      {
        verb: node.name,
        path: path.unescaped,
        line: node.location.start_line,
        guarded: calls(node.block).any? { |inner| ROUTE_GUARDS.include?(inner.name) }
      }
    end
  end

  # Every call node at or below +node+, in source order.
  def calls(node)
    return [] if node.nil?

    found = node.is_a?(Prism::CallNode) ? [node] : []
    node.compact_child_nodes.each { |child| found.concat(calls(child)) }
    found
  end

  let(:table) { routes }

  it "finds the whole route table" do
    expect(table.length).to be > 80
  end

  it "reaches an authorization call on every mutating route" do
    offenders = table.select { |route| MUTATING_VERBS.include?(route[:verb]) }
                     .reject { |route| route[:guarded] || UNGUARDED_ROUTES.key?(route[:path]) }
                     .map { |route| "app.rb:#{route[:line]} #{route[:verb].upcase} #{route[:path]}" }

    expect(offenders).to be_empty, "mutating routes with no authorization call:\n#{offenders.join("\n")}"
  end

  it "reaches an authorization call on every community-scoped read" do
    offenders = table.select { |route| route[:verb] == :get && route[:path].start_with?("/communities/:slug") }
                     .reject { |route| route[:guarded] }
                     .map { |route| "app.rb:#{route[:line]} GET #{route[:path]}" }

    expect(offenders).to be_empty, "community reads with no authorization call:\n#{offenders.join("\n")}"
  end

  it "keeps the unguarded list honest, so a route cannot be excused after it is deleted" do
    paths = table.map { |route| route[:path] }

    expect(UNGUARDED_ROUTES.keys - paths).to be_empty
  end

  it "removes an operator behind a guard" do
    route = table.find { |r| r[:path] == "/communities/:slug/operators/:id/delete" && r[:verb] == :post }

    expect(route[:guarded]).to be(true)
  end
end
