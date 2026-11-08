# frozen_string_literal: true

require "spec_helper"

# The /guest chat command against the real seeded SAMPLE control plane. The seed leaves
# "general" allowed once guests are on and "gaming" disallowed, which the gating cases use.
RSpec.describe Rubotty::Features::GuestCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models, logger: Rubotty::Log.null) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      guest_invites: invites, ephemeral: ephemeral, env: { "GUEST_PORTAL_URL" => "https://rubotty.example/guest-chat" }
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-general").endpoint

  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New", last_name: "Bie")
  end

  # The seeded bootstrap operator on Telegram (sample_owner).
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  def run(text, author:, endpoint_key: "tg-general", config: {})
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key(endpoint_key)
    msg = message(channel.endpoint, text: text, native_id: "m#{rand(100_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: config))
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  def allow_guests!(who: "operators", selector: "general")
    controls.enable(community: registry.current.community("sample"), selector: selector, feature: "guest_portal")
    controls.set(community: registry.current.community("sample"), selector: selector, feature: "guest_portal",
                 key: "who_can_invite", value: who)
  end

  describe "the feature contract" do
    it "shares Features::GuestPortal's own feature_name, is off by code default, and observes only chat" do
      expect(described_class.feature_name).to eq(Rubotty::Features::GuestPortal.feature_name)
      expect(described_class.feature_name).to eq("guest_portal")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "exposes ack_ttl_seconds and delete_command_message through the borrowed guest_portal schema" do
      schema = Rubotty::Features::GuestPortal.config_schema
      expect(schema.fields[Rubotty::Core::CommandAck::TTL_FIELD].default)
        .to eq(Rubotty::Core::CommandAck::DEFAULT_TTL_SECONDS)
      expect(schema.fields[Rubotty::Core::CommandAck::DELETE_COMMAND_FIELD].default)
        .to eq(Rubotty::Core::CommandAck::DELETE_COMMAND_DEFAULT)
    end

    it "refuses rather than relays a recognised /guest without a control plane" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "/guest Sam")))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/guest")
    end

    it "still lets an unrecognised message continue with no control plane at all" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "ignores an ordinary message, letting it continue down the pipeline" do
      expect(run("just chatting about the game", author: newcomer)).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "when the room's guest_portal feature is off" do
    it "declines politely and issues nothing" do
      outcome = run("/guest Sam", author: boss)
      expect(outcome).to be_halt # swallowed, never relayed as content
      expect(ack_on("tg-general")).to match(/not allowed/i)
      expect(models.guest_invite.count).to eq(0)
    end
  end

  describe "permission" do
    it "lets an operator invite where who_can_invite is operators (the default)" do
      allow_guests!(who: "operators")
      run("/guest Sam", author: boss)
      expect(models.guest_invite.count).to eq(1)
    end

    it "declines a normal member when who_can_invite is operators" do
      allow_guests!(who: "operators")
      run("/guest Sam", author: newcomer)
      expect(ack_on("tg-general")).to match(/only operators/i)
      expect(models.guest_invite.count).to eq(0)
    end

    it "lets a normal member invite when who_can_invite is everyone" do
      allow_guests!(who: "everyone")
      run("/guest Sam", author: newcomer)
      expect(models.guest_invite.count).to eq(1)
    end
  end

  describe "a well-formed invite" do
    before { allow_guests!(who: "everyone") }

    it "issues the invite scoped to the room the command was typed in, defaulting to a 24h lifetime" do
      run("/guest Sam", author: newcomer)
      invite = models.guest_invite.first
      expect(invite.nickname).to eq("Sam")
      expect(invite.room_id).to eq(models.room.where(community_id: invite.community_id, room_key: "general").first.id)
      expect((invite.expires_at - invite.created_at).round).to eq(24 * 3600)
    end

    it "acknowledges with the guest link, worded as a one-time credential" do
      run("/guest Sam", author: newcomer)
      reply = ack_on("tg-general")
      # 24h prints as "1d", which is human_duration's own boundary.
      expect(reply).to match(%r{Guest invite for Sam, valid 1d: https://rubotty\.example/guest-chat/g/\S+})
      expect(reply).to match(/one-time credential/i)
      expect(reply).to match(/don't post it anywhere public/i)
    end

    it "recognises the command under the alternate ! prefix as well as /" do
      outcome = run("!guest Sam", author: newcomer)
      expect(outcome).to be_halt
      expect(models.guest_invite.count).to eq(1)
    end

    it "reads a quoted multi-word nickname as one field" do
      run('/guest "Jane Doe"', author: newcomer)
      expect(models.guest_invite.first.nickname).to eq("Jane Doe")
    end

    it "reads an explicit duration in the shared 1h/30m/1d vocabulary" do
      run("/guest Sam 2h", author: newcomer)
      invite = models.guest_invite.first
      expect((invite.expires_at - invite.created_at).round).to eq(2 * 3600)
    end
  end

  describe "bad input" do
    before { allow_guests!(who: "everyone") }

    it "replies with usage for a bare /guest" do
      run("/guest", author: newcomer)
      expect(ack_on("tg-general")).to match(/Usage: \/guest/)
      expect(models.guest_invite.count).to eq(0)
    end

    it "declines a duration it cannot parse rather than silently defaulting" do
      run("/guest Sam not-a-duration", author: newcomer)
      expect(ack_on("tg-general")).to match(/could not read that duration/i)
      expect(models.guest_invite.count).to eq(0)
    end

    it "asks for quoting rather than guessing at an unquoted multi-word nickname plus a duration" do
      run("/guest Jane Doe 2h", author: newcomer)
      expect(ack_on("tg-general")).to match(/quote a multi-word nickname/i)
      expect(models.guest_invite.count).to eq(0)
    end

    it "reports unmatched quoting rather than raising" do
      expect { run('/guest "Unterminated', author: newcomer) }.not_to raise_error
      expect(ack_on("tg-general")).to match(/quoting/i)
      expect(models.guest_invite.count).to eq(0)
    end

    it "leaves an unknown prefixed token alone, so the bridge relays it" do
      outcome = run("!guestbook musings", author: newcomer)
      expect(outcome).to be_continue
      expect(models.guest_invite.count).to eq(0)
    end
  end

  describe "the guest link" do
    before { allow_guests!(who: "everyone") }

    it "falls back to the bare /g/<token> path when GUEST_PORTAL_URL is unset" do
      bare_feature = described_class.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        guest_invites: invites, ephemeral: ephemeral, env: {}
      )
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-general")
      msg = message(channel.endpoint, text: "/guest Sam", native_id: "m1", author: newcomer)
      bare_feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel))
      expect(ack_on("tg-general")).to match(%r{: /g/\S+})
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
        guest_invites: invites, ephemeral: ephemeral, cleanup: scheduler,
        env: { "GUEST_PORTAL_URL" => "https://rubotty.example/guest-chat" }
      )
    end

    after { scheduler.stop }
    before { allow_guests!(who: "everyone") }

    def run_fixed(text, native_id:, author: boss, config: {})
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-general")
      msg = message(channel.endpoint, text: text, native_id: native_id, author: author)
      feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel,
                                                   config: config))
    end

    # Bare /guest with no arguments never mints an invite, so it is a reply the ack path
    # will actually schedule to self-delete without a control-plane round trip beforehand.
    it "honours a configured ack_ttl_seconds instead of the hardcoded 30s default" do
      run_fixed("/guest", native_id: "77", config: { ack_ttl_seconds: 90 })

      advance(30)
      scheduler.run_due
      expect(scheduler.pending).to eq(1) # still waiting: the default 30s has not fired

      advance(60)
      scheduler.run_due
      expect(scheduler.pending).to eq(0)
    end

    it "takes the invoking /guest message with it by default" do
      run_fixed("/guest", native_id: "77")

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-general d1], %w[tg-general 77])
    end

    it "leaves the invocation alone when delete_command_message is false" do
      run_fixed("/guest", native_id: "77", config: { delete_command_message: false })

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-general d1])
      expect(adapter.deleted).not_to include(%w[tg-general 77])
    end
  end
end
