# frozen_string_literal: true

require "spec_helper"
require "socket"

# An always-on health endpoint for the pure-worker deployment, which stands
# aside in webhook mode so nothing double-binds $PORT.
RSpec.describe Rubotty::Core::Runtime, "health endpoint" do
  # Connect fails as discordrb would on a rejected token; named distinctly from
  # runtime_spec's to avoid a shared constant.
  class UnreachableDiscordClient
    def connect = raise(RuntimeError.new("401 Unauthorized"))
    def connected? = false
    def stop = nil
    def bot = nil
  end

  let(:tg_http) { Fakes::TelegramHttp.new }

  # PORT 0 lets the OS pick a free port, so the suite never contends for one.
  def runtime_for(yaml, env: { "PORT" => "0" })
    config = Rubotty::Config::Loader.load_string(
      yaml, env: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token" }
    )
    described_class.new(config: config, logger: Rubotty::Log.null, env: env)
  end

  def status_line(port, path: "/healthz")
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("GET #{path} HTTP/1.0\r\nHost: health\r\n\r\n")
    socket.gets.to_s.strip
  ensure
    socket&.close
  end

  before do
    tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
    tg_http.on("deleteWebhook", true)
    tg_http.default_result([])
  end

  # The production worker's shape: one healthy adapter, no discordrb dependency.
  let(:long_polling_yaml) do
    <<~YAML
      name: health
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
          poll_timeout: 0
      storage:
        driver: memory
      behaviour:
        log_level: fatal
        purge_interval: 0
      rooms:
        - id: lounge
          endpoints:
            - id: tg-a
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
            - id: tg-b
              adapter: telegram
              account: tg
              chat_id: "-1001061926370"
    YAML
  end

  context "in long-polling (worker) mode" do
    let(:runtime) { runtime_for(long_polling_yaml) }

    before do
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      runtime.start
    end

    after { runtime.stop }

    it "starts an always-on health server" do
      expect(runtime.health).to be_a(Rubotty::Core::HealthServer)
      expect(runtime.health.running?).to be(true)
    end

    it "serves 200 on /healthz while the poller is alive" do
      expect(runtime.healthy?).to be(true)
      expect(status_line(runtime.health.bound_port)).to eq("HTTP/1.1 200 OK")
    end

    it "tears the server down on stop" do
      server = runtime.health
      runtime.stop
      expect(server.running?).to be(false)
    end
  end

  # A platform health check that finds nothing listening while an adapter is
  # still connecting rolls the deploy back before boot ever finishes (#1476).
  # The port has to open before anything that can run long, not after.
  context "ordering: the health port opens before an adapter start can block it" do
    let(:runtime) { runtime_for(long_polling_yaml) }
    let(:health_running_during_adapter_start) { [] }

    before do
      runtime.build
      adapter = runtime.adapters[[:telegram, "tg"]]
      adapter.replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http))
      allow(adapter).to receive(:start).and_wrap_original do |original, *args|
        health_running_during_adapter_start << runtime.health&.running?
        original.call(*args)
      end
      runtime.start
    end

    after { runtime.stop }

    it "already has the health server bound by the time the first adapter starts" do
      expect(health_running_during_adapter_start).to eq([true])
    end
  end

  # A connect attempt that has not yet resolved is not the same as one that
  # has failed (#1478): the old running?-only check treated both as unhealthy,
  # leaving a health check with nothing but "connection refused" to report
  # for as long as the slowest platform took to come up.
  context "while an adapter is still connecting, having neither succeeded nor errored" do
    let(:runtime) { runtime_for(long_polling_yaml) }
    let(:gate) { Queue.new }

    before do
      runtime.build
      adapter = runtime.adapters[[:telegram, "tg"]]
      adapter.replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http))
      allow(adapter).to receive(:start).and_wrap_original do |original, *args|
        gate.pop
        original.call(*args)
      end
    end

    after { runtime.stop }

    it "reads healthy while boot is still in flight, then stays healthy once it lands" do
      thread = Thread.new { runtime.start }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until runtime.dispatcher&.running? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      expect(runtime.adapters[[:telegram, "tg"]].running?).to be(false)
      expect(runtime.healthy?).to be(true)

      gate << :go
      thread.join

      expect(runtime.adapters[[:telegram, "tg"]].running?).to be(true)
      expect(runtime.healthy?).to be(true)
    end
  end

  # Two platforms starting at once should not wait on each other; a slow
  # Discord gateway handshake used to hold up an already-ready Telegram
  # poller from ever reporting running (#1478).
  context "starting two adapters at once" do
    let(:dc_gate) { Queue.new }
    let(:mixed_yaml) do
      <<~YAML
        name: parallel-start
        accounts:
          dc:
            adapter: discord
            token_env: DC_TOKEN
          tg:
            adapter: telegram
            token_env: TG_TOKEN
            poll_timeout: 0
        storage:
          driver: memory
        behaviour:
          log_level: fatal
          purge_interval: 0
        rooms:
          - id: lounge
            endpoints:
              - id: tg-lounge
                adapter: telegram
                account: tg
                chat_id: "-1008000000001"
              - id: dc-lounge
                adapter: discord
                account: dc
                channel_id: "8000000000000000003"
      YAML
    end

    class BlockingDiscordClient
      def initialize(gate)
        @gate = gate
        @connected = false
      end

      def connect
        @gate.pop
        @connected = true
      end

      def connected? = @connected
      def stop = nil
      def bot = nil
    end

    let(:runtime) { runtime_for(mixed_yaml) }

    before do
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      runtime.adapters[[:discord, "dc"]].replace_client(BlockingDiscordClient.new(dc_gate))
    end

    after { runtime.stop }

    it "lets Telegram finish starting without waiting for Discord's still-blocked connect" do
      thread = Thread.new { runtime.start }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until runtime.adapters[[:telegram, "tg"]].running? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end

      expect(runtime.adapters[[:telegram, "tg"]].running?).to be(true)
      expect(runtime.adapters[[:discord, "dc"]].running?).to be(false)

      dc_gate << :go
      thread.join
    end
  end

  # RUBOTTY_INTERNAL_SECRET mounts the reload route on the SAME server
  # #start_health_server already stands up, rather than growing a second one.
  context "the internal reload route (issue #224)" do
    def post(port, headers: {})
      socket = TCPSocket.new("127.0.0.1", port)
      header_lines = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      socket.write(
        "POST #{Rubotty::Core::HealthServer::RELOAD_PATH} HTTP/1.0\r\nHost: health\r\n" \
        "Content-Length: 0\r\n#{header_lines}\r\n"
      )
      socket.gets.to_s.strip
    ensure
      socket&.close
    end

    let(:runtime) { runtime_for(long_polling_yaml, env: { "PORT" => "0", "RUBOTTY_INTERNAL_SECRET" => "s3cret" }) }

    before do
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      runtime.start
    end

    after { runtime.stop }

    it "answers with the correct secret, over the same port as /healthz" do
      line = post(runtime.health.bound_port, headers: { "x-rubotty-internal-secret" => "s3cret" })
      expect(line).to eq("HTTP/1.1 204 No Content") # no control plane on this config path
    end

    it "refuses without the secret" do
      line = post(runtime.health.bound_port)
      expect(line).to eq("HTTP/1.1 403 Forbidden")
    end

    it "mounts no reload route at all when RUBOTTY_INTERNAL_SECRET is unset" do
      plain = runtime_for(long_polling_yaml)
      plain.build
      plain.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: Fakes::TelegramHttp.new.tap do |h|
          h.on("getMe", { "id" => 1, "username" => "b" })
          h.on("deleteWebhook", true)
          h.default_result([])
        end)
      )
      plain.start
      line = post(plain.health.bound_port, headers: { "x-rubotty-internal-secret" => "anything" })
      expect(line).to eq("HTTP/1.1 200 OK") # falls through to the liveness handler
    ensure
      plain.stop
    end
  end

  # No adapter answers for the deferred-cleanup thread, so a bridge whose cleanup
  # thread had died reported a clean bill of health while every acknowledgement
  # it posted stayed in the channel for good.
  context "when the cleanup scheduler thread has died" do
    # A self-deleting banner is what makes the runtime build the scheduler at all.
    let(:cleanup_yaml) { "#{long_polling_yaml}announce:\n  room: lounge\n  delete_after: 120\n" }
    let(:runtime) { runtime_for(cleanup_yaml) }

    before do
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      runtime.start
    end

    after { runtime.stop }

    it "is healthy while the thread is alive" do
      expect(runtime.scheduler).to be_a(Rubotty::Core::Scheduler)
      expect(runtime.healthy?).to be(true)
    end

    it "reports unhealthy once the thread is gone, even with every adapter up" do
      thread = runtime.scheduler.instance_variable_get(:@thread)
      thread.kill
      thread.join

      expect(runtime.adapters.each_value).to all(be_running)
      expect(runtime.healthy?).to be(false)
      expect(status_line(runtime.health.bound_port)).to eq("HTTP/1.1 503 Service Unavailable")
    end
  end

  context "when an adapter is down" do
    # Telegram healthy, Discord's gateway connect rejected.
    let(:mixed_yaml) do
      <<~YAML
        name: health-mixed
        accounts:
          tg:
            adapter: telegram
            token_env: TG_TOKEN
            poll_timeout: 0
          dc:
            adapter: discord
            token_env: DC_TOKEN
        storage:
          driver: memory
        behaviour:
          log_level: fatal
          purge_interval: 0
        rooms:
          - id: lounge
            endpoints:
              - id: tg-lounge
                adapter: telegram
                account: tg
                chat_id: "-1008000000001"
              - id: dc-lounge
                adapter: discord
                account: dc
                channel_id: "8000000000000000003"
      YAML
    end

    let(:runtime) { runtime_for(mixed_yaml) }

    before do
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      runtime.adapters[[:discord, "dc"]].replace_client(UnreachableDiscordClient.new)
      runtime.start
    end

    after { runtime.stop }

    it "reports unhealthy" do
      expect(runtime.healthy?).to be(false)
    end

    it "serves 503 on /healthz" do
      expect(status_line(runtime.health.bound_port)).to eq("HTTP/1.1 503 Service Unavailable")
    end
  end

  context "in webhook mode" do
    # The webhook transport binds $PORT and serves its own /healthz.
    let(:webhook_yaml) do
      <<~YAML
        name: health-webhook
        accounts:
          tg:
            adapter: telegram
            token_env: TG_TOKEN
            transport: webhook
            webhook_url: https://bridge.example.com/telegram/webhook
        storage:
          driver: memory
        behaviour:
          log_level: fatal
          purge_interval: 0
        rooms:
          - id: lounge
            endpoints:
              - id: tg-a
                adapter: telegram
                account: tg
                chat_id: "-1008000000001"
              - id: tg-b
                adapter: telegram
                account: tg
                chat_id: "-1001061926370"
      YAML
    end

    let(:runtime) { runtime_for(webhook_yaml) }

    it "recognises that the webhook transport owns the port" do
      expect(runtime.send(:webhook_transport_active?)).to be(true)
    end

    # Driven directly, so coexistence is proven without a real double bind.
    it "does not start a standalone health server" do
      runtime.send(:start_health_server)
      expect(runtime.health).to be_nil
    end
  end
end
