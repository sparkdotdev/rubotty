# frozen_string_literal: true

require "spec_helper"

# The property under test is the one an operator actually cares about: a
# message rubotty relays from Telegram into Discord must never come back
# the other way. LoopGuard documents four defences and Router adds a fifth;
# each is exercised here in isolation since any one can fail without looping.
RSpec.describe Rubotty::Core::LoopGuard do
  let(:telegram) { endpoint("tg-general", adapter: :telegram) }
  let(:discord) { endpoint("dc-general", adapter: :discord) }
  let(:clock) { -> { @now ||= Time.utc(2026, 8, 3, 1, 0, 0) } }

  subject(:guard) { described_class.new(clock: clock) }

  # Defence 2. The copy rubotty posts into Discord is authored by rubotty, so when
  # Discord echoes it back at us the author is our own account id.
  describe "self authorship" do
    before { guard.register_identity(:discord, "default", "bot-99") }

    it "drops our own copy coming back from the platform" do
      ours = message(discord, native_id: "d1", author: author(native_id: "bot-99"))

      expect(guard.echo?(ours)).to eq(:self_authored)
    end

    it "lets a real member through on the same endpoint" do
      theirs = message(discord, native_id: "d2", author: author(native_id: "human-1"))

      expect(guard.echo?(theirs)).to be_nil
    end

    # Registered per adapter, so being the author on Discord says nothing about
    # who authored something on Telegram.
    it "does not treat another adapter's ids as ours" do
      elsewhere = message(telegram, native_id: "t1", author: author(native_id: "bot-99"))

      expect(guard.echo?(elsewhere)).to be_nil
    end

    # Every kind, not just chat: our own bot reacting is still ours.
    it "applies to reactions as well as messages" do
      reaction = message(discord, native_id: "d3", kind: :reaction_add,
                                  author: author(native_id: "bot-99"))

      expect(guard.echo?(reaction)).to eq(:self_authored)
    end
  end

  # An adapter whose identity can fork (an XMPP account that fell back to a
  # different MUC nick in one room but not another, see Adapters::Xmpp,
  # issue #1498) registers every id it holds at once rather than just one.
  describe "an adapter registered under more than one id at once" do
    before { guard.register_identity(:discord, "default", %w[bridge bridge_]) }

    it "treats a message authored by either registered id as our own" do
      base_nick = message(discord, native_id: "x1", author: author(native_id: "bridge"))
      fallback_nick = message(discord, native_id: "x2", author: author(native_id: "bridge_"))

      expect(guard.echo?(base_nick)).to eq(:self_authored)
      expect(guard.echo?(fallback_nick)).to eq(:self_authored)
    end

    it "still lets a real member through under neither id" do
      theirs = message(discord, native_id: "x3", author: author(native_id: "grace"))

      expect(guard.echo?(theirs)).to be_nil
    end

    it "replaces the whole set on a later registration rather than merging into it" do
      guard.register_identity(:discord, "default", ["bridge"])
      still_registered = message(discord, native_id: "x4", author: author(native_id: "bridge"))
      no_longer_registered = message(discord, native_id: "x5", author: author(native_id: "bridge_"))

      expect(guard.echo?(still_registered)).to eq(:self_authored)
      expect(guard.echo?(no_longer_registered)).to be_nil
    end
  end

  # @own_ids used to be keyed on the adapter name alone, so a second Discord
  # account's registration overwrote the first's, and from then on defence 2
  # compared every Discord message against just one bot's id, whichever
  # account it actually arrived on.
  describe "two accounts on the same adapter" do
    let(:team_a) { endpoint("dc-a", adapter: :discord, account: "team-a") }
    let(:team_b) { endpoint("dc-b", adapter: :discord, account: "team-b") }

    before do
      guard.register_identity(:discord, "team-a", "bot-a")
      guard.register_identity(:discord, "team-b", "bot-b")
    end

    it "keeps each account's own bot id, rather than the second overwriting the first" do
      a_echo = message(team_a, native_id: "a1", author: author(native_id: "bot-a"))
      b_echo = message(team_b, native_id: "b1", author: author(native_id: "bot-b"))

      expect(guard.echo?(a_echo)).to eq(:self_authored)
      expect(guard.echo?(b_echo)).to eq(:self_authored)
    end

    it "does not check one account's message against a different account's identity" do
      cross = message(team_b, native_id: "b2", author: author(native_id: "bot-a"))

      expect(guard.echo?(cross)).to be_nil
    end
  end

  # Defence 3: a webhook posts under an arbitrary display name, so authorship
  # cannot save us. The delivery we just made is remembered instead.
  describe "the recent delivery ledger" do
    it "drops a message we just wrote, whatever name it wears" do
      guard.note_delivery("dc-general", "d10")
      echo = message(discord, native_id: "d10", author: author(native_id: "webhook-7"))

      expect(guard.echo?(echo)).to eq(:recently_delivered)
    end

    it "does not confuse the same native id on a different endpoint" do
      guard.note_delivery("dc-general", "d10")
      elsewhere = message(telegram, native_id: "d10")

      expect(guard.echo?(elsewhere)).to be_nil
    end

    it "forgets a delivery once the ttl has passed" do
      guard.note_delivery("dc-general", "d11")
      @now += described_class::DEFAULT_LEDGER_TTL + 1
      late = message(discord, native_id: "d11")

      expect(guard.echo?(late)).to be_nil
    end
  end

  # Defence 4. After a restart the ledger is empty, so the durable map is what
  # recognises a copy we wrote before we went down.
  describe "the durable message map" do
    let(:storage) { instance_double(Rubotty::Storage::Base) }

    subject(:guard) { described_class.new(storage: storage, clock: clock) }

    it "drops an id the map records as one of our destinations" do
      allow(storage).to receive(:destination?).and_return(true)

      expect(guard.echo?(message(discord, native_id: "d20"))).to eq(:in_message_map)
    end

    it "lets through an id the map has never seen" do
      allow(storage).to receive(:destination?).and_return(false)

      expect(guard.echo?(message(discord, native_id: "d21"))).to be_nil
    end

    # Failing closed here would silence the bridge during a database blip, so it
    # fails open and leans on the defences that need no storage.
    it "fails open when storage is unavailable" do
      allow(storage).to receive(:destination?).and_raise(Rubotty::StorageError.new("db down"))

      expect(guard.echo?(message(discord, native_id: "d22"))).to be_nil
    end
  end

  # A reaction or a delete names a message that already exists, and our own copy
  # is the normal target. Treating that as an echo would break the feature.
  describe "kinds where the ref names a message being acted upon" do
    it "does not treat a reaction on our own copy as an echo" do
      guard.note_delivery("dc-general", "d30")
      reaction = message(discord, native_id: "d30", kind: :reaction_add,
                         author: author(native_id: "human-1"))

      expect(guard.echo?(reaction)).to be_nil
    end

    # Only the bridge can edit what the bridge posted, so an edit of our copy
    # really is our own echo.
    it "does treat an edit of our own copy as an echo" do
      guard.note_delivery("dc-general", "d31")
      edit = message(discord, native_id: "d31", kind: :edit, author: author(native_id: "human-1"))

      expect(guard.echo?(edit)).to eq(:recently_delivered)
    end
  end

  # The ledger is in memory and unbounded growth would be a slow leak, so it is
  # capped by both age and count.
  describe "ledger bounds" do
    it "stays under the entry limit" do
      (described_class::DEFAULT_LEDGER_LIMIT + 50).times do |i|
        guard.note_delivery("dc-general", "n#{i}")
      end

      expect(guard.size).to be <= described_class::DEFAULT_LEDGER_LIMIT
    end
  end

  # Defence 6: the backstop behind the per-platform echo defences above, which
  # all miss the same way when Fluxer-style webhook recognition fails. This
  # one does not look at the message at all, only at how fast the bridge is
  # posting to one endpoint.
  describe "the post rate breaker" do
    it "lets ordinary traffic under the ceiling through" do
      results = Array.new(described_class::POST_RATE_LIMIT) { guard.check_post_rate("dc-general") }

      expect(results).to all(be_nil)
    end

    it "trips the instant a burst crosses the ceiling, once" do
      described_class::POST_RATE_LIMIT.times { guard.check_post_rate("dc-general") }

      expect(guard.check_post_rate("dc-general")).to eq(:tripped)
      expect(guard.check_post_rate("dc-general")).to eq(:open)
    end

    it "stays tripped rather than clearing once the window ages out" do
      (described_class::POST_RATE_LIMIT + 1).times { guard.check_post_rate("dc-general") }
      @now += described_class::POST_RATE_WINDOW + 1

      expect(guard.check_post_rate("dc-general")).to eq(:open)
    end

    it "tracks each endpoint on its own, so a loop on one does not silence another" do
      (described_class::POST_RATE_LIMIT + 1).times { guard.check_post_rate("dc-general") }

      expect(guard.check_post_rate("tg-general")).to be_nil
    end
  end
end
