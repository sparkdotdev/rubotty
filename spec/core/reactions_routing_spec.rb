# frozen_string_literal: true

require "spec_helper"

# Reactions mirror as aggregate STATE, so a mirror must survive until the LAST
# person holding it removes theirs.
RSpec.describe "reaction routing" do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  subject(:router) do
    Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: loop_guard,
      logger: Rubotty::Log.null,
      ttl: 3600
    )
  end

  let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
  let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }

  # A reaction can only be mirrored onto a message we actually relayed.
  before { storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r") }

  def react(kind, reaction, actor)
    router.handle(
      Rubotty::Core::Message.new(
        kind: kind,
        ref: ref("tg", "5"),
        origin: tg,
        author: author(native_id: actor),
        reaction: reaction
      )
    )
  end

  it "mirrors a reaction onto the relayed copy" do
    react(:reaction_add, thumbs, "alice")
    expect(adapter.syncs.last).to include(endpoint_id: "dc", native_id: "d1")
    expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["👍"])
  end

  it "removes the mirror when the only person holding it takes it away" do
    react(:reaction_add, thumbs, "alice")
    react(:reaction_remove, thumbs, "alice")
    expect(adapter.syncs.last[:desired]).to be_empty
  end

  it "keeps the mirror while a second person still holds the reaction" do
    react(:reaction_add, thumbs, "alice")
    react(:reaction_add, thumbs, "bob")
    react(:reaction_remove, thumbs, "alice")
    expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["👍"])
  end

  it "does not call the adapter at all when the aggregate state is unchanged" do
    react(:reaction_add, thumbs, "alice")
    before = adapter.syncs.size
    react(:reaction_add, thumbs, "bob")
    expect(adapter.syncs.size).to eq(before)
  end

  # A removal releases the add's claim, so the exactly-once claim never swallows
  # a genuine re-add.
  it "mirrors a redelivered reaction add only once" do
    react(:reaction_add, thumbs, "alice")
    react(:reaction_add, thumbs, "alice")
    expect(adapter.syncs.size).to eq(1)
  end

  it "re-mirrors a reaction that is removed and then genuinely re-added" do
    react(:reaction_add, thumbs, "alice")
    react(:reaction_remove, thumbs, "alice")
    react(:reaction_add, thumbs, "alice")
    expect(adapter.syncs.size).to eq(3)
    expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["\u{1F44D}"])
  end

  it "passes the previous state so an incremental platform can diff" do
    react(:reaction_add, thumbs, "alice")
    react(:reaction_add, party, "bob")
    last = adapter.syncs.last
    expect(last[:previous].map(&:emoji)).to eq(["👍"])
    expect(last[:desired].map(&:emoji)).to eq(%w[👍 🎉])
  end

  it "ignores a reaction on a message that was never relayed" do
    router.handle(
      Rubotty::Core::Message.new(
        kind: :reaction_add, ref: ref("tg", "unmapped"), origin: tg,
        author: author(native_id: "alice"), reaction: thumbs
      )
    )
    expect(adapter.syncs).to be_empty
  end

  it "ignores an anonymous reaction, which cannot be counted per person" do
    router.handle(
      Rubotty::Core::Message.new(
        kind: :reaction_add, ref: ref("tg", "5"), origin: tg,
        author: Rubotty::Core::Author.new(kind: :channel), reaction: thumbs
      )
    )
    expect(adapter.syncs).to be_empty
  end

  # Telegram sends a count-only update instead of a per-person one wherever a
  # chat's reactions are anonymous, so this is the ONLY reaction event such a
  # chat produces. It states the whole set and names nobody holding any of it.
  describe "a count-only update, which attributes nothing" do
    def counted(*reactions)
      router.handle(
        Rubotty::Core::Message.new(
          kind: :reaction_sync, ref: ref("tg", "5"), origin: tg, reaction_set: reactions
        )
      )
    end

    it "mirrors the counted set onto the relayed copy" do
      counted(thumbs)
      expect(adapter.syncs.last).to include(endpoint_id: "dc", native_id: "d1")
      expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["👍"])
    end

    it "takes the mirror away once the count no longer carries the emoji" do
      counted(thumbs)
      counted
      expect(adapter.syncs.last[:desired]).to be_empty
    end

    it "passes the previous state so an incremental platform can diff" do
      counted(thumbs)
      counted(thumbs, party)
      expect(adapter.syncs.last[:previous].map(&:emoji)).to eq(["👍"])
      expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(%w[👍 🎉])
    end

    # The count is a snapshot and arrives repeatedly, so an unchanged one has to
    # cost nothing rather than re-pushing the same set every few minutes.
    it "does not call the adapter for a snapshot that moves nothing" do
      counted(thumbs)
      expect { counted(thumbs) }.not_to(change { adapter.syncs.size })
    end

    # The whole point of the empty actor id: it is a slot no person can occupy,
    # so it cannot take away a mirror somebody named is still holding up.
    it "leaves an emoji in place that a named person also holds" do
      react(:reaction_add, thumbs, "alice")
      counted(thumbs)
      counted
      expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["👍"])
    end

    it "does not let the anonymous slot count as a second holder" do
      counted(thumbs)
      react(:reaction_add, thumbs, "alice")
      react(:reaction_remove, thumbs, "alice")
      # Still held: the count said so, and alice leaving does not speak for it.
      expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["👍"])
    end

    it "ignores a reaction counted on a message that was never relayed" do
      router.handle(
        Rubotty::Core::Message.new(
          kind: :reaction_sync, ref: ref("tg", "unmapped"), origin: tg, reaction_set: [thumbs]
        )
      )
      expect(adapter.syncs).to be_empty
    end
  end

  # A bulk clear (Revolt's MessageRemoveReaction, Discord's remove-all and
  # remove-emoji) names nobody either, but unlike a count it does not merely
  # withhold attribution: it takes the whole aggregate down at once, named
  # actors included, because that is genuinely what happened on the platform.
  describe "a bulk clear, which attributes nothing and takes named actors with it" do
    def cleared(reaction: nil)
      router.handle(
        Rubotty::Core::Message.new(kind: :reaction_clear, ref: ref("tg", "5"), origin: tg, reaction: reaction)
      )
    end

    it "takes an emoji away even though a named person placed it" do
      react(:reaction_add, thumbs, "alice")
      react(:reaction_add, party, "alice")

      cleared(reaction: thumbs)

      expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["🎉"])
    end

    it "clears every emoji on the message when none is named" do
      react(:reaction_add, thumbs, "alice")
      react(:reaction_add, party, "bob")

      cleared

      expect(adapter.syncs.last[:desired]).to be_empty
    end

    it "does not call the adapter again once a redelivered clear finds nothing left to take" do
      react(:reaction_add, thumbs, "alice")
      cleared(reaction: thumbs)

      expect { cleared(reaction: thumbs) }.not_to(change { adapter.syncs.size })
    end

    it "ignores a clear on a message that was never relayed" do
      router.handle(
        Rubotty::Core::Message.new(kind: :reaction_clear, ref: ref("tg", "unmapped"), origin: tg, reaction: thumbs)
      )
      expect(adapter.syncs).to be_empty
    end
  end

  # A count is an aggregate with the bot's own emoji inside it and nothing
  # marking which one that is, so without this the mirror feeds itself.
  it "does not count back an emoji it mirrored onto that copy itself" do
    react_to_copy = Rubotty::Core::Message.new(
      kind: :reaction_add, ref: ref("dc", "d1"), origin: dc,
      author: author(native_id: "alice"), reaction: thumbs
    )
    router.handle(react_to_copy)
    placed = adapter.syncs.size

    router.handle(
      Rubotty::Core::Message.new(
        kind: :reaction_sync, ref: ref("tg", "5"), origin: tg, reaction_set: [thumbs]
      )
    )
    expect(adapter.syncs.size).to eq(placed)
  end

  it "respects an endpoint that has reaction mirroring disabled" do
    quiet = endpoint("dc", relay: { reactions: false })
    quiet_router = Rubotty::Core::Router.new(
      topology: topology(room("r", tg, quiet)), adapters: Hash.new(adapter),
      storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null
    )
    quiet_router.handle(
      Rubotty::Core::Message.new(
        kind: :reaction_add, ref: ref("tg", "5"), origin: tg,
        author: author(native_id: "alice"), reaction: thumbs
      )
    )
    expect(adapter.syncs).to be_empty
  end

  it "skips an adapter that cannot do reactions rather than failing" do
    plain = Fakes::RecordingAdapter.new
    plain_router = Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(plain),
      storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null
    )
    expect { plain_router.handle(
      Rubotty::Core::Message.new(
        kind: :reaction_add, ref: ref("tg", "5"), origin: tg,
        author: author(native_id: "alice"), reaction: thumbs
      )
    ) }.not_to raise_error
  end

  it "drops a reaction our own bot account made" do
    loop_guard.register_identity(:fake, "default", "bot-1")
    react(:reaction_add, thumbs, "bot-1")
    expect(adapter.syncs).to be_empty
  end

  # The map records tg:5 -> dc:d1, so a reaction arriving on dc:d1 carries a ref
  # that IS one of our own writes; treating that as an echo swallows reactions on
  # most messages in the channel.
  describe "reacting to the RELAYED copy rather than the original" do
    def react_to_copy(kind, reaction, actor)
      router.handle(
        Rubotty::Core::Message.new(
          kind: kind, ref: ref("dc", "d1"), origin: dc,
          author: author(native_id: actor), reaction: reaction
        )
      )
    end

    it "mirrors the reaction back onto the original" do
      react_to_copy(:reaction_add, thumbs, "alice")
      expect(adapter.syncs.last).to include(endpoint_id: "tg", native_id: "5")
      expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["\u{1F44D}"])
    end

    it "removes the mirror when the last holder takes it away" do
      react_to_copy(:reaction_add, thumbs, "alice")
      react_to_copy(:reaction_remove, thumbs, "alice")
      expect(adapter.syncs.last[:desired]).to be_empty
    end

    it "still keeps the mirror while somebody else holds it" do
      react_to_copy(:reaction_add, thumbs, "alice")
      react_to_copy(:reaction_add, thumbs, "bob")
      react_to_copy(:reaction_remove, thumbs, "alice")
      expect(adapter.syncs.last[:desired].map(&:emoji)).to eq(["\u{1F44D}"])
    end

    it "still drops our own bot's reaction on a relayed copy" do
      loop_guard.register_identity(:fake, "default", "bot-1")
      react_to_copy(:reaction_add, thumbs, "bot-1")
      expect(adapter.syncs).to be_empty
    end
  end
end
