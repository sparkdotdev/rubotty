# frozen_string_literal: true

require "spec_helper"

# A best-effort DM, on whichever platform has seen the deployment-configured owner-level
# operator speak before.
RSpec.describe Rubotty::ControlPlane::AdminNotifier, :control_plane do
  def fake_dm_adapter(can_dm: true)
    Class.new do
      attr_reader :dms

      define_method(:initialize) { @dms = [] }
      define_method(:supports_admin_dm?) { can_dm }
      define_method(:send_admin_dm) do |native_id, text|
        @dms << { native_id: native_id, text: text }
        true
      end
    end.new
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }

  let(:protected_operators) do
    Rubotty::Security::ProtectedOperators.new(usernames: ["owner_handle"], matrix_ids: [])
  end

  def observe(adapter:, native_id:, username:, last_seen_at:)
    models.observed_identity.create(
      community_id: community.id, adapter: adapter, native_id: native_id, username: username,
      display_name: username, first_seen_at: last_seen_at, last_seen_at: last_seen_at
    )
  end

  it "DMs the protected operator's most recently seen identity on a reachable adapter" do
    observe(adapter: "telegram", native_id: "42", username: "owner_handle", last_seen_at: Time.now - 60)
    telegram = fake_dm_adapter
    notifier = described_class.new(
      models: models, adapters: { [:telegram, "telegram"] => telegram }, protected_operators: protected_operators
    )

    sent = notifier.notify!("New pending community")
    expect(sent).to eq(1)
    expect(telegram.dms.first[:native_id]).to eq("42")
    expect(telegram.dms.first[:text]).to eq("New pending community")
  end

  it "reaches the administrator on every platform they have been seen on, not just one" do
    observe(adapter: "telegram", native_id: "42", username: "owner_handle", last_seen_at: Time.now)
    observe(adapter: "discord", native_id: "77", username: "owner_handle", last_seen_at: Time.now)
    telegram = fake_dm_adapter
    discord = fake_dm_adapter
    notifier = described_class.new(
      models: models, adapters: { [:telegram, "telegram"] => telegram, [:discord, "discord"] => discord },
      protected_operators: protected_operators
    )

    expect(notifier.notify!("hello")).to eq(2)
    expect(telegram.dms.size).to eq(1)
    expect(discord.dms.size).to eq(1)
  end

  it "prefers the most recently seen identity when the same person has several sightings" do
    observe(adapter: "telegram", native_id: "old-id", username: "owner_handle", last_seen_at: Time.now - 3600)
    observe(adapter: "telegram", native_id: "new-id", username: "owner_handle", last_seen_at: Time.now)
    telegram = fake_dm_adapter
    notifier = described_class.new(
      models: models, adapters: { [:telegram, "telegram"] => telegram }, protected_operators: protected_operators
    )

    notifier.notify!("hi")
    expect(telegram.dms.first[:native_id]).to eq("new-id")
  end

  it "never DMs someone who is not a protected operator" do
    observe(adapter: "telegram", native_id: "99", username: "random_user", last_seen_at: Time.now)
    telegram = fake_dm_adapter
    notifier = described_class.new(
      models: models, adapters: { [:telegram, "telegram"] => telegram }, protected_operators: protected_operators
    )

    expect(notifier.notify!("hi")).to eq(0)
    expect(telegram.dms).to be_empty
  end

  it "skips an adapter that cannot DM at all, without raising" do
    observe(adapter: "telegram", native_id: "42", username: "owner_handle", last_seen_at: Time.now)
    telegram = fake_dm_adapter(can_dm: false)
    notifier = described_class.new(
      models: models, adapters: { [:telegram, "telegram"] => telegram }, protected_operators: protected_operators
    )

    expect(notifier.notify!("hi")).to eq(0)
  end

  it "is a no-op with no sighting of the administrator anywhere, and never raises" do
    notifier = described_class.new(models: models, adapters: {}, protected_operators: protected_operators)
    expect(notifier.notify!("hi")).to eq(0)
  end

  it "is a no-op for blank text" do
    telegram = fake_dm_adapter
    notifier = described_class.new(
      models: models, adapters: { [:telegram, "telegram"] => telegram }, protected_operators: protected_operators
    )
    expect(notifier.notify!("  ")).to eq(0)
    expect(telegram.dms).to be_empty
  end

  # The community-scoped audience, which a loud script alert uses.
  describe "#notify_operators!" do
    let(:telegram) { fake_dm_adapter }
    let(:discord) { fake_dm_adapter }
    let(:adapters) { { [:telegram, "telegram"] => telegram, [:discord, "discord"] => discord } }
    let(:notifier) { described_class.new(models: models, adapters: adapters, logger: Rubotty::Log.null) }
    # A floor that stands over somebody else's deployment, for the cases that
    # need this community to have no operator of any kind.
    let(:nobody_protected) do
      Rubotty::Security::ProtectedOperators.new(usernames: ["someone_else"], matrix_ids: [])
    end

    # One copy in a room everybody reads beats the same text delivered five
    # times, and it reaches an operator the bot cannot open a DM with at all.
    describe "a community that nominated an alert room" do
      let(:room_endpoint) { endpoint("tg-admins", adapter: :telegram, account: "telegram") }
      let(:posting) do
        Class.new do
          attr_reader :posts

          def initialize = @posts = []

          def deliver(message, endpoint)
            @posts << { text: message.body.text, endpoint: endpoint.id }
            Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "1")
          end
        end.new
      end
      let(:snapshot) do
        room = Rubotty::Core::Room.new(id: "admins", endpoints: [room_endpoint])
        scoped = instance_double(
          Rubotty::ControlPlane::Snapshot::Community,
          id: community.id, slug: "sample", rooms: [room],
          feature_config: { Rubotty::ControlPlane::AdminNotifier::ALERT_ROOM_FIELD => "admins" }
        )
        instance_double(Rubotty::ControlPlane::Snapshot, community_by_id: scoped)
      end
      let(:registry) { instance_double(Rubotty::ControlPlane::Registry, current: snapshot) }
      let(:roomed) do
        described_class.new(models: models, adapters: adapters.merge([:telegram, "telegram"] => posting),
                            logger: Rubotty::Log.null, registry: registry)
      end

      it "posts one copy into the room and DMs nobody" do
        delivery = roomed.notify_operators!(community_id: community.id, text: "a slur in general")

        expect(posting.posts.map { |post| post[:text] }).to eq(["a slur in general"])
        expect(delivery.reached).to eq(1)
        expect(telegram.dms).to be_empty
      end

      # An alert nobody hears is the failure the audit trail exists to record,
      # so a room that cannot be posted to must not swallow one.
      it "falls back to DMs when the room refuses the post" do
        refusing = Class.new do
          def deliver(_message, _endpoint) = raise(StandardError, "no permission to post")
        end.new
        fallback = described_class.new(
          models: models, adapters: adapters.merge([:telegram, "telegram"] => refusing),
          logger: Rubotty::Log.null, registry: registry
        )

        expect(fallback.notify_operators!(community_id: community.id, text: "hi").reached).to be_positive
        expect(discord.dms.size).to eq(1)
      end

      it "falls back to DMs when the named room no longer exists" do
        gone = instance_double(
          Rubotty::ControlPlane::Snapshot::Community,
          id: community.id, slug: "sample", rooms: [],
          feature_config: { Rubotty::ControlPlane::AdminNotifier::ALERT_ROOM_FIELD => "admins" }
        )
        elsewhere = described_class.new(
          models: models, adapters: adapters, logger: Rubotty::Log.null,
          registry: instance_double(Rubotty::ControlPlane::Registry,
                                    current: instance_double(Rubotty::ControlPlane::Snapshot,
                                                             community_by_id: gone))
        )

        expect(elsewhere.notify_operators!(community_id: community.id, text: "hi").reached).to eq(2)
      end
    end

    it "DMs this community's operator on every platform they are linked on" do
      expect(notifier.notify_operators!(community_id: community.id, text: "a slur in general").reached).to eq(2)
      expect(telegram.dms.first[:text]).to eq("a slur in general")
      expect(discord.dms.size).to eq(1)
    end

    # An alert raised in one community must never reach another's operators.
    it "never DMs the operators of another community" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)

      expect(notifier.notify_operators!(community_id: other.id, text: "hi").reached).to eq(0)
      expect(telegram.dms).to be_empty
    end

    it "DMs one person once per platform, however many handles they carry there" do
      operator = models.operator.first
      models.person_identity.create(person_id: operator.person_id, adapter: "telegram",
                                    native_id: "80000012", username: "matt_again", created_at: Time.now)

      notifier.notify_operators!(community_id: community.id, text: "hi")
      expect(telegram.dms.size).to eq(1)
    end

    # A Telegram @mention carries a handle and no id, and a handle alone cannot
    # open a chat.
    it "skips an identity with no platform id to DM" do
      operator = models.operator.first
      models.person_identity.create(person_id: operator.person_id, adapter: "telegram",
                                    native_id: nil, username: "handle_only", created_at: Time.now)

      expect(notifier.notify_operators!(community_id: community.id, text: "hi").reached).to eq(2)
    end

    it "skips a platform whose adapter cannot open a DM, and still reaches the others" do
      quiet = fake_dm_adapter(can_dm: false)
      notifier = described_class.new(
        models: models, adapters: { [:telegram, "telegram"] => telegram, [:discord, "discord"] => quiet },
        logger: Rubotty::Log.null
      )

      expect(notifier.notify_operators!(community_id: community.id, text: "hi").reached).to eq(1)
    end

    # The caller has already written the alert down, so a platform throwing
    # costs the notice and nothing else.
    it "answers zero rather than raising when a send blows up" do
      allow(telegram).to receive(:send_admin_dm).and_raise(StandardError, "network gone")
      allow(discord).to receive(:send_admin_dm).and_raise(StandardError, "network gone")

      expect(notifier.notify_operators!(community_id: community.id, text: "hi").reached).to eq(0)
    end

    # The deployment-configured floor is owner-level in every community and the operators
    # screen lists it as such, but it holds no operator row anywhere, so
    # reading rows alone left it out of every alert. Live, that was four of
    # this deployment's six operators hearing nothing about a flagged message.
    describe "the deployment-configured floor" do
      it "reaches an owner who holds no operator row of their own" do
        models.operator.where(community_id: community.id).delete

        delivery = notifier.notify_operators!(community_id: community.id, text: "hi")
        expect(delivery.reached).to eq(1)
        expect(telegram.dms.first[:native_id]).to eq("80000012")
      end

      # A floor owner is granted by handle, so nothing links them to a person:
      # a sighting can be the only record of the account, which is the same
      # table #notify! resolves the administrator from.
      it "reaches an owner known only as a sighting" do
        observe(adapter: "telegram", native_id: "77123", username: "maintainer", last_seen_at: Time.now)

        notifier.notify_operators!(community_id: community.id, text: "hi")
        expect(telegram.dms.map { |dm| dm[:native_id] }).to contain_exactly("80000012", "77123")
      end

      it "counts an owner already holding a grant once, not twice" do
        expect(notifier.notify_operators!(community_id: community.id, text: "hi").audience).to eq(2)
        expect(telegram.dms.size).to eq(1)
      end

      it "never treats somebody the floor does not protect as an operator" do
        observe(adapter: "telegram", native_id: "77123", username: "random_user", last_seen_at: Time.now)
        models.operator.where(community_id: community.id).delete
        quiet = described_class.new(models: models, adapters: adapters, logger: Rubotty::Log.null,
                                    protected_operators: nobody_protected)

        delivery = quiet.notify_operators!(community_id: community.id, text: "hi")
        expect(delivery.nobody_to_tell?).to be(true)
        expect(telegram.dms).to be_empty
      end
    end

    it "is a no-op for blank text and for no community at all" do
      expect(notifier.notify_operators!(community_id: community.id, text: " ").reached).to eq(0)
      expect(notifier.notify_operators!(community_id: nil, text: "hi").reached).to eq(0)
    end

    # A bot cannot open a Telegram chat with somebody who has never opened one
    # with it, which is what happened live: the platform took the call, refused
    # the recipient, and the alert counted itself as delivered anyway.
    describe "a DM the platform will not deliver" do
      def logged(protected_operators: Rubotty::Security::ProtectedOperators.default)
        logs = StringIO.new
        loud = described_class.new(models: models, adapters: adapters, protected_operators: protected_operators,
                                   logger: Rubotty::Log.build(level: "info", io: logs))
        [loud.notify_operators!(community_id: community.id, text: "hi"), logs.string]
      end

      it "does not count a refusal toward the operators it reached" do
        allow(telegram).to receive(:send_admin_dm).and_return(nil)

        delivery, = logged
        expect(delivery.audience).to eq(2)
        expect(delivery.reached).to eq(1)
        expect(delivery.refused).to eq(1)
        expect(delivery.none?).to be(false)
      end

      it "says nobody was reached when every operator DM is refused" do
        allow(telegram).to receive(:send_admin_dm).and_return(nil)
        allow(discord).to receive(:send_admin_dm).and_return(nil)

        delivery, = logged
        expect(delivery.none?).to be(true)
        expect(delivery.nobody_to_tell?).to be(false)
        expect(delivery.refused).to eq(2)
      end

      # The adapters name the recipient and the platform's own words for it;
      # only this knows which community's alert went missing.
      it "names the recipient, the community and the reason itself, at warn" do
        allow(telegram).to receive(:send_admin_dm).and_return(nil)

        _, logs = logged
        expect(logs).to include("WARN")
        expect(logs).to include("admin notifier: no DM to telegram:")
        expect(logs).to include("for community #{community.id}")
        expect(logs).to include("the platform refused it")
      end

      # A log line is emptied by the next restart, and the first anybody hears
      # of a silently dropped operator should not be them asking why the bot
      # is quiet.
      it "remembers the refusal against the account, so the dashboard can show it" do
        allow(telegram).to receive(:send_admin_dm).and_return(nil)
        logged

        refused = models.person_identity.where(adapter: "telegram").exclude(dm_refused_at: nil).all
        expect(refused.map(&:native_id)).to include("80000012")
        expect(refused.first.dm_refused_reason).to eq("the platform refused it")
      end

      it "forgets it again the moment a DM to that account lands" do
        allow(telegram).to receive(:send_admin_dm).and_return(nil)
        logged
        allow(telegram).to receive(:send_admin_dm).and_return(true)
        logged

        expect(models.person_identity.exclude(dm_refused_at: nil).count).to eq(0)
      end

      # The whole point: one operator the platform will not take must not cost
      # the alert to every operator it would have taken.
      it "carries on to the rest of the audience after one refusal" do
        allow(telegram).to receive(:send_admin_dm).and_raise(StandardError, "chat not found")

        delivery, = logged
        expect(delivery.reached).to eq(1)
        expect(discord.dms.size).to eq(1)
      end

      # A platform with no DM at all says nothing about the recipient's own
      # account, so it is not held against them.
      it "does not blame the recipient for a platform this deployment cannot DM on" do
        quiet = fake_dm_adapter(can_dm: false)
        described_class.new(
          models: models, adapters: { [:telegram, "telegram"] => quiet }, logger: Rubotty::Log.null
        ).notify_operators!(community_id: community.id, text: "hi")

        expect(models.person_identity.exclude(dm_refused_at: nil).count).to eq(0)
      end

      it "counts a platform that cannot DM at all apart from one that refused a recipient" do
        quiet = fake_dm_adapter(can_dm: false)
        loud = described_class.new(
          models: models, adapters: { [:telegram, "telegram"] => telegram, [:discord, "discord"] => quiet },
          logger: Rubotty::Log.null
        )
        allow(telegram).to receive(:send_admin_dm).and_return(nil)

        delivery = loud.notify_operators!(community_id: community.id, text: "hi")
        expect(delivery.refused).to eq(1)
        expect(delivery.unreachable).to eq(1)
      end

      # The two ways an alert reaches nobody are different problems, and the
      # audience has to be genuinely empty to tell them apart. Deleting the
      # rows no longer does that on its own: the floor is owner-level in every
      # community and outlives them, so this narrows it off this deployment too.
      it "tells an empty audience apart from an audience that all refused" do
        models.operator.where(community_id: community.id).delete

        delivery, = logged(protected_operators: nobody_protected)
        expect(delivery.nobody_to_tell?).to be(true)
        expect(delivery.none?).to be(true)
        expect(delivery.refused).to eq(0)
      end
    end
  end
end

# The notifier gates on #supports_admin_dm? and nothing else, so this runs
# against the real adapter classes: a fake answering true proves nothing about
# the shipped code.
RSpec.describe Rubotty::ControlPlane::AdminNotifier, "which real adapters can be reached" do
  it "reaches an operator on Telegram" do
    expect(Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg", settings: { token: "t", token_env: "T" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).supports_admin_dm?).to be(true)
  end

  it "reaches an operator on Discord" do
    expect(Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "T" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).supports_admin_dm?).to be(true)
  end

  # Fluxer and Stoat joined Telegram and Discord: both are Discord shaped
  # enough that opening a DM channel and posting to it is the same two
  # calls their ordinary channel delivery already makes.
  it "reaches an operator on Fluxer" do
    expect(Rubotty::Adapters::Fluxer::Adapter.new(
      account: "fx", settings: { token: "t", token_env: "T" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).supports_admin_dm?).to be(true)
  end

  it "reaches an operator on Stoat" do
    expect(Rubotty::Adapters::Stoat::Adapter.new(
      account: "st", settings: { token: "t", token_env: "T" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).supports_admin_dm?).to be(true)
  end

  it "reaches an operator on Matrix" do
    expect(Rubotty::Adapters::Matrix::Adapter.new(
      account: "mx", settings: { token: "t", homeserver: "https://example.org" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).supports_admin_dm?).to be(true)
  end

  it "reaches an operator on IRC" do
    expect(Rubotty::Adapters::Irc::Adapter.new(
      account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).supports_admin_dm?).to be(true)
  end

  it "reaches an operator on XMPP" do
    expect(Rubotty::Adapters::Xmpp::Adapter.new(
      account: "xm", settings: { jid: "bot@example.org", password: "p" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).supports_admin_dm?).to be(true)
  end

  # A permanent DM (this one can never be deleted again) is a different
  # feature from the ephemeral one that class level flag gates. IRC is
  # excluded: deleting one rides draft/message-redaction, negotiated per
  # connection rather than a fact this static flag can honestly promise.
  it "can also delete a DM on every adapter whose delete is a static fact" do
    [Rubotty::Adapters::Telegram::Adapter, Rubotty::Adapters::Discord::Adapter,
     Rubotty::Adapters::Fluxer::Adapter, Rubotty::Adapters::Stoat::Adapter,
     Rubotty::Adapters::Matrix::Adapter, Rubotty::Adapters::Xmpp::Adapter].each do |klass|
      expect(klass.supports_admin_dm_delete?).to be(true)
    end
  end

  it "does not promise deleting an IRC DM, since the redaction capability is negotiated per connection" do
    expect(Rubotty::Adapters::Irc::Adapter.supports_admin_dm_delete?).to be(false)
  end
end
