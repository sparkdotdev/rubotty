# frozen_string_literal: true

require "spec_helper"

# Driven against the seeded SAMPLE control plane, so a real platform_connections
# mapping stands in for an authorized space.
RSpec.describe "auto-leave decision", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:connection) { models.platform_connection.where(community_id: models.community.first.id).first }

  describe Rubotty::ControlPlane::AuthorizationDirectory do
    subject(:directory) { described_class.new(models: models) }

    it "authorizes a space the control plane maps to a community" do
      expect(directory.authorized?(adapter: connection.adapter, account: connection.account,
                                   external_id: connection.external_id)).to be(true)
    end

    it "names the community owning an authorized space" do
      community = directory.community_for(adapter: connection.adapter, account: connection.account,
                                          external_id: connection.external_id)
      expect(community&.id).to eq(models.community.first.id)
    end

    it "does not authorize an unmapped space" do
      expect(directory.authorized?(adapter: "telegram", account: "telegram", external_id: "-100999999"))
        .to be(false)
      expect(directory.community_for(adapter: "telegram", account: "telegram", external_id: "-100999999"))
        .to be_nil
    end

    it "does not authorize an unmapped space with an unrelated title (#118)" do
      expect(directory.authorized?(adapter: "telegram", account: "telegram", external_id: "-100999999",
                                   title: "Random Public Group")).to be(false)
    end

    it "authorizes an unmapped space whose title is on the deployment-configured whitelist (#118)" do
      # No platform_connections row, yet the protected title alone authorizes it.
      expect(directory.authorized?(adapter: "telegram", account: "telegram", external_id: "-100999999",
                                   title: "SAMPLE - General")).to be(true)
    end

    it "matches a protected title case- and whitespace-insensitively with no DB row (#118)" do
      expect(directory.authorized?(adapter: "telegram", account: "telegram", external_id: "-100999999",
                                   title: "  SAM PLE lobby ")).to be(true)
      expect(directory.authorized?(adapter: "telegram", account: "telegram", external_id: "-100999999",
                                   title: "examplegamingcommunity pt")).to be(true)
    end

    it "still authorizes a STOPPED community's space (stop is not leave)" do
      # The platform_connections mapping survives suspension, so the bot stays.
      models.community.first.update(status: "suspended")
      expect(directory.authorized?(adapter: connection.adapter, account: connection.account,
                                   external_id: connection.external_id)).to be(true)
    end
  end

  describe Rubotty::ControlPlane::OnboardingRegistry do
    # The get_state/put_state surface the message map exposes, with expiry on read.
    let(:store) do
      Class.new do
        def initialize = @h = {}
        def get_state(key)
          row = @h[key]
          return nil if row.nil?
          return nil if row[:expires_at] && row[:expires_at] <= Time.now

          row[:value]
        end
        def put_state(key, value, expires_at: nil) = @h[key] = { value: value, expires_at: expires_at }
      end.new
    end

    subject(:registry) { described_class.new(store: store) }

    it "reports an onboarding as in progress once begun" do
      registry.begin!(adapter: "discord", account: "discord", external_id: "42")
      expect(registry.in_progress?(adapter: "discord", account: "discord", external_id: "42")).to be(true)
    end

    it "reports no onboarding for a space that was never begun" do
      expect(registry.in_progress?(adapter: "discord", account: "discord", external_id: "99")).to be(false)
    end

    it "clears the marker on complete!" do
      registry.begin!(adapter: "discord", account: "discord", external_id: "42")
      registry.complete!(adapter: "discord", account: "discord", external_id: "42")
      expect(registry.in_progress?(adapter: "discord", account: "discord", external_id: "42")).to be(false)
    end

    it "lets an abandoned marker lapse so the bot is no longer pinned in the space" do
      past = Time.now - 100
      registry = described_class.new(store: store, ttl: 10, clock: -> { past })
      registry.begin!(adapter: "discord", account: "discord", external_id: "42")
      # Reading now (real time) is past the marker's expiry.
      expect(registry.in_progress?(adapter: "discord", account: "discord", external_id: "42")).to be(false)
    end
  end

  describe Rubotty::ControlPlane::JoinGuard do
    let(:authorization) { Rubotty::ControlPlane::AuthorizationDirectory.new(models: models) }

    subject(:guard) do
      described_class.new(authorization: authorization, onboarding: onboarding, logger: Rubotty::Log.null)
    end

    let(:onboarding) { nil }

    def evaluate(adapter:, account:, external_id:, title: nil)
      guard.on_join(adapter: adapter, account: account, external_id: external_id, title: title)
    end

    it "stays in an authorized space and names the community" do
      decision = evaluate(adapter: connection.adapter, account: connection.account,
                          external_id: connection.external_id)
      expect(decision.stay?).to be(true)
      expect(decision.community&.id).to eq(models.community.first.id)
    end

    it "leaves an unauthorized space with the private-bot notice" do
      decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999")
      expect(decision.leave?).to be(true)
      expect(decision.notice).to match(/private bot/i)
    end

    it "leaves an unmapped space whose title is unrelated (#118 does not over-reach)" do
      decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999",
                          title: "Random Public Group")
      expect(decision.leave?).to be(true)
    end

    it "STAYS in an unmapped space whose title is on the deployment-configured whitelist (#118)" do
      # No row and no onboarding, so the protected title alone forces STAY.
      decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999",
                          title: "SAMPLE - General")
      expect(decision.stay?).to be(true)
    end

    # The whitelist says the bot may never walk out of the space. It says nothing
    # about who the space belongs to, so an operator still has to see it.
    it "asks for a review of an unmapped whitelisted space while staying in it" do
      decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999",
                          title: "SAMPLE - General")
      expect(decision.stay?).to be(true)
      expect(decision.review?).to be(true)
    end

    it "asks for no review of a space a platform connection already maps" do
      decision = evaluate(adapter: connection.adapter, account: connection.account,
                          external_id: connection.external_id, title: "SAMPLE - General")
      expect(decision.stay?).to be(true)
      expect(decision.review?).to be(false)
    end

    it "asks for no review of a space it is leaving anyway" do
      decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999")
      expect(decision.leave?).to be(true)
      expect(decision.review?).to be(false)
    end

    it "STAYS by title for each protected pattern with no DB row (#118)" do
      ["sample lounge", "example gaming community pt", "Example Travel", "the SECOND crew"].each do |title|
        decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999", title: title)
        expect(decision.stay?).to be(true), "expected STAY for protected title #{title.inspect}"
      end
    end

    context "when the deployment protection file is missing" do
      let(:authorization) do
        Rubotty::ControlPlane::AuthorizationDirectory.new(
          models: models,
          protected_communities: Rubotty::ControlPlane::ProtectedCommunities.from_file("/no/such/file.yml")
        )
      end

      it "does not grant access based on an unconfigured title" do
        decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999",
                            title: "sample - general")
        expect(decision.stay?).to be(false)
      end
    end

    context "with an onboarding in progress for the unmapped space" do
      let(:onboarding) do
        instance_double(Rubotty::ControlPlane::OnboardingRegistry).tap do |double|
          allow(double).to receive(:in_progress?).and_return(true)
        end
      end

      it "stays so auto-leave does not race the operator's onboarding" do
        decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999")
        expect(decision.stay?).to be(true)
      end

      it "asks for no review, since the operator is already looking at the space" do
        decision = evaluate(adapter: "telegram", account: "telegram", external_id: "-100999999")
        expect(decision.review?).to be(false)
      end
    end

    it "uses a custom notice when configured" do
      guard = described_class.new(authorization: authorization, notice: "go away", logger: Rubotty::Log.null)
      decision = guard.on_join(adapter: "telegram", account: "telegram", external_id: "-100999999")
      expect(decision.notice).to eq("go away")
    end

    # Every decision carries the signal, stay or leave, so a pending-approval flow
    # reads one shape for both platforms.
    describe "the normalized join signal (#169)" do
      let(:inviter) { Rubotty::Core::Author.new(native_id: "77", first_name: "Rando") }

      it "attaches the signal to a STAY decision" do
        decision = evaluate(adapter: connection.adapter, account: connection.account,
                            external_id: connection.external_id)
        expect(decision.signal).to be_a(Rubotty::ControlPlane::SpaceJoinSignal)
        expect(decision.signal.adapter).to eq(connection.adapter.to_sym)
        expect(decision.signal.external_id).to eq(connection.external_id)
      end

      it "carries the inviter, title, and channel sample through to a LEAVE decision" do
        decision = guard.on_join(adapter: "discord", account: "discord", external_id: "999",
                                 title: "Rando Server", inviter: inviter,
                                 channel_sample: %w[general off-topic])
        expect(decision.leave?).to be(true)
        expect(decision.signal.inviter).to eq(inviter)
        expect(decision.signal.title).to eq("Rando Server")
        expect(decision.signal.channel_sample).to eq(%w[general off-topic])
      end

      it "caps the channel sample at SpaceJoinSignal::SAMPLE_LIMIT" do
        many = (1..20).map { |n| "chan-#{n}" }
        decision = guard.on_join(adapter: "discord", account: "discord", external_id: "999", channel_sample: many)
        expect(decision.signal.channel_sample.size).to eq(Rubotty::ControlPlane::SpaceJoinSignal::SAMPLE_LIMIT)
      end
    end

    # The "cannot leave" notice posts at most once per space, so a bot with no
    # self-removal permission does not spam its own departure notice.
    describe "#record_leave_failure" do
      it "returns true the first time a space is reported stuck" do
        expect(guard.record_leave_failure(adapter: "discord", account: "discord", external_id: "999")).to be(true)
      end

      it "returns false on every later call for the same space" do
        guard.record_leave_failure(adapter: "discord", account: "discord", external_id: "999")
        expect(guard.record_leave_failure(adapter: "discord", account: "discord", external_id: "999")).to be(false)
      end

      it "tracks each space independently" do
        guard.record_leave_failure(adapter: "discord", account: "discord", external_id: "999")
        expect(guard.record_leave_failure(adapter: "discord", account: "discord", external_id: "111")).to be(true)
      end
    end
  end

  describe Rubotty::ControlPlane::SpaceJoinSignal do
    it "normalizes a blank title to nil and keeps the fields it was given" do
      signal = described_class.new(adapter: :telegram, account: "tg", external_id: "-100", title: "   ")
      expect(signal.title).to be_nil
      expect(signal.channel_sample).to eq([])
      expect(signal.inviter).to be_nil
    end

    it "drops blank channel names and caps the sample" do
      signal = described_class.new(adapter: :discord, account: "dc", external_id: "1",
                                   channel_sample: ["general", "", nil, "off-topic"])
      expect(signal.channel_sample).to eq(%w[general off-topic])
    end
  end

  describe Rubotty::ControlPlane::InertNotices do
    it "remembers a posted notice in memory when no store is given" do
      notices = described_class.new
      expect(notices.posted?(adapter: "discord", account: "dc", external_id: "1")).to be(false)
      notices.mark_posted!(adapter: "discord", account: "dc", external_id: "1")
      expect(notices.posted?(adapter: "discord", account: "dc", external_id: "1")).to be(true)
    end

    it "persists through a key/value store when one is given" do
      store = Class.new do
        def initialize = @h = {}
        def get_state(key) = @h[key]
        def put_state(key, value, expires_at: nil) = @h[key] = value
      end.new
      notices = described_class.new(store: store)

      notices.mark_posted!(adapter: "telegram", account: "tg", external_id: "-100")
      # A second instance over the same store sees the marker, so it survives a restart.
      reloaded = described_class.new(store: store)
      expect(reloaded.posted?(adapter: "telegram", account: "tg", external_id: "-100")).to be(true)
    end
  end
end
