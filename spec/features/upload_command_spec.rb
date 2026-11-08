# frozen_string_literal: true

require "spec_helper"

# Namespaced so a same-named helper in another spec file cannot reopen this
# as a top-level constant.
module UploadCommandFakes
  # The DM path is Adapters::Base#supports_admin_dm? and #send_admin_dm. The "cannot DM" case
  # below uses the plain RecordingAdapter, which answers false as an adapter with no DM does.
  class DmAdapter < Fakes::RecordingAdapter
    def initialize(**rest)
      super
      @dms = []
    end

    attr_reader :dms

    def supports_admin_dm? = true

    def send_admin_dm(native_id, text)
      @dms << [native_id, text]
      true
    end
  end
end

# The /upload chat command against the real seeded SAMPLE control plane, so parse, ticket and
# DM all run through the actual UploadTickets.
RSpec.describe Rubotty::Features::UploadCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:tickets) { Rubotty::ControlPlane::UploadTickets.new(models: models, logger: Rubotty::Log.null) }

  let(:adapter) { UploadCommandFakes::DmAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      tickets: tickets, ephemeral: ephemeral,
      env: { "GUEST_PORTAL_URL" => "https://rubotty.example/guest-chat" }
    )
  end

  def asker
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New")
  end

  def run(text = "/upload", author: asker, endpoint_key: "tg-general", config: {})
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key(endpoint_key)
    msg = message(channel.endpoint, text: text, native_id: "m#{rand(100_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel,
                                                 config: config))
  end

  def ack = adapter.delivered.last&.last&.body&.text

  it "shares the file-rehosting feature's own name, so one row governs both" do
    expect(described_class.feature_name).to eq(Rubotty::Features::FileRehosting.feature_name)
    expect(described_class.default_enabled?).to be(false)
  end

  it "exposes ack_ttl_seconds and delete_command_message through the borrowed file_rehosting schema" do
    schema = Rubotty::Features::FileRehosting.config_schema
    expect(schema.fields[Rubotty::Core::CommandAck::TTL_FIELD].default)
      .to eq(Rubotty::Core::CommandAck::DEFAULT_TTL_SECONDS)
    expect(schema.fields[Rubotty::Core::CommandAck::DELETE_COMMAND_FIELD].default)
      .to eq(Rubotty::Core::CommandAck::DELETE_COMMAND_DEFAULT)
  end

  it "is in the command registry, for /help and every native slash picker" do
    spec = Rubotty::Core::CommandRegistry.find("upload")

    expect(spec).not_to be_nil
    expect(spec.audience).to eq(:everyone)
    expect(spec.arguments).to be_empty
  end

  describe "without a control plane" do
    let(:bare_adapter) { UploadCommandFakes::DmAdapter.new(own_id: "bot-1") }

    def bare
      described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: Hash.new(bare_adapter), logger: Rubotty::Log.null
      )
    end

    it "refuses rather than relays a recognised /upload" do
      msg = message(endpoint("a"), text: "/upload")
      outcome = bare.call(Rubotty::Features::Context.new(message: msg))
      expect(outcome).to be_halt
      expect(bare_adapter.delivered_to("a").last.body.text).to include("/upload")
    end

    it "still lets an unrecognised message continue" do
      msg = message(endpoint("a"), text: "just chatting")
      outcome = bare.call(Rubotty::Features::Context.new(message: msg))
      expect(outcome).to be_continue
      expect(bare_adapter.delivered).to be_empty
    end
  end

  describe "issuing" do
    it "mints a ticket and DMs its link, never posting it in the channel" do
      outcome = run

      expect(outcome).to be_halt
      expect(models.rehosted_upload_ticket.count).to eq(1)

      native_id, text = adapter.dms.last
      expect(native_id).to eq("999888")
      expect(text).to match(%r{https://rubotty\.example/guest-chat/u/[\w-]{20,}})
      expect(ack).to include("direct message")
      expect(ack).not_to include("/u/")
    end

    # The room comes from where the command was typed, so nothing the browser sends later
    # can redirect the result elsewhere.
    it "records the room and endpoint the command was typed in" do
      run

      ticket = models.rehosted_upload_ticket.first
      expect(ticket.endpoint_key).to eq("tg-general")
      expect(ticket.room_key).to eq("general")
      expect(ticket.community_id).to eq(registry.current.community("sample").id)
    end

    it "swallows the command rather than relaying the word to the other platform" do
      expect(run).to be_halt
      expect(run.value).to eq([])
    end

    it "ignores anything that is not /upload" do
      outcome = run("just talking about /uploads in general")

      expect(outcome).to be_continue
      expect(models.rehosted_upload_ticket.count).to be_zero
    end
  end

  describe "when there is nowhere private to send it" do
    let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }

    it "says so and mints nothing" do
      run

      expect(models.rehosted_upload_ticket.count).to be_zero
      expect(ack).to include("cannot send you a direct message")
    end
  end

  # #1699: the dashboard's own File Uploads toggle, independent of File
  # Rehosting's. enable_upload_command => false refuses the command the same
  # way an unconfigured deployment does, without touching rehost_inbound.
  describe "when the File Uploads half is turned off in config" do
    it "refuses rather than relays it, and mints nothing" do
      outcome = run(config: { "enable_upload_command" => false })

      expect(outcome).to be_halt
      expect(ack).to include("not available")
      expect(models.rehosted_upload_ticket.count).to be_zero
    end

    it "still works when enable_upload_command is unset, the same as before the split" do
      outcome = run(config: {})

      expect(outcome).to be_halt
      expect(models.rehosted_upload_ticket.count).to eq(1)
    end
  end

  describe "with no upload tickets service" do
    subject(:feature) do
      described_class.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        ephemeral: ephemeral
      )
    end

    it "refuses rather than relays it, and mints nothing" do
      outcome = run
      expect(outcome).to be_halt
      expect(ack).to include("/upload")
      expect(adapter.dms).to be_empty
    end
  end

  describe "the acknowledgement TTL and command pairing are configurable" do
    let(:base) { Time.now }
    let(:clock) { -> { @now ||= base } }
    def advance(seconds) = (@now = (@now || base) + seconds)

    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }
    let(:ephemeral) do
      Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null,
        clock: clock
      )
    end
    subject(:feature) do
      described_class.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        tickets: tickets, ephemeral: ephemeral, cleanup: scheduler,
        env: { "GUEST_PORTAL_URL" => "https://rubotty.example/guest-chat" }
      )
    end

    after { scheduler.stop }

    def run_fixed(native_id:, config: {})
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-general")
      msg = message(channel.endpoint, text: "/upload", native_id: native_id, author: asker)
      feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel,
                                                   config: config))
    end

    it "honours a configured ack_ttl_seconds instead of the hardcoded 30s default" do
      run_fixed(native_id: "77", config: { ack_ttl_seconds: 90 })

      advance(30)
      scheduler.run_due
      expect(scheduler.pending).to eq(1) # still waiting: the default 30s has not fired

      advance(60)
      scheduler.run_due
      expect(scheduler.pending).to eq(0)
    end

    it "takes the invoking /upload message with it by default" do
      run_fixed(native_id: "77")

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-general d1], %w[tg-general 77])
    end

    it "leaves the invocation alone when delete_command_message is false" do
      run_fixed(native_id: "77", config: { delete_command_message: false })

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-general d1])
      expect(adapter.deleted).not_to include(%w[tg-general 77])
    end
  end
end
