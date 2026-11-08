# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"

# Anything a developer key can never reach lives under /admin/, so the privilege
# boundary is visible in the URL. Nothing fails when the rule is broken, since
# authorization still holds, so it is asserted here.
RSpec.describe "Rubotty::Api::App's admin path rule" do
  # Route bodies as source, since the gate is a call inside the block that the
  # route table never records.
  def route_blocks
    source = File.read(File.expand_path("../../lib/rubotty/api/app.rb", __dir__))
    source.scan(/^      (get|post|patch|put|delete) "([^"]+)" do\n(.*?)\n      end$/m)
  end

  it "finds the routes at all, so a rewrite cannot quietly empty this" do
    expect(route_blocks.length).to be > 40
  end

  it "puts every admin only route under /admin/" do
    stray = route_blocks.filter_map do |verb, path, body|
      "#{verb.upcase} #{path}" if body.include?("require_admin!") && !path.start_with?("/admin/")
    end

    expect(stray).to be_empty
  end

  # The other way round, so the prefix means one thing and is worth reading.
  it "gates every route under /admin/" do
    ungated = route_blocks.filter_map do |verb, path, body|
      "#{verb.upcase} #{path}" if path.start_with?("/admin/") && !body.include?("require_admin!")
    end

    expect(ungated).to be_empty
  end
end
