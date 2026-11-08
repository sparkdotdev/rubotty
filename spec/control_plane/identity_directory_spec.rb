# frozen_string_literal: true

require "spec_helper"

# Two bare communities on a migrated in-memory control plane, so per-community
# scoping is real without the whole SAMPLE seed behind it.
RSpec.describe Rubotty::ControlPlane::IdentityDirectory, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  # A fixed clock so first_seen_at / last_seen_at are assertable.
  let(:now) { Time.new(2026, 7, 23, 12, 0, 0) }

  subject(:directory) { described_class.new(models: models, clock: -> { @clock_time || now }) }

  def community(slug)
    stamp = Time.now
    id = db[:communities].insert(slug: slug, name: slug.upcase, status: "active",
                                 settings: "{}", created_at: stamp, updated_at: stamp)
    id
  end

  let(:community_id) { community("alpha") }
  let(:other_community_id) { community("beta") }

  describe "#record" do
    it "creates a directory entry for a first sighting" do
      row = directory.record(community_id: community_id, adapter: :telegram,
                             native_id: "111", username: "Ada", display: "Ada Lovelace")
      expect(row.community_id).to eq(community_id)
      expect(row.adapter).to eq("telegram")
      expect(row.native_id).to eq("111")
      expect(row.username).to eq("ada")            # lowercased
      expect(row.display_name).to eq("Ada Lovelace")
      expect(row.first_seen_at).to be_within(1).of(now)
      expect(row.last_seen_at).to be_within(1).of(now)
    end

    it "de-sigils and lowercases the handle, like the operator flow does" do
      row = directory.record(community_id: community_id, adapter: :telegram,
                             native_id: "5", username: "@Loud_Handle")
      expect(row.username).to eq("loud_handle")
    end

    it "upserts the same (community, platform, native id) rather than duplicating" do
      first = directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
      second = directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
      expect(second.id).to eq(first.id)
      expect(models.observed_identity.where(community_id: community_id).count).to eq(1)
    end

    it "updates the handle and display when they change on a later sighting" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111",
                       username: "ada", display: "Ada")
      updated = directory.record(community_id: community_id, adapter: :telegram, native_id: "111",
                                 username: "ada_renamed", display: "Ada L")
      expect(updated.username).to eq("ada_renamed")
      expect(updated.display_name).to eq("Ada L")
    end

    it "advances last_seen_at on every sighting, even a cosmetically identical one" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
      @clock_time = now + 3600
      row = directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
      expect(row.last_seen_at).to be_within(1).of(now + 3600)
      expect(row.first_seen_at).to be_within(1).of(now)  # first_seen is preserved
    end

    it "keeps an existing display when a later sighting supplies none" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111",
                       username: "ada", display: "Ada Lovelace")
      row = directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
      expect(row.display_name).to eq("Ada Lovelace")
    end

    it "records the same platform handle in two communities as two separate, scoped entries" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
      directory.record(community_id: other_community_id, adapter: :telegram, native_id: "111", username: "ada")
      expect(models.observed_identity.where(community_id: community_id).count).to eq(1)
      expect(models.observed_identity.where(community_id: other_community_id).count).to eq(1)
    end

    it "skips a sighting with no native id, having no stable key to dedupe on" do
      expect(directory.record(community_id: community_id, adapter: :telegram, native_id: nil, username: "ada"))
        .to be_nil
      expect(directory.record(community_id: community_id, adapter: :telegram, native_id: "  ", username: "ada"))
        .to be_nil
      expect(models.observed_identity.count).to eq(0)
    end

    it "does NOT create a person or a person_identity: passive observation links nothing" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "ada")
      expect(models.person.count).to eq(0)
      expect(models.person_identity.count).to eq(0)
    end
  end

  describe "#search" do
    before do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111",
                       username: "ada", display: "Ada Lovelace")
      directory.record(community_id: community_id, adapter: :discord, native_id: "999",
                       username: "adadev", display: "Ada on Discord")
      directory.record(community_id: community_id, adapter: :telegram, native_id: "222",
                       username: "bob", display: "Bob Smith")
      # A different community's entry must never leak into a community's search.
      directory.record(community_id: other_community_id, adapter: :telegram, native_id: "111",
                       username: "ada", display: "Ada Elsewhere")
    end

    it "matches a handle substring, scoped to the community" do
      results = directory.search(community_id: community_id, query: "ada")
      expect(results.map(&:username)).to contain_exactly("ada", "adadev")
    end

    # /find hands the query straight to LIKE, so a metacharacter would otherwise
    # match anything and return the whole directory.
    describe "a query carrying LIKE metacharacters" do
      it "treats a percent as a literal, not as everything" do
        expect(directory.search(community_id: community_id, query: "%")).to be_empty
      end

      it "treats an underscore as a literal, not as any character" do
        expect(directory.search(community_id: community_id, query: "a_a")).to be_empty
      end

      it "treats the escape character itself as a literal" do
        expect(directory.search(community_id: community_id, query: "!")).to be_empty
      end

      it "still finds an entry whose handle really does carry one" do
        directory.record(community_id: community_id, adapter: :telegram, native_id: "333",
                         username: "a_b", display: "Underscored")

        results = directory.search(community_id: community_id, query: "a_b")
        expect(results.map(&:username)).to eq(["a_b"])
      end
    end

    it "returns identities on different platforms as separate entries, never merged" do
      results = directory.search(community_id: community_id, query: "ada")
      adapters = results.map(&:adapter)
      expect(adapters).to contain_exactly("discord", "telegram")
    end

    it "matches a display-name substring too" do
      results = directory.search(community_id: community_id, query: "Lovelace")
      expect(results.map(&:username)).to eq(["ada"])
    end

    it "is case-insensitive on both the query and the stored value" do
      expect(directory.search(community_id: community_id, query: "LOVE").map(&:username)).to eq(["ada"])
      expect(directory.search(community_id: community_id, query: "SMITH").map(&:username)).to eq(["bob"])
    end

    it "does not leak entries from another community" do
      results = directory.search(community_id: community_id, query: "elsewhere")
      expect(results).to be_empty
    end

    it "returns [] for a blank query" do
      expect(directory.search(community_id: community_id, query: "")).to eq([])
      expect(directory.search(community_id: community_id, query: nil)).to eq([])
    end

    it "honours a limit" do
      expect(directory.search(community_id: community_id, query: "a", limit: 1).size).to eq(1)
    end
  end

  describe "#recent (the dashboard people page, issue #493)" do
    before do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111",
                       username: "ada", display: "Ada Lovelace")
      @clock_time = now + 100
      directory.record(community_id: community_id, adapter: :discord, native_id: "999",
                       username: "adadev", display: "Ada on Discord")
      @clock_time = now + 200
      directory.record(community_id: community_id, adapter: :telegram, native_id: "222",
                       username: "bob", display: "Bob Smith")
      directory.record(community_id: other_community_id, adapter: :telegram, native_id: "111", username: "ada")
    end

    it "orders most recently seen first" do
      results = directory.recent(community_id: community_id)
      expect(results.map(&:username)).to eq(%w[bob adadev ada])
    end

    it "never leaks another community's entries" do
      results = directory.recent(community_id: community_id)
      expect(results.size).to eq(3)
    end

    it "caps the result even with no search" do
      expect(directory.recent(community_id: community_id, limit: 2).size).to eq(2)
    end

    it "narrows by the same substring match #search uses, keeping the recency order" do
      results = directory.recent(community_id: community_id, query: "ada")
      expect(results.map(&:username)).to eq(%w[adadev ada])
    end

    it "is empty for an unknown community" do
      expect(directory.recent(community_id: nil)).to eq([])
    end
  end

  describe "#resolve" do
    before do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "Ada")
      directory.record(community_id: community_id, adapter: :discord, native_id: "999", username: "ada")
    end

    it "resolves an exact (platform, handle) to that platform's native id" do
      expect(directory.resolve(community_id: community_id, adapter: :telegram, handle: "ada")).to eq("111")
      expect(directory.resolve(community_id: community_id, adapter: :discord, handle: "ada")).to eq("999")
    end

    it "normalises the queried handle the same way it is stored (sigil, case)" do
      expect(directory.resolve(community_id: community_id, adapter: :telegram, handle: "@Ada")).to eq("111")
    end

    it "fails closed (nil) for an unknown handle or the wrong platform" do
      expect(directory.resolve(community_id: community_id, adapter: :telegram, handle: "nobody")).to be_nil
      expect(directory.resolve(community_id: other_community_id, adapter: :telegram, handle: "ada")).to be_nil
    end
  end

  describe "#resolve_unique (the resolution cross-platform @mentions use)" do
    it "resolves an exact (platform, handle) when exactly one person goes by it" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "999", username: "Ada")
      expect(directory.resolve_unique(community_id: community_id, adapter: :discord, handle: "@ada")).to eq("999")
    end

    it "refuses to guess (nil) when two distinct ids share the same handle" do
      directory.record(community_id: community_id, adapter: :discord, native_id: "1", username: "dup")
      directory.record(community_id: community_id, adapter: :discord, native_id: "2", username: "dup")
      expect(directory.resolve_unique(community_id: community_id, adapter: :discord, handle: "dup")).to be_nil
    end

    it "fails closed (nil) for an unknown handle" do
      expect(directory.resolve_unique(community_id: community_id, adapter: :discord, handle: "ghost")).to be_nil
    end
  end

  describe "#resolve_unique_fragment (bare foreign @mentions)" do
    it "does not reach another community or platform for a fragment" do
      directory.record(community_id: other_community_id, adapter: :discord, native_id: "999", username: "till6357")
      directory.record(community_id: community_id, adapter: :telegram, native_id: "111", username: "till6357")

      result = directory.resolve_unique_fragment(community_id: community_id, adapter: :discord, handle: "till")

      expect(result.native_id).to be_nil
      expect(result.matches).to be_empty
    end
  end

  describe "#prune (retention)" do
    it "drops entries in a community not seen since the cutoff" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "old", username: "old")
      @clock_time = now + 100_000
      directory.record(community_id: community_id, adapter: :telegram, native_id: "new", username: "new")

      removed = directory.prune(community_id: community_id, older_than: now + 50_000)
      expect(removed).to eq(1)
      expect(directory.entries(community_id: community_id).map(&:username)).to eq(["new"])
    end
  end

  describe "#handle_collision? (the keyword-watcher anti-stalking rule, issue #255)" do
    before do
      directory.record(community_id: community_id, adapter: :discord, native_id: "1",
                       username: "owner_handle", display: "River the Great")
      directory.record(community_id: community_id, adapter: :telegram, native_id: "2",
                       username: "alex", display: "Alex")
    end

    it "collides on an exact handle match, case-insensitively" do
      expect(directory.handle_collision?(community_id: community_id, keyword: "alex")).to be(true)
      expect(directory.handle_collision?(community_id: community_id, keyword: "ALEX")).to be(true)
    end

    it "collides on an exact display-name match" do
      expect(directory.handle_collision?(community_id: community_id, keyword: "Alex")).to be(true)
    end

    it "collides when the keyword is a distinctive substring of a handle" do
      expect(directory.handle_collision?(community_id: community_id, keyword: "owner")).to be(true)
    end

    it "collides when a handle is a distinctive substring of the keyword" do
      expect(directory.handle_collision?(community_id: community_id, keyword: "owner_handle_fanclub")).to be(true)
    end

    it "does not collide on an unrelated word" do
      expect(directory.handle_collision?(community_id: community_id, keyword: "aoe3")).to be(false)
    end

    it "does not collide on a short substring below the distinctive-length floor" do
      # The overlap with "alex" is only "at", below the distinctive-length floor.
      expect(directory.handle_collision?(community_id: community_id, keyword: "at")).to be(false)
    end

    it "does not leak a collision from another community" do
      expect(directory.handle_collision?(community_id: other_community_id, keyword: "alex")).to be(false)
    end

    it "is permissive (false) for a blank keyword or an unknown community" do
      expect(directory.handle_collision?(community_id: community_id, keyword: "")).to be(false)
      expect(directory.handle_collision?(community_id: community_id, keyword: nil)).to be(false)
      expect(directory.handle_collision?(community_id: nil, keyword: "alex")).to be(false)
    end

    it "reflects the LIVE directory, not a snapshot: a handle that joins later starts colliding" do
      expect(directory.handle_collision?(community_id: community_id, keyword: "newbie")).to be(false)
      directory.record(community_id: community_id, adapter: :discord, native_id: "3", username: "newbie")
      expect(directory.handle_collision?(community_id: community_id, keyword: "newbie")).to be(true)
    end
  end

  describe "name history (#1477)" do
    def enable_identity_history(id)
      models.feature_setting.create(
        community_id: id, room_id: nil, feature: "identity_history", enabled: true,
        config: "{}", created_at: now, updated_at: now
      )
    end

    it "writes no history at all while identity_history is off, only observed_identities itself" do
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "ada")
      @clock_time = now + 3600
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "grace")

      expect(directory.name_history(community_id: community_id, adapter: :telegram, native_id: "1")).to be_empty
    end

    it "opens a history row on the first sighting once the feature is on" do
      enable_identity_history(community_id)
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "ada",
                       display: "Ada Lovelace")

      rows = directory.name_history(community_id: community_id, adapter: :telegram, native_id: "1")
      expect(rows.length).to eq(1)
      expect(rows.first.username).to eq("ada")
      expect(rows.first.display_name).to eq("Ada Lovelace")
      expect(rows.first.started_at).to be_within(1).of(now)
      expect(rows.first.ended_at).to be_nil
    end

    it "closes the open row and opens a new one on a real rename" do
      enable_identity_history(community_id)
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "ada")
      @clock_time = now + 3600
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "grace")

      rows = directory.name_history(community_id: community_id, adapter: :telegram, native_id: "1")
      expect(rows.length).to eq(2)
      expect(rows.first.username).to eq("ada")
      expect(rows.first.ended_at).to be_within(1).of(now + 3600)
      expect(rows.last.username).to eq("grace")
      expect(rows.last.started_at).to be_within(1).of(now + 3600)
      expect(rows.last.ended_at).to be_nil
    end

    it "opens no new row for a sighting that only advances last_seen_at" do
      enable_identity_history(community_id)
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "ada")
      @clock_time = now + 3600
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "ada")

      rows = directory.name_history(community_id: community_id, adapter: :telegram, native_id: "1")
      expect(rows.length).to eq(1)
      expect(rows.first.ended_at).to be_nil
    end

    it "keeps a community's history off the wire for a different community" do
      enable_identity_history(community_id)
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "ada")

      expect(directory.name_history(community_id: other_community_id, adapter: :telegram, native_id: "1")).to be_empty
    end
  end

  describe "#prune_expired_name_history" do
    it "drops only closed rows past the retention window, never the open one" do
      models.feature_setting.create(
        community_id: community_id, room_id: nil, feature: "identity_history", enabled: true,
        config: "{}", created_at: now, updated_at: now
      )
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "ada")
      @clock_time = now + 10
      directory.record(community_id: community_id, adapter: :telegram, native_id: "1", username: "grace")

      dropped = directory.prune_expired_name_history(now: now + described_class::NAME_HISTORY_RETENTION + 20)
      expect(dropped).to eq(1)

      rows = directory.name_history(community_id: community_id, adapter: :telegram, native_id: "1")
      expect(rows.length).to eq(1)
      expect(rows.first.username).to eq("grace")
      expect(rows.first.ended_at).to be_nil
    end
  end
end
