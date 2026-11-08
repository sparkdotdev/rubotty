# frozen_string_literal: true

require "spec_helper"

# /unpin has two forms. Replied to a message it takes that one pin off, which
# is what it always did. Naming a room, or "all", it clears every pin there
# instead, through the separate action adapters implement for it. The argument
# is what tells them apart, so neither form can be reached by accident.
RSpec.describe Rubotty::Features::Moderation, "/unpin naming a room" do
  let(:lounge_tg) { endpoint("lounge-tg") }
  let(:lounge_dc) { endpoint("lounge-dc") }
  let(:offtopic) { endpoint("offtopic-tg") }
  let(:elsewhere) { endpoint("other-tenant-tg") }

  let(:lounge) { room("lounge", lounge_tg, lounge_dc, community_id: 7) }
  let(:offtopic_room) { room("offtopic", offtopic, community_id: 7, label: "Off Topic") }
  let(:other_tenant) { room("lounge", elsewhere, community_id: 99) }

  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:storage) { Rubotty::Storage::Memory.new }

  let(:operator) do
    Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["op-1"] }, community_id: 7)
  end
  let(:operators) { Rubotty::Core::Moderation::Directory.new([operator]) }

  # Enough of a community for the feature: the id room scoping is checked in,
  # the directory the issuer resolves against, and a settings hash for the
  # acknowledgement window lookup.
  let(:community) do
    Struct.new(:id, :slug, :operators, :settings, keyword_init: true)
          .new(id: 7, slug: "sample", operators: operators, settings: {})
  end

  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::TYPED_ACTIONS, logger: Rubotty::Log.null)
  end

  def feature
    described_class.new(
      topology: topology(lounge, offtopic_room, other_tenant), adapters: adapters, storage: storage,
      logger: Rubotty::Log.null, commands: commands
    )
  end

  def run(text, author_id: "op-1")
    msg = message(lounge_tg, text: text, native_id: "cmd-1",
                             author: author(native_id: author_id, username: "#{author_id}_handle"))
    feature.call(Rubotty::Features::Context.new(message: msg, community: community))
  end

  def swept = adapter.moderations.select { |m| m[:action] == :unpinall }.map { |m| m[:endpoint_id] }

  it "sweeps every endpoint in the room it names" do
    run("/unpin lounge")

    expect(swept).to contain_exactly("lounge-tg", "lounge-dc")
  end

  it "does not touch a room it did not name" do
    run("/unpin lounge")

    expect(swept).not_to include("offtopic-tg")
  end

  it "sweeps every room in the community when given all" do
    run("/unpin all")

    expect(swept).to contain_exactly("lounge-tg", "lounge-dc", "offtopic-tg")
  end

  # The widening reads room.community_id, so a second tenant's room that happens
  # to share the room key "lounge" must stay out of the sweep.
  it "never reaches another tenant's rooms" do
    run("/unpin all")

    expect(swept).not_to include("other-tenant-tg")
  end

  it "sweeps only the rooms a scoped operator may act in" do
    scoped = Rubotty::Core::Moderation::Operator.new(
      name: "Scoped", identities: { fake: ["op-1"] }, rooms: ["lounge"], community_id: 7
    )
    allow(community).to receive(:operators).and_return(Rubotty::Core::Moderation::Directory.new([scoped]))

    run("/unpin all")

    expect(swept).to contain_exactly("lounge-tg", "lounge-dc")
  end

  # Naming a room is a target, so the parser must not demand a reply as well.
  it "runs without replying to anything" do
    expect(run("/unpin all")).to be_halt
    expect(swept).not_to be_empty
  end

  # Bare it is still the old verb, which needs a message to act on. Nothing is
  # swept: an operator who forgot to reply must not clear the room instead.
  it "still refuses a bare /unpin that replies to nothing" do
    run("/unpin")

    expect(swept).to be_empty
  end

  # The form it always had, unchanged: one pin, off the message replied to.
  it "still unpins just the message it was a reply to" do
    msg = message(lounge_tg, text: "/unpin", native_id: "cmd-1",
                             reply_to: ref("lounge-tg", "900"),
                             author: author(native_id: "op-1", username: "op-1_handle"))
    feature.call(Rubotty::Features::Context.new(message: msg, community: community))

    ordinary = adapter.moderations.select { |m| m[:action] == :unpin }
    expect(ordinary.map { |m| m[:native_id] }).to include("900")
    expect(swept).to be_empty
  end

  # The word rubotty used to answer, now folded into /unpin, so somebody who
  # learned it is told rather than left typing into the void.
  it "no longer answers the separate verb it replaced" do
    run("/unpinall all")

    expect(swept).to be_empty
  end

  it "refuses a member who is not an operator" do
    run("/unpin lounge", author_id: "member-9")

    expect(swept).to be_empty
  end

  # The point of naming one: an operator clears a room from wherever they are,
  # rather than having to go and stand in it first.
  it "sweeps a room named by its key, from another room" do
    run("/unpin offtopic")

    expect(swept).to contain_exactly("offtopic-tg")
  end

  # A label is what an operator actually sees, and on a phone they will not
  # match its case or its punctuation.
  it "sweeps a room named by its label, however it was typed" do
    run("/unpin off topic")

    expect(swept).to contain_exactly("offtopic-tg")
  end

  # A typo must not read as a permission the operator has lost.
  it "says it does not know a room rather than sweeping anything" do
    run("/unpin lounje")

    expect(swept).to be_empty
  end

  # The other tenant's room carries the same key, so naming it has to resolve
  # within this community and no further.
  it "resolves a named room inside this community only" do
    run("/unpin lounge")

    expect(swept).to contain_exactly("lounge-tg", "lounge-dc")
  end
end
