# frozen_string_literal: true

require "spec_helper"
require "rubotty/web/server"
require "rubotty/dashboard/server"
require "rubotty/guest_portal/server"
require "rubotty/api/server"
require "rubotty/core/health_server"

# The port `rubotty web` lands on decides whether the proxy in front of it gets
# anything. It used to fall back to 9494, which no proxy probes, so a host that did
# not set PORT came up on the wrong port with no error anywhere.
RSpec.describe Rubotty::Web::Server do
  it "falls back to the port a deployment assumes" do
    expect(described_class::DEFAULT_PORT).to eq(3000)
  end

  # The resolution `Rubotty::CLI` performs, written out because standing the whole
  # web app up needs a datastore and every surface assembled.
  def resolve(env) = (env["PORT"] || described_class::DEFAULT_PORT).to_i

  it "lets PORT win, since that is what the platform sets" do
    expect(resolve("PORT" => "8080")).to eq(8080)
  end

  it "uses the fallback when nothing is set" do
    expect(resolve({})).to eq(3000)
  end

  # The two run side by side in the same deployment, so a shared default would mean
  # one of them silently failing to bind on a host that set neither.
  it "does not collide with the bot's health server" do
    expect(described_class::DEFAULT_PORT).not_to eq(Rubotty::Core::HealthServer::DEFAULT_PORT)
  end

  # The single-surface commands are development conveniences, where two running at
  # once is the likely case, so they keep their own numbers.
  it "leaves the single-surface development defaults alone" do
    expect(Rubotty::Dashboard::Server::DEFAULT_PORT).to eq(9292)
    expect(Rubotty::GuestPortal::Server::DEFAULT_PORT).to eq(9393)
  end

  # The guest portal and the API both declared 9393 for a while, so whichever command
  # started second could not bind, and nothing anywhere said the numbers had to differ.
  describe "every surface's default port" do
    SURFACES = {
      "web" => Rubotty::Web::Server,
      "dashboard" => Rubotty::Dashboard::Server,
      "guest portal" => Rubotty::GuestPortal::Server,
      "api" => Rubotty::Api::Server,
      "the bot's health server" => Rubotty::Core::HealthServer
    }.freeze

    it "is unique across every surface that binds one" do
      taken = SURFACES.group_by { |_name, mod| mod::DEFAULT_PORT }
                      .select { |_port, entries| entries.length > 1 }

      expect(taken).to be_empty,
                       "these surfaces share a default port: " \
                       "#{taken.map { |port, e| "#{port} (#{e.map(&:first).join(", ")})" }.join("; ")}"
    end
  end
end
