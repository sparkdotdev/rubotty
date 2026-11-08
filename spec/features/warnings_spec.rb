# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The operator-gated `/warn`, `/warnings` and `/unwarn` commands: swallowed like any
# moderation command, acknowledged ephemerally, routed to the shared warnings service.
RSpec.describe Rubotty::Features::Warnings do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: true) }
  let(:adapters) { Hash.new(adapter) }
  let(:storage) { Rubotty::Storage::Memory.new }

  let(:db) do
    db = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(db)
    db
  end
  let(:service) do
    Rubotty::Core::Warnings::Service.new(
      store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
      scheduler: Rubotty::Core::DurableScheduler.new(
        store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
        session_id: "s", logger: Rubotty::Log.null
      ),
      topology: topology(room("r", tg)), adapters: adapters, storage: storage, logger: Rubotty::Log.null
    )
  end

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg)), logger: Rubotty::Log.null
    )
  end

  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["op1"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:issuer) { author(native_id: "op1", username: "op") }
  let(:subject_author) { author(native_id: "u9", username: "troll") }

  def feature(cleanup: nil, storage: self.storage)
    described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null, storage: storage,
      service: service, ephemeral: ephemeral, cleanup: cleanup
    )
  end

  # A command message issued as a reply to the subject's message, which is how a
  # user-level moderation command names its target.
  def command(text, from: issuer, target: subject_author, native_id: "100")
    message(
      tg, text: text, native_id: native_id, author: from,
      reply_to: ref("tg", "parent"),
      reply_preview: Rubotty::Core::ReplyPreview.new(author: target, ref: ref("tg", "parent"))
    )
  end

  # A real Snapshot::Community sharing the "sample" slug the warnings service
  # calls resolve to, so #command_prefixes has feature_config to read; +prefixes+
  # configures the shared marker the way an operator would through the dashboard.
  def community_with(prefixes: nil, operators: directory)
    settings = prefixes.nil? ? [] : [
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        feature: Rubotty::Core::CommandPrefix::CONFIG_FEATURE, enabled: true, config: { "prefixes" => prefixes }
      )
    ]
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: "sample", slug: "sample", name: "sample", status: "active", settings: {},
      topology: Rubotty::Core::Topology.new([]), channels: [],
      operators: operators, people: Rubotty::Core::Directory.new,
      feature_settings: settings
    )
  end

  def context(message, config: {}, community: community_with, operators: directory)
    Rubotty::Features::Context.new(message: message, config: config, community: community, operators: operators)
  end

  def last_ack = adapter.delivered_to("tg").last&.body&.text

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat" do
      expect(described_class.feature_name).to eq("warnings")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "publishes a config schema for the dashboard and loader" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "leaves an ordinary message alone so the bridge relays it" do
      outcome = feature.call(context(message(tg, text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "leaves another feature's command alone (only /warn, /warnings, /unwarn are ours)" do
      outcome = feature.call(context(command("/delete")))
      expect(outcome).to be_continue
    end
  end

  describe "operator gating (fail closed)" do
    # #1154: a non-operator used to get nothing back at all, which read as
    # /warn silently doing nothing rather than refusing it. It still never
    # acts, but now says why, the same policy #1148 applied everywhere else.
    it "refuses a warnings command from a non-operator, saying why, without acting" do
      stranger = author(native_id: "nobody", username: "rando")
      outcome = feature.call(context(command("/warn spam", from: stranger)))
      expect(outcome).to be_halt                     # never relayed
      expect(last_ack).to include("operator standing")
      expect(service.list(community: "sample", subject: subject_author, adapter: :fake)).to be_empty
    end

    it "resolves the issuer in the community's own operator directory" do
      feature.call(context(command("/warn spam"), operators: directory))
      expect(service.list(community: "sample", subject: subject_author, adapter: :fake).size).to eq(1)
    end

    # No community resolved means no directory, so the issuer resolves to
    # nobody rather than to a row from the merged deployment-wide view.
    it "refuses an operator whose community did not resolve" do
      feature.call(context(command("/warn spam"), community: nil, operators: nil))
      expect(last_ack).to include("operator standing")
      expect(service.list(community: "sample", subject: subject_author, adapter: :fake)).to be_empty
    end
  end

  describe "reply targeting" do
    # #1154: typed on its own with no reply, /warn used to say nothing, which
    # left the reply requirement to be discovered rather than told.
    it "tells the issuer a warnings command needs to be a reply, without acting" do
      no_reply = message(tg, text: "/warn spam", author: issuer)
      outcome = feature.call(context(no_reply))
      expect(outcome).to be_halt
      expect(last_ack).to include("only works as a reply")
    end
  end

  # Discord reserves a leading "/" for its native slash-command UI, so "!" has to work too.
  describe "command prefixes" do
    it "recognises /warn under the alternate ! prefix by default, not only /" do
      outcome = feature.call(context(command("!warn spamming")))
      expect(outcome).to be_halt
      warnings = service.list(community: "sample", subject: subject_author, adapter: :fake)
      expect(warnings.map(&:reason)).to eq(["spamming"])
    end

    it "leaves an unknown prefixed token alone, so the bridge relays it" do
      outcome = feature.call(context(command("!warny stuff")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "honours a community's restricted prefix set: with only /, ! is not a warnings command" do
      outcome = feature.call(context(command("!warn spam"), community: community_with(prefixes: ["/"])))
      expect(outcome).to be_continue
      expect(service.list(community: "sample", subject: subject_author, adapter: :fake)).to be_empty
    end
  end

  describe "/warn" do
    it "records a warning against the replied author and acknowledges it ephemerally" do
      outcome = feature.call(context(command("/warn spamming links")))
      expect(outcome).to be_halt
      warnings = service.list(community: "sample", subject: subject_author, adapter: :fake)
      expect(warnings.map(&:reason)).to eq(["spamming links"])
      expect(warnings.first.issued_by).to eq("Op")
      expect(last_ack).to include("Warned").and include("1 active")
    end

    it "self-deletes the acknowledgement on the shared cleanup scheduler" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      feature(cleanup: cleanup).call(context(command("/warn spam"), config: { ack_ttl_seconds: 30 }))
      expect(cleanup).to have_received(:after).with(30)
    end

    it "escalates through the ladder and reports the applied sanction in the ack" do
      ladder = [{ threshold: 2, action: "mute", duration: "1h" }]
      2.times { feature.call(context(command("/warn spam"), config: { ladder: ladder })) }
      expect(adapter.moderations.last[:action]).to eq(:mute)
      expect(last_ack).to include("Muted").and include("1h")
    end

    it "DMs the subject their level against the configured max" do
      feature.call(context(command("/warn spamming links"), config: { max: 3 }))
      expect(adapter.dms_sent.last[:native_id]).to eq("u9")
      expect(adapter.dms_sent.last[:text]).to include("warning level 1 of 3")
    end

    it "notes it in the ack, rather than swallowing it, when the DM cannot be delivered" do
      closed_dm_service = Rubotty::Core::Warnings::Service.new(
        store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
        scheduler: Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s", logger: Rubotty::Log.null
        ),
        # A DM-closed twin of the shared adapter, so the ack still posts where
        # `last_ack` reads it while the DM itself is refused.
        topology: topology(room("r", tg)),
        adapters: Hash.new(Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: false)),
        logger: Rubotty::Log.null
      )
      feature = described_class.new(
        topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
        storage: storage, service: closed_dm_service, ephemeral: ephemeral
      )
      feature.call(context(command("/warn spam")))
      texts = adapter.delivered_to("tg").map { |message| message.body.text }
      expect(texts).to include(a_string_including("Could not DM them."))
    end

    it "pings the subject publicly, non-ephemerally, when the DM cannot be delivered" do
      closed_dm_service = Rubotty::Core::Warnings::Service.new(
        store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
        scheduler: Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s", logger: Rubotty::Log.null
        ),
        topology: topology(room("r", tg)),
        adapters: Hash.new(Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: false)),
        logger: Rubotty::Log.null
      )
      feature = described_class.new(
        topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
        storage: storage, service: closed_dm_service, ephemeral: ephemeral
      )
      feature.call(context(command("/warn spam")))
      notice = adapter.delivered_to("tg").find { |message| message.body.text.include?("Could not reach you by DM") }
      expect(notice).not_to be_nil
      expect(notice.body.text).to include("Ada")
    end

    # The room used to read the accusation and never the consequence, which is
    # the half that makes a public notice worth posting at all.
    it "names the penalty in the room, since that is what the notice is for" do
      tg = endpoint("tg", adapter: :fake, settings: { room_key: "r" })
      closed_dm_service = Rubotty::Core::Warnings::Service.new(
        store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
        scheduler: Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s", logger: Rubotty::Log.null
        ),
        topology: topology(room("r", tg)),
        adapters: Hash.new(Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: false)),
        logger: Rubotty::Log.null
      )
      feature = described_class.new(
        topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
        storage: storage, service: closed_dm_service, ephemeral: ephemeral
      )

      feature.call(context(command("/warn spam"), config: { ladder: [{ threshold: 1, action: "mute", duration: "1h" }] }))

      notice = adapter.delivered_to("tg").find { |message| message.body.text.include?("Could not reach you by DM") }
      expect(notice.body.text).to include("muted for 1h")
    end

    # One warning is one notice. A second in-room announcement was added in the
    # service while this one already existed, so a warned member was told twice
    # in the same room, once with the reason and once without.
    it "posts exactly one notice, carrying the reason and how long it lasts" do
      tg = endpoint("tg", adapter: :fake, settings: { room_key: "r" })
      closed_dm_service = Rubotty::Core::Warnings::Service.new(
        store: Rubotty::Core::WarningsStore::Sequel.new(db: db),
        scheduler: Rubotty::Core::DurableScheduler.new(
          store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s", logger: Rubotty::Log.null
        ),
        topology: topology(room("r", tg)),
        adapters: Hash.new(Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: false)),
        ephemeral: ephemeral, logger: Rubotty::Log.null
      )
      feature = described_class.new(
        topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
        storage: storage, service: closed_dm_service, ephemeral: ephemeral
      )

      feature.call(context(command("/warn spam"), config: { expires_after: "90d" }))

      notices = adapter.delivered_to("tg").select { |m| m.body.text.include?("you have been warned") }
      expect(notices.length).to eq(1)
      expect(notices.first.body.text).to include("Reason: spam.")
      expect(notices.first.body.text).to include("stays on your record for 90 days")
    end

    describe "delete=true" do
      it "deletes the replied-to message and reports it in the ack" do
        feature.call(context(command("/warn spamming delete=true")))
        expect(adapter.deleted).to include(["tg", "parent"])
        expect(last_ack).to include("Deleted their message.")
        warnings = service.list(community: "sample", subject: subject_author, adapter: :fake)
        expect(warnings.map(&:reason)).to eq(["spamming"])
      end

      # The invocation itself always goes now, so this is said about the
      # replied-to message rather than about everything the adapter removed.
      it "does not delete the replied-to message by default" do
        feature.call(context(command("/warn spamming links")))
        expect(adapter.deleted).not_to include(["tg", "parent"])
      end

      it "treats a reason that merely contains the phrase mid-sentence as plain text" do
        feature.call(context(command("/warn they literally typed delete=true in chat")))
        expect(adapter.deleted).not_to include(["tg", "parent"])
        warnings = service.list(community: "sample", subject: subject_author, adapter: :fake)
        expect(warnings.map(&:reason)).to eq(["they literally typed delete=true in chat"])
      end

      it "leaves a reason with its own equals sign untouched" do
        feature.call(context(command("/warn the score was tied at 3=3")))
        warnings = service.list(community: "sample", subject: subject_author, adapter: :fake)
        expect(warnings.map(&:reason)).to eq(["the score was tied at 3=3"])
      end

      it "reports the failure rather than swallowing it when deletion is unavailable" do
        feature(storage: nil).call(context(command("/warn spam delete=true")))
        expect(last_ack).to include("Could not delete their message")
      end
    end
  end

  describe "/warnings" do
    def last_dm = adapter.dms_sent.last

    it "lists the subject's active warnings to the operator who asked" do
      feature.call(context(command("/warn first")))
      feature.call(context(command("/warn second")))
      adapter.delivered.clear
      adapter.dms_sent.clear

      outcome = feature.call(context(command("/warnings")))
      expect(outcome).to be_halt
      expect(last_dm[:native_id]).to eq(issuer.native_id)
      expect(last_dm[:text]).to include("2 active warning(s)").and include("first").and include("second")
    end

    # The listing names the operator behind every strike, so the room is the
    # one place it must not appear: it told the member which operator to hold
    # each warning against for as long as the acknowledgement window ran.
    it "puts nothing about it in the room" do
      feature.call(context(command("/warn first")))
      adapter.delivered.clear

      feature.call(context(command("/warnings")))

      expect(adapter.delivered_to("tg")).to be_empty
    end

    it "says so when the subject is clean" do
      adapter.dms_sent.clear
      feature.call(context(command("/warnings")))
      expect(last_dm[:text]).to include("no active warnings")
    end

    # An operator the bot cannot open a chat with is told to open one, in a
    # notice that names neither the subject nor anybody who warned them.
    it "asks the operator to open a chat when it cannot DM them, leaking nothing" do
      quiet = Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: false)
      described_class.new(
        topology: topology(room("r", tg)), adapters: Hash.new(quiet), logger: Rubotty::Log.null,
        storage: storage, service: service, ephemeral: Rubotty::Core::EphemeralMessage.new(
          adapters: Hash.new(quiet), topology: topology(room("r", tg)), session_id: "s", logger: Rubotty::Log.null
        )
      ).call(context(command("/warnings")))

      posted = quiet.delivered_to("tg").map { |sent| sent.body.text }
      expect(posted.last).to include("Open a chat with me")
      expect(posted.join).not_to include("active warning")
    end
  end

  # The member must not learn which operator warned them, so nothing this
  # feature posts where they can read it may carry that name. The acknowledgements
  # are welcome in the room precisely because they name the subject and not the
  # issuer, and this is what keeps that true as the copy changes.
  describe "what the room can read" do
    # Distinctive on every axis the operator could be named by, since the
    # default fixture's "Op" occurs inside ordinary words and would pass by
    # accident. issued_by carries the directory NAME, not the chat handle.
    let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Quillsharp", identities: { fake: ["op1"] }) }
    let(:issuer) { author(native_id: "op1", username: "distinctivehandle") }

    def posted_in_room = adapter.delivered_to("tg").map { |sent| sent.body.text }.join("\n")

    it "never names the issuing operator in any acknowledgement" do
      feature.call(context(command("/warn spam")))
      feature.call(context(command("/warn again delete=true")))
      feature.call(context(command("/warnings")))
      feature.call(context(command("/unwarn")))
      feature.call(context(command("/unwarn all")))

      expect(posted_in_room).not_to include("Quillsharp")
      expect(posted_in_room).not_to include("distinctivehandle")
      expect(posted_in_room).not_to include("op1")
    end

    it "does not name them on the refusal paths either" do
      stranger = author(native_id: "nobody", username: "rando")
      feature.call(context(command("/warn spam", from: stranger)))
      feature.call(context(command("/warn spam"), community: nil, operators: nil))

      expect(posted_in_room).not_to include("rando")
      expect(posted_in_room).not_to include("nobody")
    end

    # It still has to reach the record and the audit trail, which is where a
    # reversal reads it back from; the room is the only place it may not go.
    it "still records who issued the warning" do
      feature.call(context(command("/warn spam")))

      issued = service.list(community: "sample", subject: subject_author, adapter: :fake).map(&:issued_by)
      expect(issued).to eq(["Quillsharp"])
    end
  end

  describe "/unwarn" do
    it "removes the most recent warning by default" do
      feature.call(context(command("/warn first")))
      feature.call(context(command("/warn second")))
      feature.call(context(command("/unwarn")))
      remaining = service.list(community: "sample", subject: subject_author, adapter: :fake)
      expect(remaining.map(&:reason)).to eq(["first"])
      expect(last_ack).to include("Removed the most recent warning")
    end

    it "clears every warning with /unwarn all" do
      2.times { feature.call(context(command("/warn spam"))) }
      feature.call(context(command("/unwarn all")))
      expect(service.list(community: "sample", subject: subject_author, adapter: :fake)).to be_empty
      expect(last_ack).to include("Cleared 2 warning(s)")
    end
  end

  describe "off by default, through the Snapshot", :control_plane do
    def registry_for(feature_settings)
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: 1, route_key: tg.id)
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "sample", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg)]), channels: [channel],
        operators: directory, people: Rubotty::Core::Directory.new,
        feature_settings: feature_settings
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
    end

    it "does not run where no feature_settings row enables it" do
      pipeline = Rubotty::Features::Pipeline.new(features: [feature], registry: registry_for([]))
      pipeline.handle(command("/warn spam"))
      expect(adapter.delivered).to be_empty
      expect(service.list(community: "sample", subject: subject_author, adapter: :fake)).to be_empty
    end

    it "runs where a feature_settings row turns it on for the community" do
      settings = [Rubotty::ControlPlane::Snapshot::FeatureSetting.new(feature: "warnings", enabled: true, config: {})]
      pipeline = Rubotty::Features::Pipeline.new(features: [feature], registry: registry_for(settings))
      pipeline.handle(command("/warn spam"))
      expect(service.list(community: "sample", subject: subject_author, adapter: :fake).size).to eq(1)
    end
  end

  # The reply went and the typed /warn stayed, which for a command naming who was
  # warned and why is the half worth taking away.
  describe "clearing up after itself" do
    let(:base) { Time.now }
    let(:clock) { -> { @now ||= base } }
    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }

    def advance(seconds) = (@now = (@now || base) + seconds)

    after { scheduler.stop }

    # Thirty seconds was long enough for the member being warned to read who
    # issued it and hold it against them, which is the reprisal the DM already
    # takes care to avoid. So this one goes at once rather than on the window.
    it "removes the invocation at once, without waiting for the acknowledgement window" do
      feature(cleanup: scheduler).call(
        context(command("/warn spam", native_id: "typed-1"), config: { ack_ttl_seconds: 5 })
      )

      expect(adapter.deleted).to include(%w[tg typed-1])
    end

    # The scope's preference governs invocations that name nobody. This one
    # names an operator acting against a member, so it does not get to stand.
    it "removes it even where the scope asked to keep its invocations" do
      feature(cleanup: scheduler).call(
        context(command("/warn spam", native_id: "typed-2"),
                config: { ack_ttl_seconds: 5, delete_command_message: false })
      )

      expect(adapter.deleted).to include(%w[tg typed-2])
    end

    # A refused attempt names its operator as plainly as an accepted one, so
    # the removal sits ahead of the operator gate rather than after it.
    it "removes a refused invocation too" do
      stranger = author(native_id: "nobody", username: "rando")
      feature(cleanup: scheduler).call(
        context(command("/warn spam", from: stranger, native_id: "typed-3"))
      )

      expect(adapter.deleted).to include(%w[tg typed-3])
    end

    # It is gone by the time the answer is posted, so handing the same ref to
    # the ephemeral reaper would leave it retrying a delete against nothing.
    it "does not also pair the invocation with the acknowledgement" do
      feature(cleanup: scheduler).call(
        context(command("/warn spam", native_id: "typed-4"), config: { ack_ttl_seconds: 5 })
      )
      before = adapter.deleted.count(%w[tg typed-4])
      advance(5)
      scheduler.run_due

      expect(adapter.deleted.count(%w[tg typed-4])).to eq(before)
    end
  end
end
