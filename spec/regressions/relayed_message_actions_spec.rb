# frozen_string_literal: true

require "spec_helper"

# Actions arriving on a relayed copy rather than on the original, which is what a
# moderator working in the Discord channel does almost every time. Two defects
# made these vanish: the loop guard treated one of our own refs as an echo for
# every kind, and the router only ever looked forward through the message map.
RSpec.describe "actions on relayed copies" do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  subject(:router) do
    Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter),
      storage: storage, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
    )
  end

  # A message that came from Telegram and was relayed to Discord.
  before { storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r") }

  describe "deleting the relayed copy" do
    def delete_copy
      router.handle(
        Rubotty::Core::Message.new(
          kind: :delete, ref: ref("dc", "d1"), origin: dc,
          author: Rubotty::Core::Author.new(kind: :system)
        )
      )
    end

    # A moderator removes the relayed copy on Discord and expects the Telegram
    # original to go with it. TediCross did this in production.
    it "propagates back to the original" do
      delete_copy
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "forgets the mapping afterwards" do
      delete_copy
      expect(storage.counterparts(ref("tg", "5"))).to be_empty
    end
  end

  describe "deleting the original" do
    it "still propagates forward to the copy" do
      router.handle(
        Rubotty::Core::Message.new(
          kind: :delete, ref: ref("tg", "5"), origin: tg,
          author: Rubotty::Core::Author.new(kind: :system)
        )
      )
      expect(adapter.deleted).to eq([%w[dc d1]])
    end
  end

  describe "the loop guard" do
    subject(:guard) { loop_guard }

    def event(kind, ref_value)
      Rubotty::Core::Message.new(
        kind: kind, ref: ref_value, origin: dc, author: author(native_id: "human")
      )
    end

    # A NEW message whose id we just wrote really is our echo.
    it "still treats an arriving chat message on one of our ids as an echo" do
      expect(guard.echo?(event(:chat, ref("dc", "d1")))).to eq(:in_message_map)
    end

    # Only the bridge can edit a message the bridge posted, so an edit event on
    # one of our copies is our own write coming back.
    it "still treats an edit of one of our own messages as an echo" do
      expect(guard.echo?(event(:edit, ref("dc", "d1")))).to eq(:in_message_map)
    end

    it "does not treat a reaction on one of our messages as an echo" do
      expect(guard.echo?(event(:reaction_add, ref("dc", "d1")))).to be_nil
      expect(guard.echo?(event(:reaction_remove, ref("dc", "d1")))).to be_nil
    end

    it "does not treat a delete of one of our messages as an echo" do
      expect(guard.echo?(event(:delete, ref("dc", "d1")))).to be_nil
    end

    # Authorship still applies to every kind: our own bot reacting is an echo
    # whatever it reacted to.
    it "still drops anything authored by our own account" do
      guard.register_identity(:fake, "default", "bot-1")
      ours = Rubotty::Core::Message.new(
        kind: :reaction_add, ref: ref("dc", "d1"), origin: dc,
        author: author(native_id: "bot-1")
      )
      expect(guard.echo?(ours)).to eq(:self_authored)
    end

    it "still drops something we delivered moments ago" do
      guard.note_delivery("dc", "d9")
      expect(guard.echo?(event(:chat, ref("dc", "d9")))).to eq(:recently_delivered)
    end
  end
end
