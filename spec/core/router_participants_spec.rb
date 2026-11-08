# frozen_string_literal: true

require "spec_helper"

# What a script can find out about people, say to one of them, and do to a
# message afterwards. The handlers are exercised directly rather than
# through Lua, the same way router_alert_spec does: what is under test is
# which platform each call reaches and what it answers when none can comply.
RSpec.describe Rubotty::Core::Router, "who a script is talking to", :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }
  let(:participants) { Rubotty::ControlPlane::Participants.new(models: models, directory: directory) }

  let(:community_id) do
    stamp = Time.now
    db[:communities].insert(slug: "alpha", name: "Alpha", status: "active",
                            settings: "{}", created_at: stamp, updated_at: stamp)
  end

  # Only what the handlers read: an id for the directory queries, and the rooms
  # the mention annotator asks about.
  let(:community) { Struct.new(:id, :rooms).new(community_id, [chat_room]) }

  let(:telegram) { endpoint("tg-general", adapter: :telegram, account: "tg") }
  let(:irc) { endpoint("irc-general", adapter: :irc, account: "irc") }
  let(:chat_room) { room("general", telegram, irc) }
  let(:live) { topology(chat_room) }

  # Telegram can open a chat with somebody; IRC cannot, and cannot edit or
  # react either, which is what makes it the honest half of every degrade.
  let(:telegram_adapter) { DirectMessagingAdapter.new(account: "tg") }
  let(:irc_adapter) { PlainAdapter.new(account: "irc") }
  # Keyed the way every other holder of the adapter map keys it: adapter name
  # and account together, since one deployment may run two of the same platform.
  let(:adapters) { { [:telegram, "tg"] => telegram_adapter, [:irc, "irc"] => irc_adapter } }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(adapters: adapters, session_id: "session-1",
                                        topology: live, logger: Rubotty::Log.null)
  end

  # A platform that can post and do nothing else afterwards, which is IRC: no
  # edits, no deleting somebody else's message, no reactions, no direct
  # messages. Every degrade in this file is measured against it.
  class PlainAdapter < Fakes::RecordingAdapter
    CAPABILITIES = Rubotty::Adapters::Capabilities.new.freeze

    def capabilities = CAPABILITIES
  end

  # An adapter that can be DMed, which no shared fake is, since only Telegram
  # and Discord implement one.
  class DirectMessagingAdapter < Fakes::ReactingAdapter
    def initialize(**)
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

  let(:sender) do
    Rubotty::Core::Author.new(native_id: "111", username: "ada", first_name: "Ada")
  end

  let(:incoming) { message(telegram, text: "hello", native_id: "m1", author: sender) }

  # Only the four readers the handlers touch.
  let(:context) do
    Struct.new(:message, :community, :channel, :operators).new(incoming, community, "general", nil)
  end

  def router = described_class.allocate

  def seen(adapter:, native_id:, username: nil, display: nil)
    directory.record(community_id: community_id, adapter: adapter,
                     native_id: native_id, username: username, display: display)
  end

  def person(name, identities)
    stamp = Time.now
    id = db[:people].insert(community_id: community_id, name: name, created_at: stamp, updated_at: stamp)
    identities.each do |adapter, native_id, username|
      db[:person_identities].insert(person_id: id, adapter: adapter.to_s, native_id: native_id,
                                    username: username, created_at: stamp)
    end
    id
  end

  describe "participant()" do
    def handler
      router.send(:script_participant_handler, context, participants: participants, community: community)
    end

    it "names whoever sent the message" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada")

      answer = handler.call

      expect(answer["id"]).to eq("telegram:111")
      expect(answer["display"]).to eq("Ada")
      expect(answer["platform"]).to eq("telegram")
      expect(answer["is_operator"]).to be(false)
    end

    it "names the person rather than the account once the two are linked" do
      id = person("Ada Lovelace", [[:telegram, "111", "ada"]])

      expect(handler.call["id"]).to eq("person:#{id}")
    end

    # The display here comes from the sender's own name on the message, which
    # is member controlled, so it is stripped on the way out.
    it "strips the styling sentinels out of the display name it hands back" do
      forged = "Ada#{Rubotty::Scripting::Markup::OPEN}@@someone-else#{Rubotty::Scripting::Markup::CLOSE}"
      forged_sender = Rubotty::Core::Author.new(native_id: "111", username: "ada", first_name: forged)
      forged_context = Struct.new(:message, :community, :channel, :operators)
                             .new(message(telegram, text: "hi", native_id: "m2", author: forged_sender),
                                  community, "general", nil)
      handler = router.send(:script_participant_handler, forged_context,
                            participants: participants, community: community)

      expect(handler.call["display"]).to eq("Ada@@someone-else")
    end

    # There is nobody to name when no message caused the run, and saying so is
    # the same honesty warn already keeps.
    it "answers nothing on a woken run" do
      woken = Rubotty::Scripting::WakeContext.new(community: community, room_key: "general")
      handler = router.send(:script_participant_handler, woken,
                            participants: participants, community: community)

      expect(handler.call).to be_nil
    end
  end

  describe "resolve_participant(name)" do
    def handler
      router.send(:script_resolve_participant_handler, participants: participants, community: community)
    end

    it "turns a name an operator typed into somebody" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada Lovelace")

      expect(handler.call("ada")).to eq({ "id" => "telegram:111", "display" => "Ada Lovelace" })
    end

    # The point of the whole function. Two Adas and no way to tell which was
    # meant, so nothing comes back and the script can say so out loud.
    it "answers nothing when the name means more than one person" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada Lovelace")
      seen(adapter: :irc, native_id: "222", username: "ada", display: "Ada Someone")

      expect(handler.call("ada")).to be_nil
    end

    it "answers nothing for a name nobody goes by" do
      expect(handler.call("nobody at all")).to be_nil
    end

    # A display name is member controlled, so it is stripped like every other
    # string a member chose. Unstripped, a script that echoes the
    # name it resolved would render formatting the member picked, or ping
    # somebody else, under the bot's name.
    it "strips the styling sentinels out of a display name" do
      forged = "Ada#{Rubotty::Scripting::Markup::OPEN}@@someone-else#{Rubotty::Scripting::Markup::CLOSE}"
      seen(adapter: :telegram, native_id: "111", username: "ada", display: forged)

      expect(handler.call("ada")["display"]).to eq("Ada@@someone-else")
    end
  end

  describe "mention_participant(id)" do
    def handler
      router.send(:script_mention_participant_handler, context,
                  participants: participants, community: community)
    end

    it "answers a mention of the handle they are known by here" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada")

      expect(handler.call("telegram:111")).to eq(Rubotty::Scripting::Markup.mention("ada"))
    end

    it "falls back to their name where no handle is known" do
      seen(adapter: :telegram, native_id: "111", display: "Ada Lovelace")

      expect(handler.call("telegram:111")).to eq("Ada Lovelace")
    end

    it "answers nothing at all for an id naming nobody here" do
      expect(handler.call("telegram:404")).to eq("")
    end

    # The mention has to become a real ping, which means the platform's own id
    # on the span rather than the handle alone. Without this a script's ping
    # read as the right name on Discord and notified nobody.
    it "resolves to a real ping when the answer is posted" do
      seen(adapter: :telegram, native_id: "111", username: "ada")
      annotator = router.send(:script_mention_annotator, identity_directory: directory)

      body = router.send(:script_body, handler.call("telegram:111"),
                         mentions: annotator, community: community)

      expect(body.text).to eq("@ada")
      expect(body.spans.first.attributes[:telegram_id_for_target]).to eq("111")
    end
  end

  describe "whisper" do
    def handler
      router.send(:script_whisper_handler, context, participants: participants, adapters: adapters,
                                                    topology: live, ephemeral: ephemeral,
                                                    community: community, logger: Rubotty::Log.null)
    end

    it "reaches one member privately, and nobody else" do
      seen(adapter: :telegram, native_id: "111", username: "ada")

      answer = handler.call({ "to" => "telegram:111", "text" => "You have already voted." })

      expect(answer.to_a).to eq([true])
      expect(telegram_adapter.dms).to eq([["111", "You have already voted."]])
      expect(telegram_adapter.delivered).to be_empty
    end

    it "reaches a batch in one call, since telling twelve players their score is the ordinary case" do
      seen(adapter: :telegram, native_id: "111", username: "ada")
      seen(adapter: :telegram, native_id: "222", username: "bob")

      handler.call({ "to" => ["telegram:111", "telegram:222"], "text" => "Your score is 3." })

      expect(telegram_adapter.dms.map(&:first)).to eq(%w[111 222])
    end

    it "takes the tables participant and resolve_participant hand back" do
      seen(adapter: :telegram, native_id: "111", username: "ada")

      handler.call({ "to" => { "id" => "telegram:111" }, "text" => "hello" })

      expect(telegram_adapter.dms.map(&:first)).to eq(["111"])
    end

    # IRC has no direct messages at all, so there is no private route to
    # anybody who is only there.
    it "answers false and says why when the platform has no private route" do
      seen(adapter: :irc, native_id: "333", username: "cleo")

      ok, reason = handler.call({ "to" => "irc:333", "text" => "quietly" }).to_a

      expect(ok).to be(false)
      expect(reason).to include("no private route to 1 of 1")
      expect(irc_adapter.delivered).to be_empty
    end

    # The default has to be silence: a rule that meant "quietly" and got "in
    # front of two hundred people" is the failure worth designing against.
    it "says nothing anywhere by default when it cannot reach them" do
      seen(adapter: :irc, native_id: "333", username: "cleo")

      handler.call({ "to" => "irc:333", "text" => "quietly" })

      expect(irc_adapter.delivered).to be_empty
      expect(telegram_adapter.delivered).to be_empty
    end

    it "says it in the room when asked to, and still answers false" do
      seen(adapter: :irc, native_id: "333", username: "cleo")

      ok, reason = handler.call({ "to" => "irc:333", "text" => "quietly",
                                  "fallback" => "room" }).to_a

      expect(ok).to be(false)
      expect(reason).to include("said in the room instead")
      expect(irc_adapter.delivered.length).to eq(1)
      expect(irc_adapter.delivered.first.last.body.text).to eq("cleo: quietly")
    end

    it "refuses a batch larger than the cap rather than working through it" do
      recipients = Array.new(described_class::MAX_WHISPER_RECIPIENTS + 1) { |i| "telegram:#{i}" }

      ok, reason = handler.call({ "to" => recipients, "text" => "hello" }).to_a

      expect(ok).to be(false)
      expect(reason).to include("25 people at most")
      expect(telegram_adapter.dms).to be_empty
    end

    it "refuses a whisper with nobody to say it to, or nothing to say" do
      expect(handler.call({ "text" => "hello" }).to_a.first).to be(false)
      expect(handler.call({ "to" => "telegram:111" }).to_a.first).to be(false)
    end

    # An id a script made up names nobody, so nothing is sent to it.
    it "reaches nobody for an id this community has never seen" do
      ok, = handler.call({ "to" => "telegram:404", "text" => "hello" }).to_a

      expect(ok).to be(false)
      expect(telegram_adapter.dms).to be_empty
    end
  end

  describe "post, edit, delete and react" do
    def post_handler
      router.send(:script_post_handler, context, topology: live, ephemeral: ephemeral,
                                                 logger: Rubotty::Log.null)
    end

    def edit_handler
      router.send(:script_edit_handler, context, topology: live, ephemeral: ephemeral)
    end

    def delete_handler
      router.send(:script_delete_handler, context, topology: live, ephemeral: ephemeral)
    end

    def react_handler
      router.send(:script_react_handler, context, topology: live, adapters: adapters,
                                                  logger: Rubotty::Log.null)
    end

    it "posts to every platform in the room and answers one handle for all of them" do
      handle = post_handler.call({ "text" => "Round one." })

      expect(telegram_adapter.delivered.length).to eq(1)
      expect(irc_adapter.delivered.length).to eq(1)
      expect(Rubotty::Scripting::Handle.refs(handle).map(&:endpoint_id))
        .to contain_exactly("tg-general", "irc-general")
    end

    it "answers a reply to the message in hand, on the platform it was said on" do
      post_handler.call({ "text" => "Yes.", "reply_to" => Rubotty::Scripting::Handle.of(incoming.ref) })

      posted = telegram_adapter.delivered.first.last
      expect(posted.reply_to&.native_id).to eq("m1")
      # Nothing to point at on the other platform, so nothing is claimed there.
      expect(irc_adapter.delivered.first.last.reply_to).to be_nil
    end

    it "refuses to post nothing" do
      expect(post_handler.call({}).to_a.first).to be(false)
    end

    # The handle is a string precisely so that this works: post now, keep it,
    # edit it on a wake ten minutes later.
    it "survives a round trip through a memo" do
      handle = post_handler.call({ "text" => "Round one." })
      memo = {}
      memo["round"] = handle

      expect(edit_handler.call(memo["round"], "Time.").to_a).to eq([true])
      expect(telegram_adapter.edited.first.last.body.text).to eq("Time.")
    end

    # One post is several messages and the platforms disagree about what can be
    # done to them, so a partial success is a success: the edit landed where an
    # edit is possible at all.
    it "edits the copies whose platform has edits, and leaves the rest alone" do
      handle = post_handler.call({ "text" => "Round one." })

      expect(edit_handler.call(handle, "Round two.").to_a).to eq([true])
      expect(telegram_adapter.edited.length).to eq(1)
      expect(irc_adapter.edited).to be_empty
    end

    it "answers false where no platform in the room can edit at all" do
      irc_only = Rubotty::Scripting::Handle.of(Rubotty::Core::MessageRef.new("irc-general", "x1"))

      ok, reason = edit_handler.call(irc_only, "Round two.").to_a

      expect(ok).to be(false)
      expect(reason).to include("edit")
    end

    it "removes the copies whose platform can remove them" do
      handle = post_handler.call({ "text" => "Round one." })

      expect(delete_handler.call(handle).to_a).to eq([true])
      expect(telegram_adapter.deleted.length).to eq(1)
      expect(irc_adapter.deleted).to be_empty
    end

    it "reacts where the platform holds reactions, and answers false where none does" do
      expect(react_handler.call(Rubotty::Scripting::Handle.of(incoming.ref), "\u{1F44D}").to_a).to eq([true])
      expect(telegram_adapter.syncs.first[:desired].map(&:emoji)).to eq(["\u{1F44D}"])

      irc_only = Rubotty::Scripting::Handle.of(Rubotty::Core::MessageRef.new("irc-general", "x1"))
      ok, reason = react_handler.call(irc_only, "\u{1F44D}").to_a
      expect(ok).to be(false)
      expect(reason).to include("holds reactions")
    end

    it "refuses a reaction with no emoji" do
      expect(react_handler.call(Rubotty::Scripting::Handle.of(incoming.ref), " ").to_a.first).to be(false)
    end

    # A handle is encoded rather than signed, so this is the check that makes
    # forging one pointless: the endpoints have to be ones this invocation is
    # already allowed to speak on.
    it "does nothing to a message in a room this script is not running in" do
      elsewhere = Rubotty::Scripting::Handle.of(
        Rubotty::Core::MessageRef.new("tg-somewhere-else", "999")
      )

      expect(delete_handler.call(elsewhere).to_a.first).to be(false)
      expect(edit_handler.call(elsewhere, "no").to_a.first).to be(false)
      expect(react_handler.call(elsewhere, "\u{1F44D}").to_a.first).to be(false)
      expect(telegram_adapter.deleted).to be_empty
      expect(telegram_adapter.edited).to be_empty
      expect(telegram_adapter.syncs).to be_empty
    end

    it "says so for a handle that names nothing at all" do
      expect(delete_handler.call("not a handle").to_a.first).to be(false)
      expect(edit_handler.call(nil, "text").to_a.first).to be(false)
    end
  end
end
