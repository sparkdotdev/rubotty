# frozen_string_literal: true

require "spec_helper"

# The startup banner can be scheduled for deletion after a delay, so a restart
# diagnostic does not linger. It posts to every endpoint of the nominated room as
# one linked ephemeral group, so one group deletion removes every copy.
RSpec.describe "startup banner auto delete" do
  def yaml(delete_after: 30)
    <<~YAML
      name: integration bridge
      accounts:
        tg: { adapter: telegram, token_env: TG_TOKEN }
        dc: { adapter: discord, token_env: DC_TOKEN }
      storage:
        driver: memory
      behaviour:
        log_level: fatal
      announce:
        room: lounge
        detail: minimal
        delete_after: #{delete_after}
        # No control plane here, which is off by default now.
        without_control_plane: true
      rooms:
        - id: lounge
          endpoints:
            - { id: tg-lounge, adapter: telegram, account: tg, chat_id: "-100111" }
            - { id: dc-lounge, adapter: discord, account: dc, channel_id: "8000000000000000003" }
    YAML
  end

  let(:tg_http) { Fakes::TelegramHttp.new }
  let(:dc_client) { DiscordFakes::Client.new(own_id: "bot-dc") }

  let(:base) { Time.now }
  let(:clock) { -> { @now ||= base } }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }

  def advance(seconds) = (@now = (@now || base) + seconds)

  def build_runtime(source)
    config = Rubotty::Config::Loader.load_string(
      source, env: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc" }
    )
    Rubotty::Core::Runtime.new(config: config, logger: Rubotty::Log.null).tap do |runtime|
      tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
      tg_http.on("sendMessage", { "message_id" => 77 })
      tg_http.default_result([])
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      runtime.adapters[[:discord, "dc"]].replace_client(dc_client)
      # Drive the deletion through a scheduler whose clock we control.
      runtime.instance_variable_set(:@scheduler, scheduler)
    end
  end

  let(:runtime) { build_runtime(yaml) }
  let(:lounge_channel) { dc_client.channel("8000000000000000003") }

  after { runtime.stop }

  def announce! = runtime.send(:announce_startup)

  # One linked group, so one scheduled deletion rather than a job per endpoint.
  it "schedules a single group deletion for the banner it posted" do
    announce!
    expect(lounge_channel.sent.size).to eq(1)
    expect(scheduler.pending).to eq(1)
  end

  it "deletes the banner on each endpoint once the delay has elapsed" do
    announce!
    advance(30)
    scheduler.run_due

    # Telegram removes message 77, the id its send returned.
    expect(tg_http.last("deleteMessage").params["message_id"]).to eq(77)
    # Discord removes the banner it posted (the first sent message).
    expect(lounge_channel.load_message("sent-1").deleted).to be(true)
  end

  it "does not delete before the delay" do
    announce!
    advance(29)
    scheduler.run_due
    expect(tg_http.called?("deleteMessage")).to be(false)
    expect(lounge_channel.load_message("sent-1").deleted).to be(false)
  end

  # A suppressed banner was never posted, so there is nothing to schedule.
  it "schedules nothing for a suppressed banner" do
    announce!
    pending_after_first = scheduler.pending

    announce! # inside the suppress window, so nothing is posted this time
    expect(scheduler.pending).to eq(pending_after_first)
  end

  # With the delay left at 0 the banner persists.
  it "schedules nothing when delete_after is 0" do
    zero = build_runtime(yaml(delete_after: 0))
    # build_runtime overwrote its scheduler with ours, so we can inspect it.
    zero.send(:announce_startup)
    expect(scheduler.pending).to eq(0)
    zero.stop
  end
end
