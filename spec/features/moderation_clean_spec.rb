# frozen_string_literal: true

require "spec_helper"

# /clean removes what rubotty itself left standing. It can only reach what
# ControlPlane::BotMessages wrote down, because that record is the only way
# back: Telegram lets a bot read none of its own history, so a message missing
# from the record cannot be found in the room at all.
RSpec.describe Rubotty::Features::Moderation, "/clean" do
  let(:lounge_tg) { endpoint("lounge-tg") }
  let(:lounge_dc) { endpoint("lounge-dc") }
  let(:offtopic) { endpoint("offtopic-tg") }

  let(:lounge) { room("lounge", lounge_tg, lounge_dc, community_id: 7) }
  let(:offtopic_room) { room("offtopic", offtopic, community_id: 7, label: "Off Topic") }
  let(:other_tenant) { room("lounge", endpoint("other-tg"), community_id: 99) }

  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:storage) { Rubotty::Storage::Memory.new }

  let(:operator) do
    Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["op-1"] }, community_id: 7)
  end
  let(:operators) { Rubotty::Core::Moderation::Directory.new([operator]) }

  # Stands in for ControlPlane::BotMessages, holding what was posted per room
  # and forgetting a row once its message has been dealt with.
  let(:bot_messages) do
    Class.new do
      def initialize(rows) = (@rows = rows)

      attr_reader :rows

      def for_room(community_id:, room_key:)
        @rows.select { |r| r[:community_id] == community_id && r[:room_key] == room_key }
             .map { |r| Rubotty::ControlPlane::BotMessages::Entry.new(**r.slice(:endpoint_id, :native_id, :kind)) }
      end

      def forget(endpoint_id:, native_id:)
        @rows.reject! { |r| r[:endpoint_id] == endpoint_id && r[:native_id] == native_id }.nil? ? 0 : 1
      end
    end.new(recorded)
  end

  let(:recorded) do
    [
      { community_id: 7, room_key: "lounge", endpoint_id: "lounge-tg", native_id: "s1", kind: "summary" },
      { community_id: 7, room_key: "lounge", endpoint_id: "lounge-dc", native_id: "s2", kind: "summary" },
      { community_id: 7, room_key: "offtopic", endpoint_id: "offtopic-tg", native_id: "s3", kind: "summary" }
    ]
  end

  let(:community) do
    Struct.new(:id, :slug, :operators, :settings, keyword_init: true) do
      def room_key_of(_channel) = "lounge"
    end.new(id: 7, slug: "sample", operators: operators, settings: {})
  end

  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::TYPED_ACTIONS, logger: Rubotty::Log.null)
  end

  def feature(store: bot_messages)
    described_class.new(
      topology: topology(lounge, offtopic_room, other_tenant), adapters: adapters, storage: storage,
      logger: Rubotty::Log.null, commands: commands, bot_messages: store
    )
  end

  def run(text, author_id: "op-1", store: bot_messages)
    msg = message(lounge_tg, text: text, native_id: "cmd-1",
                             author: author(native_id: author_id, username: "#{author_id}_handle"))
    feature(store: store).call(Rubotty::Features::Context.new(message: msg, community: community))
  end

  def deleted = adapter.deleted.reject { |(_, native_id)| native_id == "cmd-1" }

  it "deletes every recorded message in the room it was typed in" do
    run("/clean")

    expect(deleted).to contain_exactly(["lounge-tg", "s1"], ["lounge-dc", "s2"])
  end

  it "leaves other rooms alone without the all argument" do
    run("/clean")

    expect(deleted.map(&:last)).not_to include("s3")
  end

  it "reaches every room in the community when given all" do
    run("/clean all")

    expect(deleted).to contain_exactly(["lounge-tg", "s1"], ["lounge-dc", "s2"], ["offtopic-tg", "s3"])
  end

  # A row left behind would be retried on every later sweep, against a message
  # that is already gone.
  it "forgets each row it has dealt with" do
    run("/clean all")

    expect(bot_messages.rows).to be_empty
  end

  # The point of naming one: an operator clears a room from wherever they are.
  it "cleans a room named by its key, from another room" do
    run("/clean offtopic")

    expect(deleted).to contain_exactly(["offtopic-tg", "s3"])
  end

  it "cleans a room named by its label, however it was typed" do
    run("/clean OFF TOPIC")

    expect(deleted).to contain_exactly(["offtopic-tg", "s3"])
  end

  it "says it does not know a room rather than cleaning anything" do
    run("/clean lounje")

    expect(deleted).to be_empty
    expect(bot_messages.rows.length).to eq(3)
  end

  it "refuses a member who is not an operator" do
    run("/clean", author_id: "member-9")

    expect(deleted).to be_empty
  end

  # Without a control plane there is no record, and so no way to find a bot
  # message at all; saying so is better than reporting an empty sweep.
  it "reports itself unavailable with no record to read" do
    run("/clean", store: nil)

    expect(deleted).to be_empty
  end

  it "sweeps only the rooms a scoped operator may act in" do
    scoped = Rubotty::Core::Moderation::Operator.new(
      name: "Scoped", identities: { fake: ["op-1"] }, rooms: ["lounge"], community_id: 7
    )
    allow(community).to receive(:operators).and_return(Rubotty::Core::Moderation::Directory.new([scoped]))

    run("/clean all")

    expect(deleted.map(&:last)).not_to include("s3")
  end

  # Each deletion is an API call on the token the relay shares, so a sweep of a
  # whole community stops at the ceiling and says how much is left.
  it "stops at the ceiling and leaves the rest recorded" do
    stub_const("#{described_class}::CLEAN_LIMIT", 1)

    run("/clean all")

    expect(deleted.length).to eq(1)
    expect(bot_messages.rows.length).to eq(2)
  end
end
