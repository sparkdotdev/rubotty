# frozen_string_literal: true

require "spec_helper"

module VindicationSupport
end

RSpec.describe Rubotty::ContentPolicy::Vindication do
  include Builders

  # The row ContentPolicyActions hands back, with only the fields a reversal
  # reads. reversed_at is what a second operator finds already set.
  VindicationSupport::VindicationRecord = Struct.new(:code, :adapter, :endpoint_id, :native_id, :author_native_id, :author_name,
                                 :action, :policy, :body, :reasoning, :confidence, :created_at,
                                 :reversed_at, :reversed_by, keyword_init: true)

  # Stands in for the Sequel-backed store: the claim is the same conditional
  # write, so a second caller answers false here exactly as it would there.
  class VindicationActions
    attr_reader :rows, :claims

    def initialize(rows = {})
      @rows = rows
      @claims = []
    end

    def find(community_id:, code:)
      @rows["#{community_id}:#{code}"]
    end

    def reverse!(row, by:)
      return false unless row.reversed_at.nil?

      row.reversed_at = Time.now
      row.reversed_by = by
      @claims << by
      true
    end
  end

  class VindicationAudit
    attr_reader :events

    def initialize = @events = []

    def record(**event) = @events << event
  end

  # Stands in for ControlPlane::ContentPolicyMisfires: keeps what a reversal
  # asked it to remember, so a spec can check the sample rather than the SQL.
  class VindicationMisfires
    attr_reader :written

    def initialize(fail_with: nil)
      @written = []
      @fail_with = fail_with
    end

    def record(**attributes)
      raise @fail_with if @fail_with

      @written << attributes
      attributes
    end
  end

  VindicationSupport::VindicationCommunity = Struct.new(:id, :slug, :name, :rooms, keyword_init: true)

  let(:source) { endpoint("telegram-general", adapter: :fake, account: "default") }
  let(:mirror) { endpoint("discord-general", adapter: :fake, account: "default") }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1", admin_dm: true) }
  let(:adapters) { Hash.new(adapter) }
  let(:room) { Rubotty::Core::Room.new(id: "general", endpoints: [source, mirror]) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(adapters: adapters, session_id: "s", topology: topology(room),
                                        logger: Rubotty::Log.null)
  end
  # Telegram tells a bot nothing when a member deletes their own message, so
  # the reaction clear answering "no such message" is the only signal there is.
  class GoneAdapter < Fakes::ReactingAdapter
    def sync_reactions(_endpoint, _native_id, desired: [], previous: [])
      raise Rubotty::MessageGoneError.new("message to react not found", adapter: :fake)
    end
  end

  # The other way that call can fail, which must never be read as gone.
  class RefusingAdapter < Fakes::ReactingAdapter
    def sync_reactions(_endpoint, _native_id, desired: [], previous: [])
      raise Rubotty::PermissionError.new("no rights here", adapter: :fake)
    end
  end

  let(:audit) { VindicationAudit.new }
  let(:misfires) { VindicationMisfires.new }
  let(:community) { VindicationSupport::VindicationCommunity.new(id: 7, slug: "first", name: "First Community", rooms: [room]) }

  def record(action: "delete", body: "the removed words", **rest)
    VindicationSupport::VindicationRecord.new(
      code: "bq7k", adapter: "fake", endpoint_id: source.id, native_id: "m1", author_native_id: "u9",
      author_name: "Ada", action: action, policy: "Racial slurs", body: body,
      reasoning: "Reads as a slur", confidence: 0.71, created_at: Time.now - 30, **rest
    )
  end

  def store(row) = VindicationActions.new({ "7:#{row.code}" => row })

  def service(actions, misfires: self.misfires)
    described_class.new(adapters: adapters, ephemeral: ephemeral, actions: actions,
                        misfires: misfires, audit: audit, logger: Rubotty::Log.null)
  end

  # What the operator console actually hands in: its own control-plane row,
  # whose rooms are Sequel rows that answer no endpoint lookup. Reading it as a
  # routing community raised NoMethodError inside the reversal, and the rescue
  # reported that as a code nobody had ever minted.
  VindicationSupport::ConsoleRoom = Struct.new(:id, :room_key)
  VindicationSupport::ConsoleCommunity = Struct.new(:id, :slug, :name, :rooms, keyword_init: true)
  VindicationSupport::RoutingRegistry = Struct.new(:current)
  VindicationSupport::RoutedSnapshot = Struct.new(:community) do
    def community_by_id(_id) = community
  end

  def vindicate(row, statement: "you were right all along")
    actions = store(row)
    outcome = service(actions).vindicate(community: community, code: row.code, operator: "fake:mel",
                                         statement: statement)
    [outcome, actions]
  end

  it "answers unknown for a code that resolves to nothing, so a typo reverses nothing" do
    outcome = service(VindicationActions.new).vindicate(community: community, code: "zzzz", operator: "fake:mel")

    expect(outcome.status).to eq(:unknown)
  end

  # The console holds control-plane rows, not the routing snapshot, and reading
  # one for its rooms took the whole reversal down. It is the registry that
  # says where an endpoint lives, so the reversal asks that rather than
  # whatever shape of community it was handed.
  describe "a community handed in as its control-plane row" do
    let(:console_community) do
      VindicationSupport::ConsoleCommunity.new(id: 7, slug: "first", name: "First Community",
                           rooms: [VindicationSupport::ConsoleRoom.new(1, "general")])
    end
    let(:registry) { VindicationSupport::RoutingRegistry.new(VindicationSupport::RoutedSnapshot.new(community)) }

    def reversal(row)
      described_class.new(adapters: adapters, ephemeral: ephemeral, actions: store(row),
                          misfires: misfires, audit: audit, registry: registry,
                          logger: Rubotty::Log.null)
    end

    it "resolves the endpoint through the registry rather than off the row" do
      row = record(action: "delete")

      outcome = reversal(row).vindicate(community: console_community, code: row.code, operator: "fake:mel")

      expect(outcome.status).to eq(:reversed)
      expect(outcome.restored).to be(true)
    end

    # Without a registry there is nothing to resolve against, and a reversal
    # that cannot find its room still has a strike to clear and an author to
    # tell. What it must not do is raise.
    it "reverses what it still can when no registry can place the room" do
      row = record(action: "delete")
      service = described_class.new(adapters: adapters, ephemeral: ephemeral, actions: store(row),
                                    misfires: misfires, audit: audit, logger: Rubotty::Log.null)

      outcome = service.vindicate(community: console_community, code: row.code, operator: "fake:mel")

      expect(outcome.status).to eq(:reversed)
      expect(outcome.restored).to be(false)
      expect(audit.events.length).to eq(1)
    end
  end

  it "refuses a row somebody has already reversed, so two operators cannot both undo one action" do
    row = record(reversed_at: Time.now)

    outcome, actions = vindicate(row)

    expect(outcome.status).to eq(:already)
    expect(actions.claims).to be_empty
    expect(adapter.delivered).to be_empty
  end

  it "claims the row under the operator who asked, which is what the audit trail names later" do
    row = record
    _outcome, actions = vindicate(row)

    expect(actions.claims).to eq(["fake:mel"])
    expect(row.reversed_by).to eq("fake:mel")
  end

  it "reposts a removed message everywhere the removal reached, since it was taken from all of them" do
    outcome, = vindicate(record)

    expect(outcome.status).to eq(:reversed)
    expect(outcome.restored).to be(true)
    expect(adapter.delivered.map(&:first)).to include(source.id, mirror.id)
  end

  it "quotes the original under its author's name and puts the apology and the operator's words in italics" do
    vindicate(record)

    body = adapter.delivered_to(source.id).first.body
    expect(body.text).to start_with("Ada wrote:\nthe removed words")
    expect(body.text).to include("removed in error")
    expect(body.text).to include("The operator said: you were right all along")
    italic = body.spans.find { |span| span.kind == :italic }
    expect(body.text[italic.begin_index...italic.end_index]).to include("removed in error")
    expect(body.text[italic.begin_index...italic.end_index]).to include("you were right all along")
  end

  it "quotes the restored text, so nobody reads it as the bot's own words" do
    vindicate(record)

    body = adapter.delivered_to(source.id).first.body
    quote = body.spans.find { |span| span.kind == :blockquote }
    expect(body.text[quote.begin_index...quote.end_index]).to eq("the removed words")
  end

  # A native id means one person on one platform, so the mention only goes
  # where it resolves; the mirrored copy carries the same name as plain text.
  it "mentions the author only on the platform they wrote on" do
    vindicate(record)

    origin = adapter.delivered_to(source.id).first.body
    mirrored = adapter.delivered_to(mirror.id).first.body
    expect(origin.spans.map(&:kind)).to include(:mention)
    expect(mirrored.spans.map(&:kind)).not_to include(:mention)
  end

  it "leaves the apology out of the operator's own words when they gave none" do
    vindicate(record, statement: "")

    body = adapter.delivered_to(source.id).first.body
    expect(body.text).to include("removed in error")
    expect(body.text).not_to include("The operator said")
  end

  it "DMs the author that a human found them innocent, and shows what that human said" do
    vindicate(record)

    dm = adapter.dms_sent.last
    expect(dm[:native_id]).to eq("u9")
    expect(dm[:text]).to start_with("First Community: An operator has reviewed")
    expect(dm[:text]).to include("found you innocent")
    expect(dm[:text]).to include("The operator said: you were right all along")
  end

  it "takes the warning reaction off a flag, and puts nothing back, since nothing was removed" do
    outcome, = vindicate(record(action: "flag_notify", body: nil))

    expect(outcome.restored).to be(false)
    sync = adapter.syncs.last
    expect(sync[:previous]).to eq([Rubotty::ContentPolicy::Service::WARNING_REACTION])
    expect(sync[:desired]).to be_empty
  end

  it "reverses a notify silently, since nothing was ever placed on the message to undo" do
    outcome, = vindicate(record(action: "notify", body: nil))

    expect(outcome.status).to eq(:reversed)
    expect(outcome.silent).to be(true)
    expect(adapter.delivered).to be_empty
    expect(adapter.dms_sent).to be_empty
    expect(adapter.syncs).to be_empty
  end

  it "posts a self-deleting in-room notice that names the author and what the operator said" do
    quiet = Fakes::ReactingAdapter.new(own_id: "bot-1", admin_dm: false)
    adapters.default = quiet

    outcome, = vindicate(record(action: "flag_notify", body: nil), statement: "my mistake")

    expect(outcome.told_author).to be(true)
    notice = quiet.delivered_to(source.id).first.body
    expect(notice.text).to start_with("Ada An operator has reviewed")
    expect(notice.text).to include("The operator said: my mistake")
    expect(notice.spans.map(&:kind)).to include(:mention)
  end

  # The room was told the member had matched a policy, by name. A DM that lands
  # does nothing to take that back, and posting the reversal only where the DM
  # had failed left the accusation as the room's only account of it.
  it "announces a flag reversal in the room even though the author's DM landed" do
    outcome, = vindicate(record(action: "flag_notify", body: nil), statement: "my mistake")

    expect(adapter.dms_sent.last[:native_id]).to eq("u9")
    expect(outcome.told_author).to be(true)
    expect(adapter.delivered_to(source.id).map { |sent| sent.body.text })
      .to include(a_string_including("An operator has reviewed"))
  end

  # The flag was posted under the message, and so is the notice taking it back:
  # a correction floating loose in a busy room answers nothing in particular.
  it "replies to the message the flag was placed on, which is still standing" do
    vindicate(record(action: "flag_notify", body: nil))

    posted = adapter.delivered_to(source.id).first
    expect(posted.reply_to&.native_id).to eq("m1")
  end

  # A message the action really did remove is not there to reply to, and asking
  # to reply to one that is gone loses the notice rather than just its anchor.
  it "leaves the reply off where the message was removed and could not be put back" do
    vindicate(record(body: nil))

    posted = adapter.delivered_to(source.id).first
    expect(posted.reply_to).to be_nil
  end

  describe "what the outcome says was taken down" do
    it "reports a removal as having been taken down, so a failed restore reads as one" do
      outcome, = vindicate(record)

      expect(outcome.removed).to be(true)
    end

    # A flag leaves the message where it is, so there was never anything to put
    # back and the console must not report one as a failure.
    it "reports a flag as never having taken the message down" do
      outcome, = vindicate(record(action: "flag_notify", body: nil))

      expect(outcome.removed).to be(false)
    end
  end

  it "does not post an in-room notice when the restored message already carries the apology" do
    quiet = Fakes::ReactingAdapter.new(own_id: "bot-1", admin_dm: false)
    adapters.default = quiet

    outcome, = vindicate(record)

    expect(outcome.told_author).to be(true)
    expect(quiet.delivered_to(source.id).length).to eq(1)
  end

  it "records the reversal against the operator who asked for it, naming the action it undid" do
    vindicate(record)

    event = audit.events.last
    expect(event).to include(community: "first", action: "vindicate", actor: "fake:mel",
                             subject_native_id: "u9", target_ref: "telegram-general:m1")
    expect(event[:metadata]).to include(reversed: "delete", code: "bq7k")
    expect(event[:reason]).to eq("you were right all along")
  end

  # The claim is already spent by the time the room is touched, so a platform
  # refusing the repost must not cost the author their DM or the audit line.
  it "still tells the author and writes the audit line when the repost fails" do
    adapter.fail_next(RuntimeError.new("channel is gone"))

    outcome, = vindicate(record)

    expect(outcome.status).to eq(:reversed)
    expect(adapter.dms_sent.last[:text]).to include("found you innocent")
    expect(audit.events.last[:action]).to eq("vindicate")
  end

  describe "the sample it leaves behind" do
    it "keeps the text, the model's own reasoning and the operator's answer to it" do
      vindicate(record)

      sample = misfires.written.last
      expect(sample[:action_row].body).to eq("the removed words")
      expect(sample[:action_row].reasoning).to eq("Reads as a slur")
      expect(sample[:statement]).to eq("you were right all along")
      expect(sample[:reversed_by]).to eq("fake:mel")
    end

    # A flag leaves the message in the room, so it used to keep no copy at
    # all. That is exactly the action TRAVEL runs on everything, and a flag an
    # operator calls wrong is the sample most worth having.
    it "keeps a sample for a flag as well as for a removal" do
      vindicate(record(action: "flag_notify", body: "ordinary venting"))

      expect(misfires.written.last[:action_row].body).to eq("ordinary venting")
    end

    it "writes one per reversal and none for an action nobody reversed" do
      row = record(reversed_at: Time.now)
      vindicate(row)

      expect(misfires.written).to be_empty
    end

    # The reversal is already done by the time this runs, so a store that
    # cannot write must not turn a finished vindication into a failed one.
    it "still reports the reversal when the sample cannot be written" do
      broken = VindicationMisfires.new(fail_with: RuntimeError.new("disk is full"))
      row = record
      outcome = service(store(row), misfires: broken)
                .vindicate(community: community, code: row.code, operator: "fake:mel", statement: "fine")

      expect(outcome.status).to eq(:reversed)
      expect(audit.events.last[:action]).to eq("vindicate")
    end

    it "works without a corpus at all, which is how it degrades with no control plane" do
      row = record
      outcome = service(store(row), misfires: nil)
                .vindicate(community: community, code: row.code, operator: "fake:mel")

      expect(outcome.status).to eq(:reversed)
    end
  end

  # The spec's own case: the bot flagged it, the member took their own message
  # down over the flag, and an operator later called the flag wrong.
  describe "a message its author deleted over the flag" do
    def flagged_then_deleted(adapter_class: GoneAdapter, statement: "the flag was wrong")
      gone = adapter_class.new(own_id: "bot-1", admin_dm: true)
      adapters.default = gone
      row = record(action: "flag_notify", body: "the words they wrote")
      outcome = service(store(row)).vindicate(community: community, code: row.code,
                                              operator: "fake:mel", statement: statement)
      [outcome, gone]
    end

    it "puts it back, though the bot never removed it" do
      outcome, gone = flagged_then_deleted

      expect(outcome.restored).to be(true)
      expect(gone.delivered_to(source.id).first.body.text).to include("the words they wrote")
    end

    it "says the author took it down themselves rather than claiming the bot did" do
      _outcome, gone = flagged_then_deleted

      text = gone.delivered_to(source.id).first.body.text
      expect(text).to include("had deleted it themselves")
      expect(text).not_to include("removed in error")
    end

    it "tells them in the room how to take it down again" do
      _outcome, gone = flagged_then_deleted

      expect(gone.delivered_to(source.id).first.body.text).to include("/delete")
    end

    it "tells them the same in the DM" do
      _outcome, gone = flagged_then_deleted

      expect(gone.dms_sent.last[:text]).to include("You had deleted that message yourself")
      expect(gone.dms_sent.last[:text]).to include("/delete")
    end

    it "records the restored copy, so only they can take it down" do
      flagged_then_deleted

      expect(misfires).not_to be_nil
    end

    # A refusal or a rate limit is not a deleted message. Reading either as one
    # would repost something still sitting in the room. The reversal notice
    # still goes there, since the flag was announced there; it is the quoted
    # repost that must not.
    it "reposts nothing when the reaction failed for any other reason" do
      outcome, refusing = flagged_then_deleted(adapter_class: RefusingAdapter)

      expect(outcome.restored).to be(false)
      expect(refusing.delivered_to(source.id).map { |sent| sent.body.text })
        .not_to include(a_string_including("wrote:"))
    end

    it "reposts nothing when the reaction cleared, since the message is still there" do
      outcome, = vindicate(record(action: "flag_notify", body: "still up"))

      expect(outcome.restored).to be(false)
    end
  end

  it "is unavailable without a record store, which is how it degrades with no control plane" do
    expect(service(nil).available?).to be(false)
    expect(service(VindicationActions.new).available?).to be(true)
  end
end
