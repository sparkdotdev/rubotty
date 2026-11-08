# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# One set of examples, run against every backend. A backend that passes these
# satisfies the contract in Rubotty::Storage::Base.
RSpec.shared_examples "a message map" do
  let(:source) { ref("tg", "100") }
  let(:destination) { ref("dc", "900") }

  before { store.migrate! }
  after { store.close }

  it "finds what a source was relayed to" do
    store.record(source: source, destination: destination, room_id: "r")
    expect(store.counterparts(source)).to eq([destination])
  end

  it "records one source fanned out to several destinations" do
    store.record(source: source, destination: destination, room_id: "r")
    store.record(source: source, destination: ref("irc", "5"), room_id: "r")
    expect(store.counterparts(source)).to contain_exactly(destination, ref("irc", "5"))
  end

  it "filters counterparts by endpoint" do
    store.record(source: source, destination: destination, room_id: "r")
    store.record(source: source, destination: ref("irc", "5"), room_id: "r")
    expect(store.counterparts(source, endpoint_id: "irc")).to eq([ref("irc", "5")])
  end

  it "returns nothing for an unknown source" do
    expect(store.counterparts(ref("tg", "does-not-exist"))).to be_empty
  end

  it "resolves the reverse direction" do
    store.record(source: source, destination: destination, room_id: "r")
    expect(store.origins(destination)).to eq([source])
  end

  # The restart safe half of loop prevention.
  it "knows whether a ref is something we wrote" do
    store.record(source: source, destination: destination, room_id: "r")
    expect(store.destination?(destination)).to be(true)
    expect(store.destination?(source)).to be(false)
  end

  it "is idempotent on the same pair, so a retry does not duplicate" do
    3.times { store.record(source: source, destination: destination, room_id: "r") }
    expect(store.counterparts(source).size).to eq(1)
  end

  it "forgets both directions of a ref" do
    store.record(source: source, destination: destination, room_id: "r")
    store.forget(source)
    expect(store.counterparts(source)).to be_empty
    expect(store.origins(destination)).to be_empty
  end

  describe "expiry" do
    it "hides an expired row from reads even before it is purged" do
      store.record(source: source, destination: destination, room_id: "r",
                   expires_at: Time.now - 60)
      expect(store.counterparts(source)).to be_empty
    end

    it "keeps a row that has not expired" do
      store.record(source: source, destination: destination, room_id: "r",
                   expires_at: Time.now + 3600)
      expect(store.counterparts(source)).to eq([destination])
    end

    it "keeps a row with no expiry at all" do
      store.record(source: source, destination: destination, room_id: "r", expires_at: nil)
      expect(store.counterparts(source)).to eq([destination])
    end

    it "purges expired rows and reports how many" do
      store.record(source: source, destination: destination, room_id: "r", expires_at: Time.now - 1)
      store.record(source: ref("tg", "2"), destination: ref("dc", "2"), room_id: "r",
                   expires_at: Time.now + 3600)
      expect(store.purge).to eq(1)
      expect(store.size).to eq(1)
    end
  end

  # What reaction state hangs its own expiry off, so a reaction added late in a
  # message's life cannot outlive the map row it belongs to.
  describe "the expiry a row carries" do
    it "reports the expiry of a row named as the source" do
      expiry = Time.now + 3600
      store.record(source: source, destination: destination, room_id: "r", expires_at: expiry)
      expect(store.map_expiry(source)).to be_within(1).of(expiry)
    end

    it "reports it from the destination side too, an action arriving on either copy" do
      expiry = Time.now + 3600
      store.record(source: source, destination: destination, room_id: "r", expires_at: expiry)
      expect(store.map_expiry(destination)).to be_within(1).of(expiry)
    end

    it "takes the furthest expiry when a source fanned out to several destinations" do
      furthest = Time.now + 7200
      store.record(source: source, destination: destination, room_id: "r", expires_at: Time.now + 60)
      store.record(source: source, destination: ref("irc", "5"), room_id: "r", expires_at: furthest)
      expect(store.map_expiry(source)).to be_within(1).of(furthest)
    end

    it "answers nil for a ref the map holds nothing for" do
      expect(store.map_expiry(ref("tg", "does-not-exist"))).to be_nil
    end

    it "answers nil when a row never expires, there being no expiry to inherit" do
      store.record(source: source, destination: destination, room_id: "r", expires_at: nil)
      expect(store.map_expiry(source)).to be_nil
    end

    it "ignores a row that has already expired" do
      store.record(source: source, destination: destination, room_id: "r", expires_at: Time.now - 60)
      expect(store.map_expiry(source)).to be_nil
    end
  end

  # A mirrored reaction survives until the LAST person holding it takes it away.
  describe "reaction state" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }

    it "counts the actors holding a reaction" do
      expect(store.add_reaction(source, reaction: thumbs, actor_id: "alice")).to eq(1)
      expect(store.add_reaction(source, reaction: thumbs, actor_id: "bob")).to eq(2)
    end

    it "is idempotent when the same actor is recorded twice" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice")
      expect(store.add_reaction(source, reaction: thumbs, actor_id: "alice")).to eq(1)
    end

    it "keeps the reaction while another actor still holds it" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice")
      store.add_reaction(source, reaction: thumbs, actor_id: "bob")
      expect(store.remove_reaction(source, reaction: thumbs, actor_id: "alice")).to eq(1)
      expect(store.reactions_on(source)).to eq([thumbs])
    end

    it "reports zero once the last actor removes it" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice")
      expect(store.remove_reaction(source, reaction: thumbs, actor_id: "alice")).to eq(0)
      expect(store.reactions_on(source)).to be_empty
    end

    it "tracks different emoji independently" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice")
      store.add_reaction(source, reaction: party, actor_id: "bob")
      expect(store.reactions_on(source)).to eq([thumbs, party])
      store.remove_reaction(source, reaction: thumbs, actor_id: "alice")
      expect(store.reactions_on(source)).to eq([party])
    end

    # Telegram allows a bot exactly one reaction per message, so the order has
    # to be stable or the mirror flickers whenever anyone reacts.
    it "returns reactions oldest first" do
      store.add_reaction(source, reaction: party, actor_id: "alice")
      store.add_reaction(source, reaction: thumbs, actor_id: "bob")
      expect(store.reactions_on(source).map(&:emoji)).to eq(%w[🎉 👍])
    end

    it "tracks reactions per message" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice")
      expect(store.reactions_on(ref("tg", "other"))).to be_empty
    end

    it "distinguishes a custom emoji from a unicode one" do
      custom = Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot")
      store.add_reaction(source, reaction: thumbs, actor_id: "alice")
      store.add_reaction(source, reaction: custom, actor_id: "alice")
      expect(store.reactions_on(source).size).to eq(2)
    end

    it "expires reaction state on the same TTL as the message map" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice", expires_at: Time.now - 1)
      expect(store.reactions_on(source)).to be_empty
    end

    it "purges expired reaction rows" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice", expires_at: Time.now - 1)
      expect(store.purge).to be >= 1
    end

    it "forgets reactions when the message is forgotten" do
      store.add_reaction(source, reaction: thumbs, actor_id: "alice")
      store.forget(source)
      expect(store.reactions_on(source)).to be_empty
    end

    # The per-person view of the same rows: what one person still holds is what
    # decides whether the notice line about them has anything left to say.
    describe "#reactions_by" do
      it "answers only what that person holds" do
        store.add_reaction(source, reaction: thumbs, actor_id: "alice")
        store.add_reaction(source, reaction: party, actor_id: "bob")
        expect(store.reactions_by(source, actor_id: "alice")).to eq([thumbs])
      end

      it "is empty once they have taken their last one off, even while others hold theirs" do
        store.add_reaction(source, reaction: thumbs, actor_id: "alice")
        store.add_reaction(source, reaction: thumbs, actor_id: "bob")
        store.remove_reaction(source, reaction: thumbs, actor_id: "alice")
        expect(store.reactions_by(source, actor_id: "alice")).to be_empty
        expect(store.reactions_by(source, actor_id: "bob")).to eq([thumbs])
      end

      it "returns what one person holds oldest first" do
        store.add_reaction(source, reaction: party, actor_id: "alice")
        store.add_reaction(source, reaction: thumbs, actor_id: "alice")
        expect(store.reactions_by(source, actor_id: "alice").map(&:emoji)).to eq(%w[🎉 👍])
      end

      it "is empty for somebody who has never reacted there" do
        store.add_reaction(source, reaction: thumbs, actor_id: "alice")
        expect(store.reactions_by(source, actor_id: "nobody")).to be_empty
      end

      it "hides an expired row, the same as the aggregate does" do
        store.add_reaction(source, reaction: thumbs, actor_id: "alice", expires_at: Time.now - 1)
        expect(store.reactions_by(source, actor_id: "alice")).to be_empty
      end
    end

    # A bulk clear reported with no author has to take down every actor's
    # claim at once, leaving no named holder behind.
    describe "#clear_reactions" do
      it "drops every actor's hold on one emoji, leaving other emoji alone" do
        store.add_reaction(source, reaction: thumbs, actor_id: "alice")
        store.add_reaction(source, reaction: thumbs, actor_id: "bob")
        store.add_reaction(source, reaction: party, actor_id: "alice")

        store.clear_reactions(source, reaction: thumbs)

        expect(store.reactions_on(source)).to eq([party])
      end

      it "drops every emoji on the message when given none" do
        store.add_reaction(source, reaction: thumbs, actor_id: "alice")
        store.add_reaction(source, reaction: party, actor_id: "bob")

        store.clear_reactions(source)

        expect(store.reactions_on(source)).to be_empty
      end

      it "leaves another message's reactions untouched" do
        other = ref("tg", "other")
        store.add_reaction(source, reaction: thumbs, actor_id: "alice")
        store.add_reaction(other, reaction: thumbs, actor_id: "alice")

        store.clear_reactions(source)

        expect(store.reactions_on(other)).to eq([thumbs])
      end
    end
  end

  # The exactly-once relay claim: the first claim of a source event wins, a second
  # is denied, and a release lets a later event re-claim. Atomic across instances on
  # the shared-database backends, single-process on memory and pstore.
  describe "relay claims" do
    it "lets the first claim of a source event win" do
      expect(store.claim_relay(source: source, operation: "new")).to be(true)
    end

    it "denies a second claim of the same event, so a duplicate relay is a no-op" do
      store.claim_relay(source: source, operation: "new")
      expect(store.claim_relay(source: source, operation: "new")).to be(false)
    end

    # The read the paced backfill makes before re-feeding a historical message: it
    # must reflect an existing claim WITHOUT taking one.
    it "reports whether a source event is already claimed, without taking a claim" do
      expect(store.relay_claimed?(source: source, operation: "new")).to be(false)
      store.claim_relay(source: source, operation: "new")
      expect(store.relay_claimed?(source: source, operation: "new")).to be(true)
      # The check did not consume the claim, so a genuine claim would still lose.
      expect(store.claim_relay(source: source, operation: "new")).to be(false)
    end

    it "scopes relay_claimed? by operation and community exactly as the claim" do
      store.claim_relay(source: source, operation: "new", community: "a")
      expect(store.relay_claimed?(source: source, operation: "new", community: "a")).to be(true)
      expect(store.relay_claimed?(source: source, operation: "new", community: "b")).to be(false)
      expect(store.relay_claimed?(source: source, operation: "delete", community: "a")).to be(false)
    end

    it "keeps distinct operations on one message independent" do
      expect(store.claim_relay(source: source, operation: "new")).to be(true)
      expect(store.claim_relay(source: source, operation: "delete")).to be(true)
    end

    it "keeps distinct source events independent" do
      expect(store.claim_relay(source: source, operation: "new")).to be(true)
      expect(store.claim_relay(source: ref("tg", "101"), operation: "new")).to be(true)
    end

    it "scopes a claim to its community, so two tenants never collide" do
      expect(store.claim_relay(source: source, operation: "new", community: "a")).to be(true)
      expect(store.claim_relay(source: source, operation: "new", community: "b")).to be(true)
    end

    it "treats a nil community and an empty one as the same scope" do
      expect(store.claim_relay(source: source, operation: "new", community: nil)).to be(true)
      expect(store.claim_relay(source: source, operation: "new", community: "")).to be(false)
    end

    it "releases a claim so a genuine later event can re-claim it" do
      store.claim_relay(source: source, operation: "react:alice:emoji:👍")
      expect(store.claim_relay(source: source, operation: "react:alice:emoji:👍")).to be(false)
      store.release_relay(source: source, operation: "react:alice:emoji:👍")
      expect(store.claim_relay(source: source, operation: "react:alice:emoji:👍")).to be(true)
    end

    it "ignores a release of a claim that was never taken" do
      expect { store.release_relay(source: source, operation: "new") }.not_to raise_error
      expect(store.claim_relay(source: source, operation: "new")).to be(true)
    end

    # Backfill asks where to resume from. nil means "no idea", never "never",
    # which is why the two in-process backends may answer nil throughout.
    it "answers nil for an endpoint that has claimed nothing" do
      expect(store.last_relay_at(endpoint: "tg", community: "a")).to be_nil
    end

    it "reports the newest claim from an endpoint, or nil where it keeps no clock" do
      store.claim_relay(source: source, operation: "new", community: "a")
      answer = store.last_relay_at(endpoint: source.endpoint_id, community: "a")

      expect(answer).to be_nil.or be_within(120).of(Time.now)
    end

    it "prunes expired claims so the table cannot grow without bound" do
      store.claim_relay(source: source, operation: "new", expires_at: Time.now - 1)
      expect(store.purge).to be >= 1
    end

    it "keeps a claim with no expiry through a purge" do
      store.claim_relay(source: source, operation: "new", expires_at: nil)
      store.purge
      expect(store.claim_relay(source: source, operation: "new")).to be(false)
    end

    # Two overlapping instances, or a redelivery racing an in-flight relay, must
    # produce exactly one winner for a source event.
    it "yields exactly one winner when many callers race the same event" do
      gate = Queue.new
      threads = Array.new(12) do
        Thread.new do
          gate.pop
          store.claim_relay(source: ref("tg", "race"), operation: "new")
        end
      end
      12.times { gate << :go }
      results = threads.map(&:value)
      expect(results.count(true)).to eq(1)
      expect(results.count(false)).to eq(11)
    end
  end

  # A sighting returns how many DISTINCT channels have carried one author's
  # fingerprint inside the window, keyed independently by community, author and
  # fingerprint, expiring on the window and swept by purge.
  describe "multipost fingerprints" do
    let(:now) { Time.now }

    def sighting(channel:, community: "c", author: "tg:u1", fingerprint: "fp", at: now, window: 300)
      store.record_multipost(
        community: community, author: author, fingerprint: fingerprint,
        channel: channel, now: at, window_seconds: window
      )
    end

    it "counts a single channel for a first sighting" do
      expect(sighting(channel: "ch-a")).to eq(1)
    end

    it "counts distinct channels for one author and fingerprint within the window" do
      expect(sighting(channel: "ch-a", at: now)).to eq(1)
      expect(sighting(channel: "ch-b", at: now + 10)).to eq(2)
      expect(sighting(channel: "ch-c", at: now + 20)).to eq(3)
    end

    it "does not double-count a repeat in a channel already seen" do
      expect(sighting(channel: "ch-a", at: now)).to eq(1)
      expect(sighting(channel: "ch-a", at: now + 5)).to eq(1)
      expect(sighting(channel: "ch-b", at: now + 10)).to eq(2)
    end

    it "ages a sighting out once it falls outside the window" do
      expect(sighting(channel: "ch-a", at: now, window: 300)).to eq(1)
      # ch-a was seen 400s ago with a 300s window, so it no longer counts.
      expect(sighting(channel: "ch-b", at: now + 400, window: 300)).to eq(1)
    end

    it "keeps distinct authors independent" do
      expect(sighting(channel: "ch-a", author: "tg:u1")).to eq(1)
      expect(sighting(channel: "ch-b", author: "tg:u2")).to eq(1)
    end

    it "keeps distinct fingerprints independent" do
      expect(sighting(channel: "ch-a", fingerprint: "one")).to eq(1)
      expect(sighting(channel: "ch-b", fingerprint: "two")).to eq(1)
    end

    it "keeps distinct communities independent, so two tenants never collide" do
      expect(sighting(channel: "ch-a", community: "x")).to eq(1)
      expect(sighting(channel: "ch-a", community: "y")).to eq(1)
    end

    it "purges expired fingerprint rows so the state cannot grow without bound" do
      sighting(channel: "ch-a", at: now - 400, window: 300)
      expect(store.purge).to be >= 1
    end
  end

  # A handful of bytes that must survive a restart, currently only the last startup
  # announcement time, which stops a crash looping bridge announcing every restart.
  describe "key value state" do
    it "returns nothing for a key never written" do
      expect(store.get_state("nope")).to be_nil
    end

    it "round trips a value" do
      store.put_state("k", "v")
      expect(store.get_state("k")).to eq("v")
    end

    it "overwrites an existing key rather than duplicating it" do
      store.put_state("k", "first")
      store.put_state("k", "second")
      expect(store.get_state("k")).to eq("second")
    end

    it "hides an expired value" do
      store.put_state("k", "v", expires_at: Time.now - 1)
      expect(store.get_state("k")).to be_nil
    end

    it "keeps a value that has not expired" do
      store.put_state("k", "v", expires_at: Time.now + 3600)
      expect(store.get_state("k")).to eq("v")
    end

    it "purges expired state" do
      store.put_state("k", "v", expires_at: Time.now - 1)
      expect(store.purge).to be >= 1
    end

    it "keeps separate keys separate" do
      store.put_state("a", "1")
      store.put_state("b", "2")
      expect([store.get_state("a"), store.get_state("b")]).to eq(%w[1 2])
    end
  end

  it "keeps ids as opaque strings, so Discord snowflakes survive intact" do
    snowflake = "8000000000000000009"
    store.record(source: source, destination: ref("dc", snowflake), room_id: "r")
    expect(store.counterparts(source).first.native_id).to eq(snowflake)
  end
end

RSpec.describe Rubotty::Storage::Memory do
  subject(:store) { described_class.new }

  it_behaves_like "a message map"
end

# The default driver, and the one that runs everywhere, SQLite needing no service.
RSpec.describe Rubotty::Storage::SequelStore, "on sqlite" do
  let(:tmpdir) { Dir.mktmpdir("rubotty-sqlite") }

  subject(:store) do
    Rubotty::Storage::Factory.build({ driver: :sqlite, path: File.join(tmpdir, "map.sqlite3") })
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  it_behaves_like "a message map"

  it "says where its file lives" do
    expect(store.describe).to include("sqlite")
  end
end

# Runs only when a PostgreSQL is available. CI provides one.
RSpec.describe Rubotty::Storage::SequelStore, "on postgres", if: ENV["TEST_DATABASE_URL"] do
  subject(:store) do
    Rubotty::Storage::Factory.build(
      { driver: :pg, url_env: "TEST_DATABASE_URL", auto_migrate: false }, env: ENV
    )
  end

  before { Rubotty::Storage::Schema.drop(store.db) }

  it_behaves_like "a message map"
end

# Runs only when a MariaDB is available. CI's MariaDB storage job provides one and
# installs the opt-in ruby-mysql driver.
RSpec.describe Rubotty::Storage::SequelStore, "on mariadb", if: ENV["TEST_MYSQL_DATABASE_URL"] do
  subject(:store) do
    Rubotty::Storage::Factory.build(
      { driver: :mdb, url_env: "TEST_MYSQL_DATABASE_URL", auto_migrate: false }, env: ENV
    )
  end

  before { Rubotty::Storage::Schema.drop(store.db) }

  it_behaves_like "a message map"

  it "reports itself as the mariadb backend" do
    expect(store.describe).to include("mariadb")
  end
end

RSpec.describe Rubotty::Storage::PStoreStore do
  let(:tmpdir) { Dir.mktmpdir("rubotty-pstore") }

  subject(:store) do
    Rubotty::Storage::Factory.build({ driver: :pstore, path: File.join(tmpdir, "map.pstore") })
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  it_behaves_like "a message map"

  it "warns about its limits, since they are easy to walk into" do
    expect(store.describe).to include("single process")
  end

  it "survives being reopened, which is the point of persisting at all" do
    path = File.join(tmpdir, "reopen.pstore")
    first = Rubotty::Storage::Factory.build({ driver: :pstore, path: path })
    first.record(source: ref("tg", "1"), destination: ref("dc", "2"), room_id: "r")
    second = Rubotty::Storage::PStoreStore.new(path: path)
    expect(second.counterparts(ref("tg", "1"))).to eq([ref("dc", "2")])
  end
end

RSpec.describe Rubotty::Storage::Factory do
  it "builds an in memory store" do
    expect(described_class.build({ driver: :memory })).to be_a(Rubotty::Storage::Memory)
  end

  it "defaults to sqlite, so a fresh clone runs with no external service" do
    tmpdir = Dir.mktmpdir("rubotty-default")
    store = described_class.build({ path: File.join(tmpdir, "d.sqlite3") })
    expect(store).to be_a(Rubotty::Storage::SequelStore)
    expect(store.describe).to include("sqlite")
    FileUtils.remove_entry(tmpdir)
  end

  it "rejects an unknown driver" do
    expect { described_class.build({ driver: :redis }) }.to raise_error(Rubotty::ConfigError)
  end

  it "accepts mysql and mariadb as aliases for the mdb driver" do
    # Each resolves to the mdb builder, so the failure is the missing URL rather
    # than a ConfigError about an unknown driver. The driver gem is stubbed to a
    # no-op require so this runs without the optional mariadb group installed.
    allow(described_class).to receive(:require).and_call_original
    allow(described_class).to receive(:require).with("mysql")

    %i[mdb mariadb mysql].each do |driver|
      expect { described_class.build({ driver: driver }) }
        .to raise_error(Rubotty::ConfigError, /needs a connection URL/)
    end
  end

  it "normalises the mysql, mariadb and mysql2 schemes onto the pure-Ruby mysql adapter" do
    expect(described_class.normalise_mysql_url("mariadb://host/db")).to eq("mysql://host/db")
    expect(described_class.normalise_mysql_url("mysql2://host/db")).to eq("mysql://host/db")
    expect(described_class.normalise_mysql_url("mysql://host/db")).to eq("mysql://host/db")
  end

  it "tells the operator which bundle group to enable when the mariadb driver is missing" do
    allow(described_class).to receive(:require).and_call_original
    allow(described_class).to receive(:require).with("mysql")
                                               .and_raise(LoadError, "cannot load such file -- mysql")

    expect { described_class.build({ driver: :mdb, url: "mysql://h/d" }) }
      .to raise_error(Rubotty::StorageError, /bundle config set --local with mariadb/)
  end

  # Exercised through connection_url rather than build, because the pg gem sits in
  # an optional bundle group and is not installed by default.
  it "reads the connection URL from the named environment variable" do
    expect(described_class.connection_url({ url_env: "DB" }, { "DB" => "postgres://h/d" }))
      .to eq("postgres://h/d")
  end

  it "reports an unset URL variable by name" do
    expect { described_class.connection_url({ url_env: "NOPE" }, {}) }
      .to raise_error(Rubotty::ConfigError, /NOPE is not set/)
  end

  it "returns nothing when no URL is configured at all, so the caller can explain" do
    expect(described_class.connection_url({}, {})).to be_nil
  end

  it "tells the operator which bundle group to enable when a driver is missing" do
    # Force the LoadError branch rather than relying on pg being uninstalled: the CI
    # job that installs pg gets past the require and fails on DNS instead. `sequel`
    # is allowed through, since the rescue clauses name Sequel::Error and Ruby
    # resolves a rescued constant at rescue time.
    allow(described_class).to receive(:require).and_call_original
    allow(described_class).to receive(:require).with("pg")
                                               .and_raise(LoadError, "cannot load such file -- pg")

    expect { described_class.build({ driver: :pg, url: "postgres://h/d" }) }
      .to raise_error(Rubotty::StorageError, /bundle config set --local with postgres/)
  end

  it "normalises the postgresql scheme that some providers hand out" do
    expect(described_class.normalise_postgres_url("postgresql://host/db")).to eq("postgres://host/db")
  end
end
