# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The Logs page: each process's own recent lines, read without a shell on the
# box. Administrator only, since a log line carries whatever the code that
# wrote it put there and belongs to no one community.
RSpec.describe "Rubotty::Dashboard::App logs", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:buffer) { Rubotty::RingBuffer.new }
  let(:reader) { Rubotty::Dashboard::DebugLogs.new(log_buffer: buffer) }
  let(:deps) do
    Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, debug_logs: reader)
  end

  def login!
    post "/login", secret: secret
  end

  def log!(level, text, at: Time.utc(2026, 7, 1, 12, 0))
    buffer << "#{at.iso8601} #{level.upcase.ljust(5)} #{text}\n"
  end

  describe "unauthenticated" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    it "gates the page behind a session" do
      get "/logs"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end
  end

  describe "an administrator session" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { login! }

    it "shows this process's own recent lines" do
      log!("warn", "topic routing: skipped 42")
      get "/logs"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("topic routing: skipped 42")
    end

    it "filters to a level and anything more severe, leaving quieter lines out" do
      log!("debug", "a line nobody needs")
      log!("error", "a line somebody does")
      get "/logs", level: "warn"

      expect(last_response.body).to include("a line somebody does")
      expect(last_response.body).not_to include("a line nobody needs")
    end

    it "says so plainly when nothing matches" do
      get "/logs"

      expect(last_response.body).to include("No log lines with these filters.")
    end

    # An unreachable bot has to read as unreachable. Reported as nothing to say
    # would be a silence the reader takes for a quiet process.
    it "names the bot as unreadable rather than showing it as silent" do
      get "/logs", source: "bot"

      expect(last_response.body).to include("configured for the bot")
    end

    it "falls back rather than refusing when the filters make no sense" do
      log!("info", "still here")
      get "/logs", source: "nonsense", level: "nonsense", limit: "-4"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("still here")
    end
  end

  # source=all is the only path that merges two processes, and merging is where
  # an order or a count goes wrong. RingBuffer keeps the whole formatted line as
  # the text, so these match on it rather than comparing it whole.
  describe "merging both processes" do
    let(:bot) do
      Class.new do
        def fetch(level: nil, limit: nil)
          entries = [{ "time" => "2026-07-01T12:00:09Z", "level" => "INFO", "text" => "from the bot" }]
          Rubotty::Api::BotLogsClient::Result.new(entries: entries, error: nil)
        end
      end.new
    end

    it "reads both into one list, oldest first" do
      log!("info", "from the web", at: Time.utc(2026, 7, 1, 12, 0, 1))
      view = Rubotty::Dashboard::DebugLogs.new(log_buffer: buffer, bot_logs: bot).fetch(source: "all")

      expect(view["entries"].map { |entry| entry["source"] }).to eq(%w[web bot])
      expect(view["entries"].first["text"]).to include("from the web")
      expect(view["errors"]).to be_empty
    end

    it "trims the merged list to the limit, rather than the limit per process" do
      3.times { |i| log!("info", "web #{i}", at: Time.utc(2026, 7, 1, 12, 0, i)) }
      view = Rubotty::Dashboard::DebugLogs.new(log_buffer: buffer, bot_logs: bot)
                                           .fetch(source: "all", limit: 2)

      expect(view["entries"].length).to eq(2)
      expect(view["entries"].last["source"]).to eq("bot")
    end
  end

  describe "a non-administrator session" do
    let(:app) do
      operator_deps = deps
      Class.new(Rubotty::Dashboard::App) do
        set :deps, operator_deps
        helpers do
          define_method(:authenticated?) { true }
          define_method(:current_role) { Rubotty::Dashboard::Role.operator(community_ids: []) }
        end
      end
    end

    it "cannot read the logs, even with no community scope at all" do
      get "/logs"

      expect(last_response.status).to eq(403)
    end
  end
end
