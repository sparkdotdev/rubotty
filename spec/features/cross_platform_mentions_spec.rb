# frozen_string_literal: true

require "spec_helper"

# `@handle@platform` relays as a native ping on the named platform, resolved against the
# passively learned identity directory. Unknown handles stay plain text.
RSpec.describe "cross-platform @mentions through the bridge", :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }

  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:fx) { endpoint("fx", adapter: :fluxer, settings: { channel_id: "1" }) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: Hash.new(adapter), session_id: "test", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
    )
  end

  subject(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      identity_directory: directory,
      ephemeral: ephemeral
    )
  end

  # A bare control-plane community, enough to give a message a community id.
  let(:community_id) do
    stamp = Time.now
    db[:communities].insert(slug: "alpha", name: "ALPHA", status: "active",
                            settings: "{}", created_at: stamp, updated_at: stamp)
  end

  # The bridge only needs the community's id off the Context for the mention rewrite.
  let(:community) { Struct.new(:id).new(community_id) }

  before do
    directory.record(community_id: community_id, adapter: :discord, native_id: "900", username: "user2")
    directory.record(community_id: community_id, adapter: :discord, native_id: "901", username: "till6357")
    directory.record(community_id: community_id, adapter: :discord, native_id: "902", username: "extreme4476")
    directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
    directory.record(community_id: community_id, adapter: :fluxer, native_id: "700", username: "grace")
    # A handle two different Discord accounts both go by: genuinely ambiguous.
    directory.record(community_id: community_id, adapter: :discord, native_id: "301", username: "dup")
    directory.record(community_id: community_id, adapter: :discord, native_id: "302", username: "dup")
  end

  # Relay +text+ and return the body the bridge delivered. +enabled: false+ writes an
  # explicit false, since an absent key resolves to on.
  def relay(text, origin: tg, enabled: true)
    config = enabled ? {} : { cross_platform_mentions: false }
    context = Rubotty::Features::Context.new(
      message: message(origin, text: text), community: community, config: config
    )
    bridge.call(context)
    adapter.delivered.last.last.body
  end

  def discord_render(body) = Rubotty::Rendering::DiscordMarkdown.new.render(body)

  def telegram_render(body) = Rubotty::Rendering::TelegramHtml.new.render(body)

  def fluxer_render(body) = Rubotty::Adapters::Fluxer::Outbound.new.compose(message(fx, text: body), fx)

  def allowed_mentions(body, endpoint)
    Rubotty::Adapters::Discord::Outbound.new.allowed_mentions(message(endpoint, text: body), endpoint)
  end

  describe "resolving to a native ping on the named platform" do
    it "rewrites @handle@discord into a real Discord ping when relayed to Discord" do
      body = relay("hey @user2@discord", origin: tg)
      span = body.spans.find { |s| s.kind == :mention }
      expect(span.attributes[:discord_id_for_target]).to eq("900")
      expect(discord_render(body)).to eq("hey <@900>")
    end

    it "rewrites @handle@domain into a real ping when the target uses that domain" do
      allow(adapter).to receive(:origin_label).and_call_original
      allow(adapter).to receive(:origin_label).with(dc).and_return("chat.example.org")
      body = relay("hey @user2@chat.example.org", origin: tg)
      span = body.spans.find { |s| s.kind == :mention }
      expect(span.attributes[:discord_id_for_target]).to eq("900")
      expect(discord_render(body)).to eq("hey <@900>")
    end

    it "whitelists ONLY the resolved id, so Discord actually pings it" do
      body = relay("hey @user2@discord", origin: tg)
      expect(allowed_mentions(body, endpoint("d", adapter: :discord)))
        .to eq(parse: [], users: ["900"], roles: [])
    end

    it "resolves the reverse direction too: @handle@telegram pings on Telegram" do
      body = relay("hey @ada@telegram", origin: dc)
      span = body.spans.find { |s| s.kind == :mention }
      expect(span.attributes[:telegram_id_for_target]).to eq("111")
      # Ada has no nickname and no display name distinct from her handle, so
      # the link text is her bare identity on the target platform, not the
      # canonical token the author typed.
      expect(telegram_render(body)).to eq(%(hey <a href="tg://user?id=111">ada@telegram</a>))
    end

    it "reformats every mention in a message, not just the first, and leaves the text between them alone" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "222", username: "bob")

      body = relay("hey @ada@telegram and @bob@telegram", origin: dc)
      expect(telegram_render(body)).to eq(
        %(hey <a href="tg://user?id=111">ada@telegram</a> and <a href="tg://user?id=222">bob@telegram</a>)
      )
    end

    # Fluxer is Discord shaped and shares Discord's renderer, but it is its
    # own identity space in the router: this only passes if the id the
    # bridge resolves for a Fluxer target reaches Fluxer's own renderer,
    # rather than sitting under a key only the real Discord adapter reads.
    it "resolves a third direction: @handle@fluxer pings on Fluxer" do
      fluxer_bridge = Rubotty::Features::Bridge.new(
        topology: topology(room("fx-room", tg, fx)), adapters: Hash.new(adapter), storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
        identity_directory: directory
      )
      context = Rubotty::Features::Context.new(
        message: message(tg, text: "hey @grace@fluxer"), community: community, config: {}
      )
      fluxer_bridge.call(context)
      body = adapter.delivered.last.last.body

      span = body.spans.find { |s| s.kind == :mention }
      expect(span.attributes[:fluxer_id_for_target]).to eq("700")
      expect(fluxer_render(body)).to eq("hey <@700>")
    end
  end

  describe "resolving a bare fragment on the destination platform" do
    it "resolves a distinctive handle prefix" do
      body = relay("hey @till", origin: tg)

      expect(discord_render(body)).to eq("hey <@901>")
    end

    it "resolves a distinctive middle fragment without regard to case" do
      body = relay("hey @REME4", origin: tg)

      expect(discord_render(body)).to eq("hey <@902>")
    end

    it "keeps an exact handle ahead of longer handles containing it" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "903", username: "till")

      body = relay("hey @till", origin: tg)

      expect(discord_render(body)).to eq("hey <@903>")
    end

    it "does not let a bot carrying a copied handle make one person ambiguous" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "903", username: "alecxvs")
      recorder = Rubotty::ControlPlane::IdentityRecorder.new(directory: directory, logger: Rubotty::Log.null)
      recorder.record(message(dc, author: author(native_id: "hook", username: "alecxvs", bot: true)), community)

      body = relay("hey @alec", origin: tg)

      expect(discord_render(body)).to eq("hey <@903>")
      expect(adapter.delivered_to("tg")).to be_empty
    end

    it "leaves an ambiguous fragment as text" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "903", username: "stillhere")

      relay("hey @till", origin: tg)
      body = adapter.delivered_to("dc").last.body

      expect(body.spans.select { |span| span.kind == :mention }).to be_empty
      expect(discord_render(body)).to eq("hey @till")
      expect(adapter.delivered_to("tg").last.body.text)
        .to eq("@till matches 2 discord accounts. Tag one of these exactly to reach it: " \
               "@stillhere@discord, @till6357@discord")
    end

    it "only ever offers a tag that resolves to a single account" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "903", username: "stillhere")

      relay("hey @till", origin: tg)
      offered = adapter.delivered_to("tg").last.body.text.scan(Rubotty::Features::Bridge::CROSS_PLATFORM_MENTION)

      expect(offered).not_to be_empty
      offered.each_with_index do |(handle, platform), index|
        context = Rubotty::Features::Context.new(
          message: message(tg, text: "hey @#{handle}@#{platform}", native_id: "offered-#{index}"),
          community: community, config: {}
        )
        bridge.call(context)
        body = adapter.delivered_to("dc").last.body
        expect(body.spans.select { |span| span.kind == :mention }.size).to eq(1)
      end
    end

    it "offers no tag, and asks for none, when the candidates share one handle" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "401", username: "wrenzo")
      directory.record(community_id: community_id, adapter: :discord, native_id: "402", username: "wrenzo")

      relay("hey @wren", origin: tg)
      text = adapter.delivered_to("tg").last.body.text

      expect(text).to eq("@wren matches 2 discord accounts and no tag tells them apart, " \
                         "so I left it as the text you typed.")
    end

    it "offers no tag when the only candidates are labels a relay wrote" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "hook-1",
                       username: "wren okafor [wrenzo@telegram]")
      directory.record(community_id: community_id, adapter: :discord, native_id: "hook-2",
                       username: "wren okafor [wrenzo@telegram]")

      relay("hey @wren", origin: tg)
      text = adapter.delivered_to("tg").last.body.text

      expect(text).not_to include("[")
      expect(text).to include("no tag tells them apart")
    end

    it "leaves an unknown fragment as text" do
      body = relay("hey @nobody", origin: tg)

      expect(body.spans.select { |span| span.kind == :mention }).to be_empty
      expect(discord_render(body)).to eq("hey @nobody")
      expect(adapter.delivered_to("tg")).to be_empty
    end

    it "leaves a bare tag alone when this community has only one platform" do
      tg_two = endpoint("tg-two", adapter: :telegram)
      directory.record(community_id: community_id, adapter: :telegram, native_id: "222", username: "till6357")
      single_platform = Rubotty::Features::Bridge.new(
        topology: topology(room("telegram-only", tg, tg_two)), adapters: Hash.new(adapter), storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
        identity_directory: directory, ephemeral: ephemeral
      )
      context = Rubotty::Features::Context.new(
        message: message(tg, text: "hey @till"), community: community, config: {}
      )

      single_platform.call(context)

      body = adapter.delivered_to("tg-two").last.body
      expect(body.spans.select { |span| span.kind == :mention }).to be_empty
      expect(telegram_render(body)).to eq("hey @till")
      expect(adapter.delivered_to("tg")).to be_empty
    end
  end

  describe "staying plain text where a native ping is not warranted" do
    it "leaves @handle@discord as plain text when relayed to a non-Discord target" do
      body = relay("hey @user2@discord", origin: dc) # delivered to the Telegram endpoint
      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
      expect(telegram_render(body)).to eq("hey @user2@discord")
    end

    it "leaves an unresolved handle as plain text everywhere" do
      body = relay("hey @nobody@discord", origin: tg)
      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
      expect(discord_render(body)).to eq("hey @nobody@discord")
    end

    # A miss otherwise looks identical to the token never having been scanned
    # at all, which made a stuck mention impossible to tell apart from one
    # nobody ever typed.
    it "logs why an unresolved handle did not resolve, rather than failing silently" do
      logs = StringIO.new
      logged = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter),
        storage: storage, loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
        logger: Rubotty::Log.build(level: "debug", io: logs), identity_directory: directory
      )
      context = Rubotty::Features::Context.new(
        message: message(tg, text: "hey @nobody@discord"), community: community, config: {}
      )
      logged.call(context)

      expect(logs.string).to include("cross-platform mention miss")
      expect(logs.string).to include("nobody@discord")
    end

    it "leaves an ambiguous handle as plain text rather than guessing who to ping" do
      body = relay("hey @dup@discord", origin: tg)
      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
      expect(discord_render(body)).to eq("hey @dup@discord")
      expect(allowed_mentions(body, endpoint("d", adapter: :discord))[:users]).to eq([])
    end
  end

  describe "preserving the mention-injection safety (#48)" do
    it "never turns a spoofed @everyone@discord into a mass ping" do
      body = relay("@everyone@discord ping", origin: tg)
      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
      # parse: [] keeps Discord from resolving the literal @everyone in the text,
      # and nothing was resolved into the whitelist, so nobody is pinged.
      expect(allowed_mentions(body, endpoint("d", adapter: :discord)))
        .to eq(parse: [], users: [], roles: [])
    end

    it "never lets a raw-id token @123@discord ping: the handle, not an id, is the key" do
      body = relay("@900@discord @123@discord", origin: tg)
      # "900" is a real native id but nobody's handle, so it does not resolve.
      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
      expect(allowed_mentions(body, endpoint("d", adapter: :discord))[:users]).to eq([])
    end
  end

  describe "on by default" do
    it "resolves a mention when the per-scope setting is absent" do
      body = relay("hey @user2@discord", origin: tg)
      expect(body.spans.select { |s| s.kind == :mention }).not_to be_empty
      expect(discord_render(body)).to eq("hey <@900>")
    end

    it "does nothing without a resolved community, even with the setting on" do
      context = Rubotty::Features::Context.new(
        message: message(tg, text: "hey @user2@discord"),
        community: nil, config: { cross_platform_mentions: true }
      )
      bridge.call(context)
      body = adapter.delivered.last.last.body
      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
    end

    it "does nothing when no identity directory was injected" do
      plain = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter),
        storage: storage, loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
        logger: Rubotty::Log.null
      )
      context = Rubotty::Features::Context.new(
        message: message(tg, text: "hey @user2@discord"),
        community: community, config: { cross_platform_mentions: true }
      )
      plain.call(context)
      body = adapter.delivered.last.last.body
      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
    end
  end

  # Bug: the per-message mention scope used to be computed ONCE from the
  # ORIGIN message's config and reused for every fanned-out target, so
  # toggling cross_platform_mentions on a DESTINATION room's config had no
  # effect on whether a mention typed elsewhere resolved into it.
  describe "governed by the destination room's own setting, not the origin's", :control_plane do
    # tg is a hub member of BOTH rooms, so one message it sends fans out to
    # two destinations whose own settings differ. The origin's own config
    # (set to false, below) is irrelevant to either delivery.
    let(:dc_on) { endpoint("dc-on", adapter: :discord) }
    let(:dc_off) { endpoint("dc-off", adapter: :discord) }

    def hub_community
      channels = [tg, dc_on, dc_off].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: community_id, route_key: ep.id)
      end
      Rubotty::ControlPlane::Snapshot::Community.new(
        id: community_id, slug: "alpha", name: "ALPHA", status: "active", settings: {},
        topology: topology(room("r-on", tg, dc_on), room("r-off", tg, dc_off)),
        channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new,
        people: Rubotty::Core::Directory.new,
        feature_settings: [
          # The ORIGIN's own room setting, off: proves it is never consulted.
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            room_key: "r-off", feature: "bridge", enabled: true, config: { cross_platform_mentions: false }
          ),
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            room_key: "r-on", feature: "bridge", enabled: true, config: { cross_platform_mentions: true }
          )
        ]
      )
    end

    def hub_bridge
      Rubotty::Features::Bridge.new(
        topology: topology(room("r-on", tg, dc_on), room("r-off", tg, dc_off)),
        adapters: Hash.new(adapter), storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
        identity_directory: directory
      )
    end

    it "resolves into the room whose own setting is on and leaves the other room's copy plain" do
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [hub_community])
      community = snapshot.community_by_id(community_id)
      context = Rubotty::Features::Context.new(
        message: message(tg, text: "hey @user2@discord"), community: community, config: {}
      )
      hub_bridge.call(context)

      delivered = adapter.delivered.to_h
      on_body = delivered.fetch("dc-on").body
      off_body = delivered.fetch("dc-off").body

      expect(on_body.spans.select { |s| s.kind == :mention }).not_to be_empty
      expect(discord_render(on_body)).to eq("hey <@900>")
      expect(off_body.spans.select { |s| s.kind == :mention }).to be_empty
      expect(discord_render(off_body)).to eq("hey @user2@discord")
    end
  end

  # A bridged nickname lives in this directory alongside real handles, so a
  # mention addressed to it resolves to the person's real account on whichever
  # platform the message is landing on.
  describe "a nickname somebody chose to be bridged as" do
    let(:nicknames) { Rubotty::ControlPlane::BridgedNicknames.new(models: models) }

    # Ada is @ada on Telegram and asked to show up as owner on Discord.
    let!(:ada) do
      person = nicknames.person_for(community_id: community_id, adapter: "telegram",
                                    native_id: "111", username: "ada")
      nicknames.set(community_id: community_id, person_id: person.id, adapter: "discord", nickname: "owner")
      person
    end

    it "pings her real Telegram account when @owner@telegram is relayed there" do
      body = relay("hey @owner@telegram", origin: dc)

      span = body.spans.find { |s| s.kind == :mention }
      expect(span.attributes[:telegram_id_for_target]).to eq("111")
    end

    it "shows her own nickname on the target platform in the mention text, when she has one there too" do
      nicknames.set(community_id: community_id, person_id: ada.id, adapter: "telegram", nickname: "adalovelace")

      body = relay("hey @owner@telegram", origin: dc)

      # Nickname leads, her real Telegram handle follows in brackets: the
      # format Core::SenderLabel#render specifies.
      expect(telegram_render(body)).to eq(%(hey <a href="tg://user?id=111">adalovelace [ada@telegram]</a>))
    end

    it "resolves it however it is capitalised" do
      body = relay("hey @owner@telegram", origin: dc)

      expect(body.spans.find { |s| s.kind == :mention }&.attributes&.dig(:telegram_id_for_target)).to eq("111")
    end

    it "leaves a real handle winning over a nickname, so nobody is shadowed" do
      other = nicknames.person_for(community_id: community_id, adapter: "discord",
                                   native_id: "900", username: "user2")
      nicknames.set(community_id: community_id, person_id: other.id, adapter: "telegram", nickname: "ada")

      body = relay("hey @ada@telegram", origin: dc)

      # The observed identity, not the person who claimed "ada" as a nickname.
      expect(body.spans.find { |s| s.kind == :mention }.attributes[:telegram_id_for_target]).to eq("111")
    end

    it "stays plain text on a platform she has no account on" do
      body = relay("hey @owner@discord", origin: tg)

      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
    end

    it "stops resolving once it is cleared" do
      nicknames.clear(community_id: community_id, person_id: ada.id, adapter: "discord")

      body = relay("hey @owner@telegram", origin: dc)

      expect(body.spans.select { |s| s.kind == :mention }).to be_empty
    end
  end
end
