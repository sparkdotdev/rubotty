# frozen_string_literal: true

require "spec_helper"
require "socket"

# Bound on port 0 so the suite never fights over a fixed port, and probed over a
# raw TCPSocket because spec_helper puts Net::HTTP off limits here.
RSpec.describe Rubotty::Core::HealthServer do
  def status_line(port, path: "/healthz", method: "GET")
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("#{method} #{path} HTTP/1.0\r\nHost: health\r\n\r\n")
    socket.gets.to_s.strip
  ensure
    socket&.close
  end

  def body(port, path: "/healthz")
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("GET #{path} HTTP/1.0\r\nHost: health\r\n\r\n")
    socket.read.to_s.split("\r\n\r\n", 2).last
  ensure
    socket&.close
  end

  let(:healthy) { true }
  subject(:server) do
    described_class.new(liveness: -> { healthy }, logger: Rubotty::Log.null, port: 0)
  end

  after { server.stop }

  it "answers /healthz with 200 while the liveness probe is truthy" do
    server.start
    expect(status_line(server.bound_port)).to eq("HTTP/1.1 200 OK")
    expect(body(server.bound_port)).to eq("ok\n")
  end

  context "when the liveness probe reports the process is down" do
    let(:healthy) { false }

    it "answers /healthz with 503" do
      server.start
      expect(status_line(server.bound_port)).to eq("HTTP/1.1 503 Service Unavailable")
      expect(body(server.bound_port)).to eq("unhealthy\n")
    end
  end

  it "answers a bare GET / too, for a platform that probes the root" do
    server.start
    expect(status_line(server.bound_port, path: "/")).to eq("HTTP/1.1 200 OK")
  end

  it "reflects the liveness probe live, without a restart" do
    flag = true
    live = described_class.new(liveness: -> { flag }, logger: Rubotty::Log.null, port: 0)
    live.start
    expect(live.status).to eq(200)
    flag = false
    expect(live.status).to eq(503)
  ensure
    live.stop
  end

  it "reports unhealthy rather than crashing when the probe itself raises" do
    boom = described_class.new(
      liveness: -> { raise "probe exploded" }, logger: Rubotty::Log.null, port: 0
    )
    boom.start
    expect(status_line(boom.bound_port)).to eq("HTTP/1.1 503 Service Unavailable")
  ensure
    boom.stop
  end

  it "is safe to stop when never started, and safe to stop twice" do
    expect { server.stop }.not_to raise_error
    server.start
    server.stop
    expect { server.stop }.not_to raise_error
    expect(server.running?).to be(false)
  end

  # An authenticated POST re-reads the control plane over the same internal port
  # the liveness probe already binds, never the public tunnel.
  describe "the internal reload route (issue #224)" do
    def post(port, path: described_class::RELOAD_PATH, headers: {}, body: "")
      socket = TCPSocket.new("127.0.0.1", port)
      header_lines = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      socket.write(
        "POST #{path} HTTP/1.0\r\nHost: health\r\nContent-Length: #{body.bytesize}\r\n#{header_lines}\r\n#{body}"
      )
      socket.gets.to_s.strip
    ensure
      socket&.close
    end

    let(:reload_calls) { [] }
    let(:reload) { ->(reason:) { reload_calls << reason; true } }

    subject(:server) do
      described_class.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
        reload: reload, reload_secret: "s3cret"
      )
    end

    it "reloads and answers 200 with the correct secret" do
      server.start
      line = post(server.bound_port, headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(line).to eq("HTTP/1.1 200 OK")
      expect(reload_calls).to eq(["push"])
    end

    it "carries the POST body through as the reload reason" do
      server.start
      post(server.bound_port, headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" },
                              body: "dashboard write")
      expect(reload_calls).to eq(["dashboard write"])
    end

    it "answers 403 and never reloads with a wrong secret" do
      server.start
      line = post(server.bound_port, headers: { described_class::RELOAD_SECRET_HEADER => "wrong" })
      expect(line).to eq("HTTP/1.1 403 Forbidden")
      expect(reload_calls).to be_empty
    end

    it "answers 403 and never reloads with no secret header at all" do
      server.start
      line = post(server.bound_port)
      expect(line).to eq("HTTP/1.1 403 Forbidden")
      expect(reload_calls).to be_empty
    end

    it "answers 405 for a GET, never reloading" do
      server.start
      line = status_line(server.bound_port, path: described_class::RELOAD_PATH)
      expect(line).to eq("HTTP/1.1 405 Method Not Allowed")
      expect(reload_calls).to be_empty
    end

    it "answers 204 when there is no control plane to reload" do
      no_plane = described_class.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
        reload: ->(reason:) { false }, reload_secret: "s3cret"
      )
      no_plane.start
      line = post(no_plane.bound_port, headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(line).to eq("HTTP/1.1 204 No Content")
    ensure
      no_plane.stop
    end

    it "answers 500 rather than crashing the server when the reload callable raises" do
      boom = described_class.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
        reload: ->(reason:) { raise "boom" }, reload_secret: "s3cret"
      )
      boom.start
      line = post(boom.bound_port, headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(line).to eq("HTTP/1.1 500 Internal Server Error")
    ensure
      boom.stop
    end

    it "never mounts the route at all when no secret is configured, falling through to liveness" do
      unconfigured = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0, reload: reload)
      unconfigured.start
      line = post(unconfigured.bound_port, headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(line).to eq("HTTP/1.1 200 OK")
      expect(reload_calls).to be_empty
    ensure
      unconfigured.stop
    end

    it "never mounts the route at all when no reload callable is given" do
      no_callable = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0, reload_secret: "s3cret")
      no_callable.start
      line = post(no_callable.bound_port, headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(line).to eq("HTTP/1.1 200 OK")
    ensure
      no_callable.stop
    end
  end

  # The admin API's debug/logs endpoint reads this process's own recent lines
  # over the same authenticated internal hop as the reload route.
  describe "the internal logs route (issue #236)" do
    def get(port, path:, headers: {})
      socket = TCPSocket.new("127.0.0.1", port)
      header_lines = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      socket.write("GET #{path} HTTP/1.0\r\nHost: health\r\n#{header_lines}\r\n")
      response = socket.read.to_s
      [response.lines.first.to_s.strip, response.split("\r\n\r\n", 2).last]
    ensure
      socket&.close
    end

    let(:buffer) do
      Rubotty::RingBuffer.new.tap do |b|
        b << "2026-07-27T12:00:00Z INFO  ordinary line\n"
        b << "2026-07-27T12:00:01Z WARN  a warning\n"
        b << "2026-07-27T12:00:02Z ERROR something broke\n"
      end
    end

    subject(:server) do
      described_class.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
        reload_secret: "s3cret", log_buffer: buffer
      )
    end

    it "serves the buffer's entries as YAML with the correct secret" do
      server.start
      status, body = get(server.bound_port, path: described_class::LOGS_PATH,
                                            headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(status).to eq("HTTP/1.1 200 OK")
      parsed = YAMLCamel.load(body)
      expect(parsed["entries"].map { |e| e["level"] }).to eq(%w[INFO WARN ERROR])
      expect(parsed["entries"].first["text"]).to include("ordinary line")
    end

    it "filters by level via the query string" do
      server.start
      _status, body = get(
        server.bound_port, path: "#{described_class::LOGS_PATH}?level=warn",
        headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" }
      )
      parsed = YAMLCamel.load(body)
      expect(parsed["entries"].map { |e| e["level"] }).to eq(%w[WARN ERROR])
    end

    it "caps to the last N via the limit query param" do
      server.start
      _status, body = get(
        server.bound_port, path: "#{described_class::LOGS_PATH}?limit=1",
        headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" }
      )
      parsed = YAMLCamel.load(body)
      expect(parsed["entries"].map { |e| e["level"] }).to eq(%w[ERROR])
    end

    it "answers 403 with a wrong secret, revealing nothing" do
      server.start
      status, _body = get(server.bound_port, path: described_class::LOGS_PATH,
                                             headers: { described_class::RELOAD_SECRET_HEADER => "wrong" })
      expect(status).to eq("HTTP/1.1 403 Forbidden")
    end

    it "answers 403 with no secret header at all" do
      server.start
      status, _body = get(server.bound_port, path: described_class::LOGS_PATH)
      expect(status).to eq("HTTP/1.1 403 Forbidden")
    end

    it "answers 405 for a POST" do
      server.start
      socket = TCPSocket.new("127.0.0.1", server.bound_port)
      socket.write(
        "POST #{described_class::LOGS_PATH} HTTP/1.0\r\nHost: health\r\n" \
        "#{described_class::RELOAD_SECRET_HEADER}: s3cret\r\nContent-Length: 0\r\n\r\n"
      )
      line = socket.gets.to_s.strip
      socket.close
      expect(line).to eq("HTTP/1.1 405 Method Not Allowed")
    end

    it "never mounts the route at all when no log_buffer is given, falling through to liveness" do
      no_buffer = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0, reload_secret: "s3cret")
      no_buffer.start
      status, _body = get(no_buffer.bound_port, path: described_class::LOGS_PATH,
                                                headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(status).to eq("HTTP/1.1 200 OK")
    ensure
      no_buffer.stop
    end

    it "never mounts the route at all when no secret is configured, falling through to liveness" do
      unconfigured = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0, log_buffer: buffer)
      unconfigured.start
      status, _body = get(unconfigured.bound_port, path: described_class::LOGS_PATH)
      expect(status).to eq("HTTP/1.1 200 OK")
    ensure
      unconfigured.stop
    end

    describe "the internal info route" do
      it "reports this process's own version, commit and liveness with the correct secret" do
        server.start
        status, body = get(server.bound_port, path: described_class::INFO_PATH,
                                              headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
        expect(status).to eq("HTTP/1.1 200 OK")
        parsed = YAMLCamel.load(body)
        expect(parsed["version"]).to eq(Rubotty::VERSION)
        expect(parsed["pid"]).to eq(Process.pid)
        expect(parsed["healthy"]).to be(true)
      end

      it "answers 403 with a wrong secret" do
        server.start
        status, _body = get(server.bound_port, path: described_class::INFO_PATH,
                                               headers: { described_class::RELOAD_SECRET_HEADER => "wrong" })
        expect(status).to eq("HTTP/1.1 403 Forbidden")
      end

      it "never mounts the route at all when no secret is configured" do
        unconfigured = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0)
        unconfigured.start
        status, _body = get(unconfigured.bound_port, path: described_class::INFO_PATH)
        expect(status).to eq("HTTP/1.1 200 OK")
      ensure
        unconfigured.stop
      end
    end

    # The admin API's debug/backfill-gaps endpoint running the read-only sweep
    # against this process's own adapters, over the same internal hop as the
    # logs and info routes above.
    describe "the internal backfill-gaps route" do
      let(:sample) do
        double("finding", endpoint_id: "dc-general", native_id: "900", timestamp: "2026-07-27T12:00:00Z")
      end
      let(:channel) do
        double("channel", endpoint_id: "dc-general", community: "sample", since: Time.utc(2026, 7, 27, 12, 0, 0),
                          fetched: 3, gaps: 1, ours: 1, claimed: 1, below_floor: 0, error: nil, samples: [sample])
      end
      let(:gap_report_calls) { [] }
      let(:gap_report) { -> { gap_report_calls << :called; [channel] } }

      subject(:server) do
        described_class.new(
          liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
          reload_secret: "s3cret", gap_report: gap_report
        )
      end

      it "serves the sweep's rows as YAML with the correct secret" do
        server.start
        status, body = get(server.bound_port, path: described_class::GAPS_PATH,
                                              headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
        expect(status).to eq("HTTP/1.1 200 OK")
        row = YAMLCamel.load(body)["channels"].first
        expect(row["endpoint_id"]).to eq("dc-general")
        expect(row["community"]).to eq("sample")
        expect(row["gaps"]).to eq(1)
        expect(row["since"]).to eq("2026-07-27T12:00:00Z")
      end

      it "carries only the sample's endpoint id, native id and timestamp, never a message body" do
        server.start
        _status, body = get(server.bound_port, path: described_class::GAPS_PATH,
                                               headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
        row = YAMLCamel.load(body)["channels"].first
        expect(row["samples"].first.keys).to match_array(%w[endpoint_id native_id timestamp])
      end

      it "answers 403 with a wrong secret, never running the sweep" do
        server.start
        status, _body = get(server.bound_port, path: described_class::GAPS_PATH,
                                               headers: { described_class::RELOAD_SECRET_HEADER => "wrong" })
        expect(status).to eq("HTTP/1.1 403 Forbidden")
        expect(gap_report_calls).to be_empty
      end

      it "answers 405 for a POST" do
        server.start
        socket = TCPSocket.new("127.0.0.1", server.bound_port)
        socket.write(
          "POST #{described_class::GAPS_PATH} HTTP/1.0\r\nHost: health\r\n" \
          "#{described_class::RELOAD_SECRET_HEADER}: s3cret\r\nContent-Length: 0\r\n\r\n"
        )
        line = socket.gets.to_s.strip
        socket.close
        expect(line).to eq("HTTP/1.1 405 Method Not Allowed")
      end

      it "answers 500 rather than crashing the server when the sweep raises" do
        boom = described_class.new(
          liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
          reload_secret: "s3cret", gap_report: -> { raise "boom" }
        )
        boom.start
        status, _body = get(boom.bound_port, path: described_class::GAPS_PATH,
                                             headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
        expect(status).to eq("HTTP/1.1 500 Internal Server Error")
      ensure
        boom.stop
      end

      it "never mounts the route at all when no sweep callable is given, falling through to liveness" do
        no_callable = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0, reload_secret: "s3cret")
        no_callable.start
        status, _body = get(no_callable.bound_port, path: described_class::GAPS_PATH,
                                                    headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
        expect(status).to eq("HTTP/1.1 200 OK")
      ensure
        no_callable.stop
      end

      it "never mounts the route at all when no secret is configured, falling through to liveness" do
        unconfigured = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0, gap_report: gap_report)
        unconfigured.start
        status, _body = get(unconfigured.bound_port, path: described_class::GAPS_PATH)
        expect(status).to eq("HTTP/1.1 200 OK")
      ensure
        unconfigured.stop
      end
    end
  end

  # The dashboard's Accept button, reaching the process holding the
  # adapters over the same internal hop the reload nudge and gap report use.
  describe "the internal relay-backfill-proposal route (issue #518)" do
    def post(port, path: described_class::RELAY_PROPOSAL_PATH, headers: {}, body: "")
      socket = TCPSocket.new("127.0.0.1", port)
      header_lines = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      socket.write(
        "POST #{path} HTTP/1.0\r\nHost: health\r\nContent-Length: #{body.bytesize}\r\n#{header_lines}\r\n#{body}"
      )
      response = socket.read.to_s
      [response.lines.first.to_s.strip, response.split("\r\n\r\n", 2).last]
    ensure
      socket&.close
    end

    let(:relay_calls) { [] }
    let(:outcome) { Rubotty::Core::BackfillProposalRelay::Outcome.new(ok: true, error: nil) }
    let(:relay_proposal) { ->(proposal_id:) { relay_calls << proposal_id; outcome } }

    subject(:server) do
      described_class.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
        reload_secret: "s3cret", relay_proposal: relay_proposal
      )
    end

    it "starts the relay and answers 202 with the correct secret, passing the id through as an integer" do
      server.start
      status, body = post(server.bound_port, body: "42",
                                             headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(status).to eq("HTTP/1.1 202 Accepted")
      expect(body).to eq("relay started\n")
      expect(relay_calls).to eq([42])
    end

    it "answers 422 with the callable's own error, never claiming success" do
      failing_outcome = Rubotty::Core::BackfillProposalRelay::Outcome.new(ok: false, error: "no such proposal")
      failing = described_class.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
        reload_secret: "s3cret", relay_proposal: ->(proposal_id:) { failing_outcome }
      )
      failing.start
      status, body = post(failing.bound_port, body: "999",
                                              headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(status).to eq("HTTP/1.1 422 Unprocessable Entity")
      expect(body).to eq("no such proposal\n")
    ensure
      failing.stop
    end

    it "answers 400 for a non-numeric body rather than calling the relay" do
      server.start
      status, = post(server.bound_port, body: "not-a-number",
                                        headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(status).to eq("HTTP/1.1 400 Bad Request")
      expect(relay_calls).to be_empty
    end

    it "answers 403 and never calls the relay with a wrong secret" do
      server.start
      status, = post(server.bound_port, body: "42", headers: { described_class::RELOAD_SECRET_HEADER => "wrong" })
      expect(status).to eq("HTTP/1.1 403 Forbidden")
      expect(relay_calls).to be_empty
    end

    it "answers 405 for a GET" do
      server.start
      line = status_line(server.bound_port, path: described_class::RELAY_PROPOSAL_PATH)
      expect(line).to eq("HTTP/1.1 405 Method Not Allowed")
    end

    it "answers 500 rather than crashing the server when the callable raises" do
      boom = described_class.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
        reload_secret: "s3cret", relay_proposal: ->(proposal_id:) { raise "boom" }
      )
      boom.start
      status, = post(boom.bound_port, body: "1", headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(status).to eq("HTTP/1.1 500 Internal Server Error")
    ensure
      boom.stop
    end

    it "never mounts the route at all when no callable is given, falling through to liveness" do
      no_callable = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0, reload_secret: "s3cret")
      no_callable.start
      status, = post(no_callable.bound_port, body: "1", headers: { described_class::RELOAD_SECRET_HEADER => "s3cret" })
      expect(status).to eq("HTTP/1.1 200 OK")
    ensure
      no_callable.stop
    end

    it "never mounts the route at all when no secret is configured, falling through to liveness" do
      unconfigured = described_class.new(liveness: -> { true }, logger: Rubotty::Log.null, port: 0,
                                         relay_proposal: relay_proposal)
      unconfigured.start
      status, = post(unconfigured.bound_port, body: "1")
      expect(status).to eq("HTTP/1.1 200 OK")
      expect(relay_calls).to be_empty
    ensure
      unconfigured.stop
    end
  end
end
