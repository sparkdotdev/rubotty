# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Link filter URL authorities" do
  it "applies domain rules to the actual host after userinfo" do
    verdict = Rubotty::Features::LinkFilter.verdict_for(
      "https://trusted.example:443@blocked.example/payload",
      posture: "block_all", whitelist: ["trusted.example"], blacklist: ["blocked.example"]
    )

    expect(verdict).to eq("blocked")
  end

  it "cannot hide a blacklisted host behind a username and password" do
    verdict = Rubotty::Features::LinkFilter.verdict_for(
      "https://innocent:password@blocked.example/payload",
      posture: "allow_all", blacklist: ["blocked.example"]
    )

    expect(verdict).to eq("blocked")
  end

  it "retains bare domain, www, scheme and port normalization" do
    verdict = Rubotty::Features::LinkFilter.verdict_for(
      "HTTPS://WWW.TRUSTED.EXAMPLE:8443/path",
      posture: "block_all", whitelist: ["trusted.example/path"]
    )

    expect(verdict).to eq("clean")
  end
end

RSpec.describe Rubotty::Features::LinkFilter do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  def filter(ephemeral: nil, cleanup: nil, warnings: nil, audit: nil)
    described_class.new(
      topology: topology(room("r", tg, dc)),
      adapters: adapters,
      storage: storage,
      logger: Rubotty::Log.null,
      ephemeral: ephemeral,
      cleanup: cleanup,
      warnings: warnings,
      audit: audit
    )
  end

  def context(message, config: {}, operators: nil, attachment_text: nil)
    Rubotty::Features::Context.new(
      message: message, config: config, operators: operators, attachment_text: attachment_text
    )
  end

  def msg(body, native_id: "1", kind: :chat, **rest)
    message(tg, text: body, native_id: native_id, kind: kind, **rest)
  end

  # Whether +body+ (text or RichText) is blocked under +config+.
  def blocks?(body, config)
    filter.call(context(msg(body), config: config)).halt?
  end

  describe "the feature contract" do
    it "names itself, is off by default, and observes chat and edit" do
      expect(described_class.feature_name).to eq("link_filter")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat edit])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "is inert when the posture allows everything and there is no blacklist" do
      outcome = filter.call(context(msg("visit https://discord.gg/abcd now"), config: { posture: "allow_all" }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "does not act on a message with no links" do
      expect(blocks?("just a normal chat message", { posture: "block_all" })).to be(false)
    end
  end

  describe "the block_invites posture (default)" do
    it "blocks a Discord invite link" do
      expect(blocks?("come to https://discord.gg/abcd", {})).to be(true)
    end

    it "blocks a bare Discord invite with no scheme" do
      expect(blocks?("join discord.gg/abcd now", {})).to be(true)
    end

    it "blocks a Telegram group / channel link" do
      expect(blocks?("see https://t.me/somechannel", {})).to be(true)
      expect(blocks?("t.me/joinchat/AAAA", {})).to be(true)
    end

    # A permalink is not a way into anywhere. t.me/c/<chat>/<message> resolves
    # only for somebody already in that chat, and it is what an operator pastes
    # when quoting a message, so this deleted moderators quoting their own
    # community to each other, and would delete the bot's own alert links.
    it "leaves a link to one message alone, on a private chat or a public one" do
      expect(blocks?("see https://t.me/c/8000000003/1098 for context", {})).to be(false)
      expect(blocks?("https://t.me/c/8000000002/7044/12848", {})).to be(false)
      expect(blocks?("look at https://t.me/durov/123", {})).to be(false)
    end

    it "leaves a web preview link alone, which joins nothing either" do
      expect(blocks?("https://t.me/s/durov", {})).to be(false)
    end

    # The whole link decides, not its first path segment: unanchored, the match
    # came back on "https://t.me/c" out of the front of every permalink.
    it "still blocks the invite forms a permalink is told apart from" do
      expect(blocks?("https://t.me/joinchat/AAAAAEabcdef", {})).to be(true)
      expect(blocks?("https://t.me/+AbCdEfGh", {})).to be(true)
      expect(blocks?("https://t.me/somechannel", {})).to be(true)
      expect(blocks?("https://t.me/somechannel/", {})).to be(true)
    end

    it "is not fooled by an invite shape sitting in another host's path" do
      expect(blocks?("https://example.com/t.me/evil", {})).to be(false)
    end

    it "blocks a WhatsApp group invite link (issue #115, critical for TRAVEL)" do
      expect(blocks?("join us https://chat.whatsapp.com/ABCdef123GHIjkl456MNo", {})).to be(true)
    end

    it "blocks a bare WhatsApp invite with no scheme" do
      expect(blocks?("here: chat.whatsapp.com/ABCdef123GHIjkl456MNo", {})).to be(true)
    end

    it "blocks a WhatsApp invite hidden behind Markdown display text" do
      body = rich("click here", span(:link, 0, 10, url: "https://chat.whatsapp.com/ABCdef123GHIjkl456MNo"))
      expect(filter.call(context(msg(body, native_id: "7"), config: {})).halt?).to be(true)
    end

    it "does not mistake the plain whatsapp.com marketing site for an invite" do
      # Only chat.whatsapp.com is an invite host; the marketing domain is an ordinary link.
      expect(blocks?("read https://www.whatsapp.com/features", {})).to be(false)
    end

    it "allows an ordinary non-invite link" do
      expect(blocks?("watch https://www.youtube.com/watch?v=x", {})).to be(false)
    end
  end

  describe "the block_all posture (whitelist-only)" do
    it "blocks any link that is not whitelisted" do
      expect(blocks?("read https://example.com/article", { posture: "block_all" })).to be(true)
    end

    it "allows an whitelisted domain, and its subdomains" do
      config = { posture: "block_all", whitelist: %w[youtube.com] }
      expect(blocks?("https://www.youtube.com/watch?v=x", config)).to be(false)
      expect(blocks?("https://cdn.youtube.com/a", config)).to be(false)
      expect(blocks?("https://example.com/a", config)).to be(true)
    end
  end

  describe "the allow_all posture" do
    it "still blocks a blacklisted domain, punctuation and all" do
      config = { posture: "allow_all", blacklist: %w[evil.example] }
      expect(blocks?("scam at (https://evil.example).", config)).to be(true)
      expect(blocks?("fine https://good.example/x", config)).to be(false)
    end
  end

  describe "precedence" do
    it "blacklist wins over whitelist for the same host" do
      config = { posture: "block_all", whitelist: %w[shady.example], blacklist: %w[shady.example] }
      expect(blocks?("https://shady.example/x", config)).to be(true)
    end
  end

  describe "links carried as :link spans" do
    it "catches a blacklisted URL hidden behind Markdown display text" do
      body = rich("click here", span(:link, 0, 10, url: "https://evil.example/phish"))
      outcome = filter.call(context(msg(body, native_id: "7"), config: { posture: "allow_all", blacklist: %w[evil.example] }))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 7]])
    end
  end

  describe "the delete action" do
    it "removes the message and its relayed cross-platform copies" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      edit = msg("https://discord.gg/raid", native_id: "5", kind: :edit)
      outcome = filter.call(context(edit, config: {}))
      expect(outcome).to be_halt
      expect(adapter.deleted).to contain_exactly(%w[tg 5], %w[dc d1])
    end

    it "posts the standard self-deleting @mention removal notice through the shared flow" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = filter(ephemeral: ephemeral, cleanup: cleanup)
      subject.call(context(msg("https://discord.gg/x", native_id: "5", author: author(native_id: "u9", first_name: "Ada")),
                           config: { removal_notice_ttl_seconds: 30 }))
      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq("Ada Your last message was automatically removed: Sharing invitation links to other communities is not allowed.")
      mention = notice.body.spans.find { |s| s.kind == :mention }
      expect(mention.attributes).to eq(fake_id_for_target: "u9")
      expect(cleanup).to have_received(:after).with(30)
    end

    it "honours a per-scope removal_reason override in the notice" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = filter(ephemeral: ephemeral, cleanup: cleanup)
      subject.call(context(msg("https://discord.gg/x", native_id: "5"),
                           config: { removal_reason: "Keep invites out of here" }))
      expect(adapter.delivered_to("tg").last.body.text)
        .to eq("Ada Your last message was automatically removed: Keep invites out of here.")
    end
  end

  describe "the flag action" do
    it "leaves the message in place and continues" do
      outcome = filter.call(context(msg("https://discord.gg/x"), config: { action: "flag" }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "audit logging" do
    let(:recorder) do
      Class.new do
        attr_reader :events

        def initialize = @events = []

        def record(**kwargs)
          @events << kwargs
          kwargs
        end
      end.new
    end

    def community
      instance_double(
        Rubotty::ControlPlane::Snapshot::Community,
        slug: "acme", operators: Rubotty::Core::Moderation::Directory.new
      )
    end

    it "records a blocked invite as a structured event, keyed to this source and the author" do
      ctx = Rubotty::Features::Context.new(
        message: msg("https://chat.whatsapp.com/ABCdef123GHIjkl456MNo", native_id: "5",
                     author: author(native_id: "u9", username: "poacher")),
        community: community, config: {}
      )
      filter(audit: recorder).call(ctx)
      event = recorder.events.last
      expect(event).to include(source: "link_filter", action: "delete", community: "acme", subject_native_id: "u9")
      expect(event[:reason]).to eq("Sharing invitation links to other communities is not allowed.")
      expect(event[:metadata]).to include(link: "https://chat.whatsapp.com/ABCdef123GHIjkl456MNo")
    end
  end

  describe "warn and mute routing to the warnings service (#46)" do
    let(:warnings) { instance_spy(Rubotty::Core::Warnings::Service) }
    let(:offender) { author(native_id: "u9", username: "spammer") }

    it "warns the author on a warn action, still containing the message" do
      subject = filter(warnings: warnings)
      outcome = subject.call(
        context(msg("https://discord.gg/x", native_id: "5", author: offender), config: { action: "warn" })
      )
      expect(warnings).to have_received(:warn).with(hash_including(subject: offender, issued_by: "link filter"))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "mutes the author on a mute action for the configured duration" do
      subject = filter(warnings: warnings)
      subject.call(
        context(msg("https://discord.gg/x", author: offender),
                config: { action: "mute", mute_duration: "2h", stub_action: "flag" })
      )
      expect(warnings).to have_received(:sanction)
        .with(hash_including(subject: offender, action: :mute, duration: 7200, issued_by: "link filter"))
    end

    it "passes the community's configured max and decay alongside a warn" do
      subject = filter(warnings: warnings)
      community = instance_double(Rubotty::ControlPlane::Snapshot::Community,
                                  feature_config: { max: 3, expires_after: "30d" }, operators: nil, slug: "sample")
      ctx = Rubotty::Features::Context.new(
        message: msg("https://discord.gg/x", author: offender), community: community, config: { action: "warn" }
      )
      subject.call(ctx)
      expect(warnings).to have_received(:warn).with(hash_including(max: 3, expire_after: 2_592_000))
    end

    it "does not escalate a delete action" do
      subject = filter(warnings: warnings)
      subject.call(context(msg("https://discord.gg/x", author: offender), config: { action: "delete" }))
      expect(warnings).not_to have_received(:warn)
      expect(warnings).not_to have_received(:sanction)
    end
  end

  describe "operator exemption" do
    let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "op", identities: { fake: ["op1"] }) }
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }

    it "exempts operators by default" do
      outcome = filter.call(
        context(msg("https://discord.gg/x", author: author(native_id: "op1")), config: {}, operators: directory)
      )
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "still filters a non-operator" do
      outcome = filter.call(
        context(msg("https://discord.gg/x", native_id: "9", author: author(native_id: "u2")),
                config: {}, operators: directory)
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end

    # No community resolved means no directory, so the operator is filtered
    # rather than exempted out of the merged deployment-wide view.
    it "filters an operator whose community did not resolve" do
      outcome = filter.call(
        context(msg("https://discord.gg/x", native_id: "9", author: author(native_id: "op1")), config: {})
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end
  end

  describe "per-community and per-room enablement", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }

    def setting(enabled:, room_key: nil, config: {})
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: "link_filter", enabled: enabled, config: config
      )
    end

    def pipeline_for(feature_settings)
      channels = [ep_a, ep_b].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("a", ep_a), room("b", ep_b)]),
        channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new,
        people: Rubotty::Core::Directory.new,
        feature_settings: feature_settings
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      registry = instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
      Rubotty::Features::Pipeline.new(features: [filter], registry: registry)
    end

    it "runs where a community-default row enables it" do
      pipeline = pipeline_for([setting(enabled: true, config: { posture: "block_invites" })])
      pipeline.handle(message(ep_a, text: "https://discord.gg/x", native_id: "5"))
      expect(adapter.deleted).to eq([%w[ch-a 5]])
    end

    it "does not run where a per-room row overrides the community default off" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { posture: "block_invites" }),
          setting(enabled: false, room_key: "b")
        ]
      )
      pipeline.handle(message(ep_b, text: "https://discord.gg/x", native_id: "5"))
      expect(adapter.deleted).to be_empty
    end
  end

  # A domain whitelist cannot express "this one invite": allowing t.me by domain would allow
  # every Telegram invite there is.
  describe "the invite whitelist" do
    subject(:filter) { described_class.allocate }

    def decide(url, allowed)
      filter.send(:verdict, url, "block_invites", [], [], allowed)
    end

    let(:own) { "https://t.me/+nZLlGg-bVaU2OWFj" }
    let(:someone_else) { "https://t.me/+SomeoneElsesGroup" }

    it "blocks an invite when nothing is allowed, as before" do
      expect(decide(own, [])).to eq(:block)
    end

    it "allows exactly the invite that was listed" do
      expect(decide(own, [own])).to eq(:allow)
    end

    it "still blocks a different invite on the same host" do
      expect(decide(someone_else, [own])).to eq(:block)
    end

    it "accepts the link however an operator pasted it" do
      %w[
        https://t.me/+nZLlGg-bVaU2OWFj
        http://t.me/+nZLlGg-bVaU2OWFj
        t.me/+nZLlGg-bVaU2OWFj
        T.ME/+nZLlGg-bVaU2OWFj
      ].each { |form| expect(decide(own, [form])).to eq(:allow), "did not match #{form}" }
    end

    it "accepts a bare invite code with no host in front of it" do
      expect(decide(own, ["+nZLlGg-bVaU2OWFj"])).to eq(:allow)
    end

    it "never lets an allowed invite override the blacklist" do
      expect(filter.send(:verdict, own, "block_invites", [], ["t.me"], [own])).to eq(:block)
    end
  end

  # A photo carrying the same invite a typed link would, either as a QR code
  # (issue #857) or as text an operator turns OCR on to read (issue #858). No
  # caption on the message at all, matching a "join this group" card posted
  # with nothing typed alongside it.
  describe "a photo attachment" do
    def photo_msg(native_id: "9")
      message(tg, text: "", native_id: native_id, attachments: [photo_attachment])
    end

    it "blocks an invite a QR code decodes to, with no config change at all" do
      qr = stub_attachment_text(qr: "join us at chat.whatsapp.com/ABCdef123GHIjkl456MNo")

      outcome = filter.call(context(photo_msg, config: {}, attachment_text: qr))

      expect(outcome).to be_halt
    end

    it "does not need `ocr` on to catch a QR-decoded invite" do
      qr = stub_attachment_text(qr: "chat.whatsapp.com/ABCdef123GHIjkl456MNo")

      outcome = filter.call(context(photo_msg, config: { ocr: false }, attachment_text: qr))

      expect(outcome).to be_halt
    end

    it "leaves an OCR-only invite alone until `ocr` is turned on" do
      ocr_only = stub_attachment_text(ocr: "join us at chat.whatsapp.com/ABCdef123GHIjkl456MNo")

      outcome = filter.call(context(photo_msg, config: {}, attachment_text: ocr_only))

      expect(outcome).to be_continue
    end

    it "catches an OCR-only invite once `ocr` is turned on" do
      ocr_only = stub_attachment_text(ocr: "join us at chat.whatsapp.com/ABCdef123GHIjkl456MNo")

      outcome = filter.call(context(photo_msg, config: { ocr: true }, attachment_text: ocr_only))

      expect(outcome).to be_halt
    end

    it "still allows an ordinary photo with no code and no invite in its text" do
      nothing_there = stub_attachment_text(qr: "", ocr: "a menu photo has no invite in it")

      outcome = filter.call(context(photo_msg, config: { ocr: true }, attachment_text: nothing_there))

      expect(outcome).to be_continue
    end
  end
  # A link into this community's own rooms leads nowhere else, so it is exempt
  # under every posture. The chat is recognised exactly rather than guessed at:
  # t.me/c/<id> is the chat id with the -100 supergroup prefix dropped.
  describe "a link to this community's own rooms" do
    let(:home) { endpoint("tg", settings: { chat_id: "-1008000000003" }) }
    # Context#operators reads the community first, so the stand-in has to
    # answer that too, not only the rooms this exemption is about.
    let(:community) { Struct.new(:rooms, :operators).new([room("r", home)], nil) }

    def blocks_here?(body, config)
      described_class.new(
        topology: topology(room("r", home)), adapters: adapters, storage: storage,
        logger: Rubotty::Log.null
      ).call(
        Rubotty::Features::Context.new(
          message: message(home, text: body, native_id: "1"), config: config, community: community
        )
      ).halt?
    end

    it "is left alone even where the posture blocks every link" do
      expect(blocks_here?("see https://t.me/c/8000000003/1098", { posture: "block_all" })).to be(false)
    end

    it "still blocks a permalink into a chat this community does not own" do
      expect(blocks_here?("see https://t.me/c/9999999999/5", { posture: "block_all" })).to be(true)
    end

    # Owning a chat says nothing about an invite hash, which names no chat a
    # reader can resolve and which Telegram rotates anyway.
    it "does not exempt somebody else's invite" do
      expect(blocks_here?("join https://t.me/+SomeoneElse", { posture: "block_invites" })).to be(true)
    end

    it "still yields to the blacklist, as every other allow does" do
      expect(blocks_here?("https://t.me/c/8000000003/1098",
                          { posture: "allow_all", blacklist: ["t.me"] })).to be(true)
    end

    # Without a community there is nothing to compare against, which is how
    # every other example here runs.
    it "is inert with no community on the context" do
      expect(blocks?("see https://t.me/c/8000000003/1098", { posture: "block_all" })).to be(true)
    end
  end
end
