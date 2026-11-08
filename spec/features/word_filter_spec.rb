# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Rubotty::Features::WordFilter do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  # One recording adapter and a two-endpoint room, so a removal and its propagation
  # are both observable on the same fake.
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

  # A word list entry that removes on a match, keyed literal and whole-word.
  def list(*entries, **overrides)
    { entries: entries, **overrides }
  end

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat and edit" do
      expect(described_class.feature_name).to eq("word_filter")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat edit])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "defaults mode to off through the schema, and validates the mode/custom fields (issue #173)" do
      schema = described_class.config_schema
      defaulted = schema.call({})
      expect(defaulted).to be_valid
      expect(defaulted.value[:mode]).to eq("off")
      expect(defaulted.value[:custom]).to eq([])

      expect(schema.call({ mode: "slurs_profanity", custom: %w[foo bar] })).to be_valid
      expect(schema.call({ mode: "nonsense" })).not_to be_valid
    end

    it "is a no-op when no list is configured, so it is safe to keep in the chain" do
      outcome = filter.call(context(message(tg, text: "anything at all")))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "the vendored base list and its filter modes" do
    # Calling #call directly is the state a scope is in once an operator has enabled the filter.
    def matches?(text, *entries, **overrides)
      config = entries.empty? && overrides.empty? ? {} : list(*entries, **overrides)
      filter.call(context(message(tg, text: text, native_id: "5"), config: config)).halt?
    end

    # Real terms from the two categories in word_filter_base.yml. The check below pins
    # the membership these cases rely on.
    let(:slur_term)   { "raghead" }  # from the `slur` category
    let(:vulgar_term) { "bullshit" } # from the `vulgar` category
    let(:casual)      { "fuck" }     # a `vulgar`-only term

    it "sorts the fixture terms into the two vendored categories as the tests assume" do
      slurs   = described_class.base_terms(%w[slur])
      vulgars = described_class.base_terms(%w[vulgar])
      expect(slurs).to include(slur_term)
      expect(vulgars).to include(vulgar_term, casual)
      # The casual profanity is deliberately not a slur, which is why `slurs` mode leaves it alone.
      expect(slurs).not_to include(casual, vulgar_term)
    end

    it "vendors both categories as a non-empty, frozen base list by default" do
      terms = described_class.base_terms
      expect(terms).not_to be_empty
      expect(terms).to be_frozen
      expect(terms).to include(vulgar_term)
      expect(terms).to include(slur_term)
    end

    describe "mode off (the default, issue #173)" do
      it "contributes nothing when left unset: dormancy now covers the tier, not just enablement" do
        expect(matches?("you absolute #{slur_term}")).to be(false)
        expect(matches?("what a load of #{vulgar_term}")).to be(false)
      end

      it "contributes nothing when set explicitly either" do
        expect(matches?("you absolute #{slur_term}", mode: "off")).to be(false)
        expect(matches?("what a load of #{vulgar_term}", mode: "off")).to be(false)
      end

      it "still applies the scope's own entries" do
        expect(matches?("a badword here", "badword", mode: "off")).to be(true)
      end
    end

    describe "mode slurs" do
      it "catches a slur but leaves casual profanity" do
        expect(matches?("you absolute #{slur_term}", mode: "slurs")).to be(true)
        expect(matches?("what the #{casual}", mode: "slurs")).to be(false)
      end

      it "deletes on a base-list slur even with no per-scope entries" do
        outcome = filter.call(
          context(message(tg, text: "you absolute #{slur_term}", native_id: "5"), config: { mode: "slurs" })
        )
        expect(outcome).to be_halt
        expect(adapter.deleted).to eq([%w[tg 5]])
      end

      it "lets a per-scope entry extend the slur base: both are caught" do
        expect(matches?("you absolute #{slur_term}", "badword", mode: "slurs")).to be(true) # base slur
        expect(matches?("a badword here", "badword", mode: "slurs")).to be(true)            # per-scope term
      end
    end

    describe "mode slurs_profanity" do
      it "catches both a slur and a vulgar term, including casual profanity" do
        expect(matches?("you absolute #{slur_term}", mode: "slurs_profanity")).to be(true)
        expect(matches?("what a load of #{vulgar_term}", mode: "slurs_profanity")).to be(true)
        expect(matches?("what the #{casual}", mode: "slurs_profanity")).to be(true)
      end

      it "matches a multi-word vulgar phrase on word boundaries" do
        expect(matches?("go jack off somewhere else", mode: "slurs_profanity")).to be(true)
      end

      it "still does not catch a Scunthorpe-safe word the base list deliberately omits" do
        expect(matches?("a careful assessment", mode: "slurs_profanity")).to be(false)
        expect(matches?("have a cocktail", mode: "slurs_profanity")).to be(false)
        expect(matches?("I moved to Scunthorpe", mode: "slurs_profanity")).to be(false)
      end

      it "lets a per-scope entry extend the full base list" do
        expect(matches?("what a load of #{vulgar_term}", "badword", mode: "slurs_profanity")).to be(true)
        expect(matches?("a badword here", "badword", mode: "slurs_profanity")).to be(true)
      end
    end

    it "falls back to off for an invalid mode value: an unrecognised mode never widens filtering" do
      expect(matches?("you absolute #{slur_term}", mode: "bogus")).to be(false)
      expect(matches?("what the #{casual}", mode: "bogus")).to be(false)
    end

    describe "the custom word list" do
      it "applies on top of whatever the mode selects" do
        expect(matches?("a housebanned term", mode: "slurs", custom: %w[housebanned])).to be(true)
        expect(matches?("you absolute #{slur_term}", mode: "slurs", custom: %w[housebanned])).to be(true)
      end

      it "applies even under mode off, so a scope can filter its own words with no tier enabled" do
        expect(matches?("a housebanned term", mode: "off", custom: %w[housebanned])).to be(true)
        expect(matches?("something unrelated", mode: "off", custom: %w[housebanned])).to be(false)
      end

      it "is additive with the legacy entries field rather than replacing it" do
        config = { mode: "off", custom: %w[fromcustom], entries: %w[fromentries] }
        expect(filter.call(context(message(tg, text: "a fromcustom word", native_id: "5"), config: config))).to be_halt
        expect(filter.call(context(message(tg, text: "a fromentries word", native_id: "5"), config: config))).to be_halt
      end
    end

    describe "the legacy vulgarity_mode field, folded in when mode is unset" do
      it "maps none / slurs_only / all onto their off / slurs / slurs_profanity equivalents" do
        expect(matches?("you absolute #{slur_term}", vulgarity_mode: "none")).to be(false)
        expect(matches?("what a load of #{vulgar_term}", vulgarity_mode: "none")).to be(false)

        expect(matches?("you absolute #{slur_term}", vulgarity_mode: "slurs_only")).to be(true)
        expect(matches?("what the #{casual}", vulgarity_mode: "slurs_only")).to be(false)

        expect(matches?("you absolute #{slur_term}", vulgarity_mode: "all")).to be(true)
        expect(matches?("what the #{casual}", vulgarity_mode: "all")).to be(true)
      end

      it "still applies the scope's own entries under any legacy mode" do
        expect(matches?("a badword here", "badword", vulgarity_mode: "none")).to be(true)
      end

      it "is ignored once the canonical mode field is set, which always wins" do
        expect(matches?("what the #{casual}", mode: "off", vulgarity_mode: "all")).to be(false)
      end

      it "falls back to off for an invalid legacy value" do
        expect(matches?("you absolute #{slur_term}", vulgarity_mode: "bogus")).to be(false)
      end
    end
  end

  describe "matching modes" do
    def matches?(text, *entries, **overrides)
      outcome = filter.call(context(message(tg, text: text), config: list(*entries, **overrides)))
      outcome.halt?
    end

    describe "literal" do
      it "is case-insensitive by default" do
        expect(matches?("stop saying BADWORD now", "badword")).to be(true)
        expect(matches?("stop saying BadWord now", "badword")).to be(true)
      end

      it "honours case_sensitive: true" do
        expect(matches?("BADWORD", { pattern: "badword", case_sensitive: true })).to be(false)
        expect(matches?("badword", { pattern: "badword", case_sensitive: true })).to be(true)
      end

      it "matches on a word boundary by default, dodging the Scunthorpe problem" do
        expect(matches?("I moved to Scunthorpe", "cunt")).to be(false)
        expect(matches?("what a cunt", "cunt")).to be(true)
      end

      it "matches a substring when whole_word is turned off" do
        expect(matches?("I moved to Scunthorpe", { pattern: "cunt", whole_word: false })).to be(true)
      end
    end

    describe "wildcard (glob)" do
      it "expands * to any run and matches on a word boundary" do
        expect(matches?("such badness today", { pattern: "bad*", mode: "wildcard" })).to be(true)
        expect(matches?("nothing wrong here", { pattern: "bad*", mode: "wildcard" })).to be(false)
      end

      it "expands ? to a single character" do
        expect(matches?("that is fsck", { pattern: "f?ck", mode: "wildcard" })).to be(true)
        expect(matches?("that is frick", { pattern: "f?ck", mode: "wildcard" })).to be(false)
      end
    end

    describe "regex" do
      it "matches a user-supplied regex, case-insensitively by default" do
        expect(matches?("h3llo world", { pattern: "h[e3]llo", mode: "regex" })).to be(true)
        expect(matches?("H3LLO world", { pattern: "h[e3]llo", mode: "regex" })).to be(true)
        expect(matches?("goodbye world", { pattern: "h[e3]llo", mode: "regex" })).to be(false)
      end
    end

    it "picks the most severe action when a message trips several entries" do
      # A flag list default with one delete entry: delete outranks flag.
      outcome = filter.call(
        context(message(tg, text: "mild and severe"),
                config: { action: "flag", entries: [{ pattern: "mild" }, { pattern: "severe", action: "delete" }] })
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to include(%w[tg 1])
    end
  end

  describe "the ReDoS guard" do
    let(:ruleset) { Rubotty::Features::WordFilter::Ruleset }

    it "rejects a nested-unbounded-quantifier pattern before it can run" do
      %w[(a+)+$ (a*)* ([a-z]+)* (.*)+].each do |pattern|
        compiled = ruleset.compile({ entries: [{ pattern: pattern, mode: "regex" }] })
        expect(compiled).to be_empty, "expected #{pattern.inspect} to be rejected"
      end
    end

    it "rejects a pattern longer than the bound" do
      compiled = ruleset.compile({ entries: [{ pattern: "a" * 1000, mode: "regex" }] })
      expect(compiled).to be_empty
    end

    it "rejects an invalid regex without crashing" do
      compiled = ruleset.compile({ entries: [{ pattern: "(", mode: "regex" }] })
      expect(compiled).to be_empty
    end

    it "time-boxes every compiled regex with a per-pattern budget" do
      compiled = ruleset.compile({ entries: [{ pattern: "h[e3]llo", mode: "regex" }] })
      expect(compiled.rules.first.regex.timeout).to eq(ruleset::REGEX_TIMEOUT_SECONDS)
    end

    it "treats a pattern that blows its budget as no match rather than hanging" do
      # The rule swallows Regexp::TimeoutError into a non-match. The outer timeout makes a
      # regression that removes the guard fail the test instead of hanging CI.
      regex = Regexp.new("(?:a|a)*b", 0, timeout: 0.05)
      rule = Rubotty::Features::WordFilter::Rule.new(
        pattern: "rigged", mode: "regex", action: "delete", regex: regex, logger: Rubotty::Log.null
      )
      allow(regex).to receive(:match?).and_raise(Regexp::TimeoutError)
      result = Timeout.timeout(5) { rule.match?("a" * 100) }
      expect(result).to be(false)
    end
  end

  describe "the delete action" do
    it "removes the offending message on its own endpoint and halts the pipeline" do
      outcome = filter.call(context(message(tg, text: "a badword here", native_id: "5"), config: list("badword")))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "removes the relayed cross-platform copies too, using the message map" do
      # An edit that newly trips the filter, with the original already relayed to the far platform.
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      edit = message(tg, text: "now a badword", native_id: "5", kind: :edit)

      outcome = filter.call(context(edit, config: list("badword")))

      expect(outcome).to be_halt
      expect(adapter.deleted).to contain_exactly(%w[tg 5], %w[dc d1])
      expect(storage.counterparts(ref("tg", "5"))).to be_empty
    end

    it "does not relay a deleted message: the bridge downstream never sees it", :control_plane do
      # The real pipeline, word_filter then bridge: the halt is what keeps an offending
      # message from crossing platforms.
      bridge = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: adapters, storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null
      )
      channels = [tg, dc].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg, dc)]), channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "word_filter", enabled: true, config: { entries: %w[badword] }
          )
        ]
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      registry = instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
      pipeline = Rubotty::Features::Pipeline.new(features: [filter, bridge], registry: registry)

      pipeline.handle(message(tg, text: "a badword", native_id: "5"))

      expect(adapter.deleted).to eq([%w[tg 5]])
      expect(adapter.delivered).to be_empty
    end

    it "posts the standard self-deleting @mention removal notice through the shared flow" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = filter(ephemeral: ephemeral, cleanup: cleanup)

      subject.call(
        context(message(tg, text: "a badword", native_id: "5", author: author(native_id: "u9", first_name: "Ada")),
                config: list("badword", removal_notice_ttl_seconds: 30))
      )

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq("Ada Your last message was automatically removed: Message contained profanity or inappropriate language.")
      # The leading name carries an origin-platform mention span, so it pings.
      mention = notice.body.spans.find { |s| s.kind == :mention }
      expect(mention.attributes).to eq(fake_id_for_target: "u9")
      # The self-delete goes on the shared cleanup scheduler.
      expect(cleanup).to have_received(:after).with(30)
    end

    it "defaults the removal-notice TTL to 60 seconds when a scope leaves it unset" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = filter(ephemeral: ephemeral, cleanup: cleanup)

      subject.call(context(message(tg, text: "a badword", native_id: "5"), config: list("badword")))

      expect(cleanup).to have_received(:after).with(60)
    end

    it "honours a per-scope removal_reason override in the notice" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = filter(ephemeral: ephemeral, cleanup: cleanup)

      subject.call(
        context(message(tg, text: "a badword", native_id: "5"),
                config: list("badword", removal_reason: "Watch your language"))
      )

      expect(adapter.delivered_to("tg").last.body.text)
        .to eq("Ada Your last message was automatically removed: Watch your language.")
    end
  end

  describe "the flag action" do
    it "leaves the message in place and continues, so the bridge still relays it" do
      outcome = filter.call(
        context(message(tg, text: "a badword", native_id: "5"), config: list("badword", action: "flag"))
      )
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

    def audited(config, native_id: "5", author_id: "u9")
      ctx = Rubotty::Features::Context.new(
        message: message(tg, text: "a badword", native_id: native_id, author: author(native_id: author_id, username: "troll")),
        community: community, config: config
      )
      filter(audit: recorder).call(ctx)
      recorder.events.last
    end

    it "records a removed message as a structured event scoped to the community and author" do
      event = audited(list("badword"))
      expect(event).to include(source: "word_filter", action: "delete", community: "acme", subject_native_id: "u9")
      expect(event[:actor]).to eq("word_filter")
      expect(event[:actor_native_id]).to be_nil
      expect(event[:reason]).to eq("Message contained profanity or inappropriate language.")
      expect(event[:target_ref]).to eq("tg:5")
    end

    it "records a flag too, without removing the message" do
      event = audited(list("badword", action: "flag"))
      expect(event[:action]).to eq("flag")
      expect(adapter.deleted).to be_empty
    end

    it "records the requested action in the metadata when it degraded to a stub" do
      event = audited(list("badword", action: "warn", stub_action: "delete"))
      expect(event[:action]).to eq("delete")
      expect(event[:metadata]).to include(requested: "warn")
    end
  end

  describe "the warn and mute stubs, pending the warnings ladder (#46)" do
    it "does not crash on a warn action and degrades to the stub action (delete by default)" do
      outcome = filter.call(
        context(message(tg, text: "a badword", native_id: "5"), config: list("badword", action: "warn"))
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "does not crash on a mute action and honours a flag stub_action" do
      outcome = filter.call(
        context(message(tg, text: "a badword", native_id: "5"),
                config: list("badword", action: "mute", stub_action: "flag"))
      )
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "warn and mute routing to the warnings service (#46)" do
    let(:warnings) { instance_spy(Rubotty::Core::Warnings::Service) }
    let(:offender) { author(native_id: "u9", username: "troll") }

    it "issues a warning for the author on a warn match, still containing the message" do
      subject = filter(warnings: warnings)
      outcome = subject.call(
        context(message(tg, text: "a badword", native_id: "5", author: offender), config: list("badword", action: "warn"))
      )
      expect(warnings).to have_received(:warn).with(hash_including(subject: offender, issued_by: "word filter"))
      # The message is still contained via the stub action (delete by default).
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "applies a mute for the author on a mute match, for the configured duration" do
      subject = filter(warnings: warnings)
      subject.call(
        context(message(tg, text: "a badword", author: offender),
                config: list("badword", action: "mute", mute_duration: "2h", stub_action: "flag"))
      )
      expect(warnings).to have_received(:sanction)
        .with(hash_including(subject: offender, action: :mute, duration: 7200, issued_by: "word filter"))
    end

    it "does not escalate a delete or flag match" do
      subject = filter(warnings: warnings)
      subject.call(context(message(tg, text: "a badword", author: offender), config: list("badword", action: "delete")))
      expect(warnings).not_to have_received(:warn)
      expect(warnings).not_to have_received(:sanction)
    end

    it "passes a reason on both a warn and a mute match, and the community's max/expiry alongside a warn" do
      subject = filter(warnings: warnings)
      community = instance_double(Rubotty::ControlPlane::Snapshot::Community,
                                  feature_config: { max: 3, expires_after: "30d" }, operators: nil, slug: "sample")
      ctx = Rubotty::Features::Context.new(
        message: message(tg, text: "a badword", author: offender), community: community,
        config: list("badword", action: "warn")
      )
      subject.call(ctx)
      expect(warnings).to have_received(:warn).with(hash_including(max: 3, expire_after: 2_592_000, reason: /badword/))

      subject.call(context(message(tg, text: "a badword", author: offender),
                           config: list("badword", action: "mute", stub_action: "flag")))
      expect(warnings).to have_received(:sanction).with(hash_including(reason: /badword/))
    end

    it "feeds the community's own escalation ladder, so a warn match can trip a mute", :control_plane do
      # A one-strike ladder in the community's warnings config, so a single warn mutes.
      db = Sequel.sqlite
      Rubotty::ControlPlane::Migrator.run(db)
      reacting = Fakes::ReactingAdapter.new(own_id: "bot")
      reacting_adapters = Hash.new(reacting)
      service = Rubotty::Core::Warnings::Service.new(
        store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
        scheduler: Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
          session_id: "s", logger: Rubotty::Log.null
        ),
        topology: topology(room("r", tg)), adapters: reacting_adapters, logger: Rubotty::Log.null
      )
      subject = described_class.new(
        topology: topology(room("r", tg)), adapters: reacting_adapters, storage: storage,
        logger: Rubotty::Log.null, warnings: service
      )
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: 1, route_key: tg.id)
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "sample", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg)]), channels: [channel],
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "warnings", enabled: true,
            config: { ladder: [{ threshold: 1, action: "mute", duration: "1h" }] }
          )
        ]
      )
      ctx = Rubotty::Features::Context.new(
        message: message(tg, text: "a badword", author: offender), channel: channel,
        community: community, config: list("badword", action: "warn", stub_action: "flag")
      )

      subject.call(ctx)

      expect(reacting.moderations.map { |m| m[:action] }).to include(:mute)
    end
  end

  describe "operator exemption" do
    let(:operator) do
      Rubotty::Core::Moderation::Operator.new(name: "op", identities: { fake: ["u1"] })
    end
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
    let(:op_author) { author(native_id: "u1") }
    let(:member_author) { author(native_id: "u2") }

    it "exempts operators by default" do
      outcome = filter.call(
        context(message(tg, text: "a badword", author: op_author), config: list("badword"), operators: directory)
      )
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "still filters a non-operator" do
      outcome = filter.call(
        context(message(tg, text: "a badword", native_id: "9", author: member_author),
                config: list("badword"), operators: directory)
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end

    it "subjects operators to the filter when exempt_operators is false" do
      outcome = filter.call(
        context(message(tg, text: "a badword", native_id: "9", author: op_author),
                config: list("badword", exempt_operators: false), operators: directory)
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end

    # The scope is the only directory there is. A message whose community did
    # not resolve carries none, so the same operator is filtered like anyone
    # else rather than exempted out of the merged deployment-wide view.
    it "filters an operator whose community did not resolve" do
      outcome = filter.call(
        context(message(tg, text: "a badword", native_id: "9", author: op_author), config: list("badword"))
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end
  end

  # Every example above calls #call directly, so it keeps passing whatever the
  # observes list says. These drive one real message per observed kind through a
  # real Pipeline, which is the only place the list is ever read.
  describe "every kind it observes, driven through the real pipeline", :control_plane do
    # The filter is off by code default, so a row has to switch it on before the
    # pipeline will run it at all.
    let(:pipeline) do
      channels = [tg, dc].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg, dc)]), channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "word_filter", enabled: true, config: { entries: %w[badword] }
          )
        ]
      )
      Rubotty::Features::Pipeline.new(
        features: [filter],
        registry: instance_double(
          Rubotty::ControlPlane::Registry,
          current: Rubotty::ControlPlane::Snapshot.new(communities: [community])
        )
      )
    end

    observes_kind :chat, "a listed term is taken down the moment it is posted" do
      pipeline.handle(message(tg, text: "a badword here", native_id: "5"))
      adapter.deleted
    end

    observes_kind :edit, "an edit that newly trips the list is taken down as well" do
      pipeline.handle(message(tg, text: "now with a badword", native_id: "5", kind: :edit))
      adapter.deleted
    end

    covers_every_observed_kind
  end

  describe "per-community and per-room config and enablement", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_far) { Rubotty::Core::Endpoint.new(id: "ch-far", adapter_name: :fake, account: "default", settings: {}) }

    def setting(enabled:, room_key: nil, config: {})
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: "word_filter", enabled: enabled, config: config
      )
    end

    def registry_for(feature_settings)
      channels = [ep_a, ep_b, ep_far].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("a", ep_a, ep_far), room("b", ep_b, ep_far)]),
        channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new,
        people: Rubotty::Core::Directory.new,
        feature_settings: feature_settings
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
    end

    def pipeline_for(feature_settings)
      Rubotty::Features::Pipeline.new(features: [filter], registry: registry_for(feature_settings))
    end

    it "runs the filter where a community-default row enables it, reading that row's list" do
      pipeline = pipeline_for([setting(enabled: true, config: { entries: %w[badword] })])
      pipeline.handle(message(ep_a, text: "a badword here", native_id: "5"))
      expect(adapter.deleted).to eq([%w[ch-a 5]])
    end

    it "does not run where a per-room row overrides the community default off" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { entries: %w[badword] }),
          setting(enabled: false, room_key: "b")
        ]
      )
      pipeline.handle(message(ep_b, text: "a badword here", native_id: "5"))
      expect(adapter.deleted).to be_empty
    end

    it "resolves the word list per room: a room row's list applies to its channel" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { entries: %w[community-term] }),
          setting(enabled: true, room_key: "a", config: { entries: %w[channel-term] })
        ]
      )
      # Room "a"'s own list is in force: a room row beats the community default.
      pipeline.handle(message(ep_a, text: "a channel-term slips in", native_id: "7"))
      expect(adapter.deleted).to eq([%w[ch-a 7]])
    end

    it "does not run for an origin the snapshot does not know" do
      pipeline = pipeline_for([setting(enabled: true, config: { entries: %w[badword] })])
      pipeline.handle(message(endpoint("stranger"), text: "a badword", native_id: "5"))
      expect(adapter.deleted).to be_empty
    end
  end

  # The same QR decode and OCR text link_filter reads off a photo attachment
  # (issues #857, #858) feeds this filter too, off the one shared extraction
  # pass: a slur baked into a QR code, or typed into a screenshot, is exactly
  # what a scope with word_filter on would want caught.
  describe "a photo attachment" do
    def photo_msg(native_id: "9")
      message(tg, text: "", native_id: native_id, attachments: [photo_attachment])
    end

    it "matches a banned word a QR code decodes to, with no config change at all" do
      qr = stub_attachment_text(qr: "come find the badword crew")

      outcome = filter.call(context(photo_msg, config: list("badword"), attachment_text: qr))

      expect(outcome).to be_halt
    end

    it "leaves an OCR-only match alone until `ocr` is turned on" do
      ocr_only = stub_attachment_text(ocr: "come find the badword crew")

      outcome = filter.call(context(photo_msg, config: list("badword"), attachment_text: ocr_only))

      expect(outcome).to be_continue
    end

    it "catches an OCR-only match once `ocr` is turned on" do
      ocr_only = stub_attachment_text(ocr: "come find the badword crew")
      config = list("badword").merge(ocr: true)

      outcome = filter.call(context(photo_msg, config: config, attachment_text: ocr_only))

      expect(outcome).to be_halt
    end

    it "still allows an ordinary photo whose text trips nothing" do
      nothing_there = stub_attachment_text(qr: "", ocr: "a menu photo has nothing filtered in it")
      config = list("badword").merge(ocr: true)

      outcome = filter.call(context(photo_msg, config: config, attachment_text: nothing_there))

      expect(outcome).to be_continue
    end
  end
  # The gap that let TRAVEL delete messages for a month with nobody told: this
  # filter removes, posts a self-deleting notice and writes an audit row, and
  # until now told no operator anything.
  describe "telling the operators" do
    let(:notifier) do
      Class.new do
        attr_reader :dms

        def initialize = @dms = []

        def notify_operators!(community_id:, text:)
          @dms << { community_id: community_id, text: text }
          Rubotty::ControlPlane::AdminNotifier::Delivery.new(audience: 1, reached: 1, refused: 0, unreachable: 0)
        end
      end.new
    end

    it "asks the shared removal engine to alert, which the rate guards do not" do
      filter = described_class.new(
        topology: topology(room("r", endpoint("tg"))), adapters: Hash.new(Fakes::RecordingAdapter.new),
        storage: Rubotty::Storage::Memory.new, logger: Rubotty::Log.null, admin_notifier: notifier
      )
      engine = filter.instance_variable_get(:@removal)

      expect(engine.instance_variable_get(:@notice).instance_variable_get(:@alerts)).to be(true)
      expect(engine.instance_variable_get(:@notice).instance_variable_get(:@admin_notifier)).to be(notifier)
    end

    it "offers the scope a way to turn that DM off" do
      field = described_class.config_schema.fields[Rubotty::Core::RemovalNotice::NOTIFY_FIELD]

      expect(field).not_to be_nil
      expect(field.default).to be(true)
    end
  end

end
