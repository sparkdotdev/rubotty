# frozen_string_literal: true

require "spec_helper"

# The bot-DM to web-dashboard login handoff, driven against a store double with the
# same get_state/put_state surface the message map's bridge_state table exposes.
RSpec.describe Rubotty::ControlPlane::WebLoginTokens do
  # Expiry is honoured against the wall clock as every production backend does, so a
  # spec can force an expired row by issuing with a negative ttl.
  let(:store) do
    Class.new do
      def initialize = @rows = {}

      def get_state(key)
        row = @rows[key.to_s]
        return nil if row.nil?
        return nil if row[:expires_at] && row[:expires_at] <= Time.now

        row[:value]
      end

      def put_state(key, value, expires_at: nil)
        @rows[key.to_s] = { value: value.to_s, expires_at: expires_at }
        nil
      end
    end.new
  end

  subject(:tokens) { described_class.new(store: store, logger: Rubotty::Log.null) }

  let(:operator) { { adapter: "telegram", account: "telegram", native_id: "80000012", label: "Alex" } }
  let(:communities) { [{ id: 1, slug: "sample", name: "SAMPLE" }, { id: 2, slug: "second", name: "Second" }] }

  describe "#issue" do
    it "mints a token and hands it back once" do
      outcome = tokens.issue(identity_key: "telegram:telegram:80000012", operator: operator, communities: communities)

      expect(outcome).to be_ok
      expect(outcome.token).to be_a(String)
      expect(outcome.token.length).to be >= 32
      expect(outcome.expires_at).to be_within(5).of(Time.now + described_class::DEFAULT_TTL)
    end

    it "never stores the raw token, only its digest" do
      outcome = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      digest = described_class.digest(outcome.token)

      expect(store.get_state("web_login:token:#{digest}")).not_to be_nil
      expect(store.get_state("web_login:token:#{digest}")).not_to include(outcome.token)
    end

    it "rate-limits a second issue for the same identity while the first is still active" do
      tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      second = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)

      expect(second.ok?).to be(false)
      expect(second.status).to eq(:rate_limited)
    end

    it "does not rate-limit a different identity" do
      tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      second = tokens.issue(identity_key: "telegram:telegram:2", operator: operator, communities: communities)

      expect(second).to be_ok
    end

    it "keeps rate-limiting after the active token has been redeemed, since redeeming does not end it" do
      first = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      tokens.redeem(token: first.token)

      second = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      expect(second.ok?).to be(false)
      expect(second.status).to eq(:rate_limited)
    end

    it "allows a fresh issue once the active token has expired" do
      expired = described_class.new(store: store, ttl: -10, logger: Rubotty::Log.null)
      expired.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)

      fresh = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      expect(fresh).to be_ok
    end
  end

  # The viewer dimension rides on the same token as the operator
  # communities, so one link can be viewer, operator, or both, and the
  # revocation and per-sender accounting above cover all three unchanged.
  describe "the viewer dimension" do
    it "defaults to no viewer status, so a plain operator link is unchanged" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)

      expect(tokens.redeem(token: issued.token).viewer).to be(false)
    end

    it "carries viewer on a token that also carries operator communities" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: communities, viewer: true)

      redeemed = tokens.redeem(token: issued.token)

      expect(redeemed.viewer).to be(true)
      expect(redeemed.community_ids).to eq([1, 2])
    end

    it "carries viewer on a token that operates nothing at all" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: [], viewer: true)

      redeemed = tokens.redeem(token: issued.token)

      expect(redeemed.viewer).to be(true)
      expect(redeemed.community_ids).to eq([])
    end

    it "stores only a literal true, so a truthy argument is not viewer status" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: communities, viewer: "yes")

      expect(tokens.redeem(token: issued.token).viewer).to be(false)
    end

    it "shows the administrator which links carry it" do
      tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                   communities: communities, viewer: true)

      expect(tokens.active_tokens.first[:viewer]).to be(true)
    end

    it "revokes a viewer link the same way as any other" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: [], viewer: true)

      expect(tokens.revoke(id: tokens.active_tokens.first[:id])).to be(true)
      expect(tokens.redeem(token: issued.token)).not_to be_ok
    end
  end

  # The third dimension, which is the heaviest thing a link can carry: total
  # control of the deployment sitting in a chat message. It is shorter lived
  # than the other two on that account, and what it says about its holder is a
  # claim the redeeming surface checks against the roster rather than a grant.
  describe "the administrator dimension" do
    it "defaults to no administrator claim, so an ordinary link is unchanged" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: communities)

      expect(tokens.redeem(token: issued.token).administrator).to be(false)
      expect(issued.expires_at).to be_within(5).of(Time.now + described_class::DEFAULT_TTL)
    end

    it "carries the claim through a redemption" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: [], administrator: true)

      expect(tokens.redeem(token: issued.token).administrator).to be(true)
    end

    it "lives a good deal less long than an ordinary link" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: [], administrator: true)

      expect(described_class::ADMINISTRATOR_TTL).to be < described_class::DEFAULT_TTL
      expect(issued.expires_at).to be_within(5).of(Time.now + described_class::ADMINISTRATOR_TTL)
    end

    # A deployment that configured something tighter keeps what it configured.
    it "never lengthens a link on a deployment with a shorter lifetime of its own" do
      brief = described_class.new(store: store, ttl: 120, logger: Rubotty::Log.null)

      issued = brief.issue(identity_key: "telegram:telegram:1", operator: operator,
                           communities: [], administrator: true)

      expect(issued.expires_at).to be_within(5).of(Time.now + 120)
    end

    it "stores only a literal true, so a truthy argument is not an administrator claim" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: communities, administrator: "yes")

      expect(tokens.redeem(token: issued.token).administrator).to be(false)
    end

    it "shows the administrator which links carry it" do
      tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                   communities: [], administrator: true)

      expect(tokens.active_tokens.first[:administrator]).to be(true)
    end

    it "revokes an administrator link the same way as any other" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: [], administrator: true)

      expect(tokens.revoke(id: tokens.active_tokens.first[:id])).to be(true)
      expect(tokens.redeem(token: issued.token)).not_to be_ok
    end

    # A token stored before this key existed carries none of it, and that has to
    # read as no claim rather than as one.
    it "reads a payload written before the key existed as no claim at all" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator,
                            communities: communities)
      digest = described_class.digest(issued.token)
      payload = JSON.parse(store.get_state("web_login:token:#{digest}"))
      payload.delete("administrator")
      store.put_state("web_login:token:#{digest}", JSON.generate(payload), expires_at: Time.now + 600)

      expect(tokens.redeem(token: issued.token).administrator).to be(false)
    end
  end

  describe "#preview" do
    it "carries the same claimed dimensions #redeem does without spending the token" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities,
                            viewer: true, viewer_communities: [2], administrator: true)

      previewed = tokens.preview(token: issued.token)

      expect(previewed).to be_ok
      expect(previewed.community_ids).to eq([1, 2])
      expect(previewed.viewer).to be(true)
      expect(previewed.viewer_communities).to eq([2])
      expect(previewed.administrator).to be(true)
      expect(tokens.redeem(token: issued.token)).to be_ok
    end
  end

  describe "#redeem" do
    it "returns the community ids and operator for a valid token" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      outcome = tokens.redeem(token: issued.token)

      expect(outcome).to be_ok
      expect(outcome.community_ids).to eq([1, 2])
      expect(outcome.operator["label"]).to eq("Alex")
    end

    it "rejects an unknown token" do
      outcome = tokens.redeem(token: "not-a-real-token")
      expect(outcome.ok?).to be(false)
      expect(outcome.status).to eq(:invalid)
    end

    it "rejects a blank or nil token" do
      expect(tokens.redeem(token: nil).status).to eq(:invalid)
      expect(tokens.redeem(token: "").status).to eq(:invalid)
    end

    it "rejects an expired token" do
      expired = described_class.new(store: store, ttl: -10, logger: Rubotty::Log.null)
      issued = expired.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)

      outcome = tokens.redeem(token: issued.token)
      expect(outcome.ok?).to be(false)
    end

    # A client that builds its own link preview redeems the token before the operator
    # taps it, so the token's boundary is its TTL rather than one-time use.
    it "is repeatable: a second, third and fourth redeem of the same live token all succeed" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)

      results = Array.new(4) { tokens.redeem(token: issued.token) }

      expect(results).to all(be_ok)
      expect(results.map(&:community_ids)).to all(eq([1, 2]))
    end
  end

  # The opt-in for a link handed to somebody rather than fetched by the person
  # who asked for it, where a second use would be a second person.
  describe "a single-use token" do
    def issue_single_use(identity: "telegram:telegram:1")
      tokens.issue(identity_key: identity, operator: operator, communities: communities, single_use: true)
    end

    it "works once" do
      issued = issue_single_use

      expect(tokens.redeem(token: issued.token)).to be_ok
    end

    it "stops working after that one use" do
      issued = issue_single_use
      tokens.redeem(token: issued.token)

      expect(tokens.redeem(token: issued.token).status).to eq(:invalid)
    end

    it "still stops working at its expiry, used or not" do
      short = described_class.new(store: store, ttl: -10, logger: Rubotty::Log.null)
      issued = short.issue(identity_key: "telegram:telegram:9", operator: operator,
                           communities: communities, single_use: true)

      expect(tokens.redeem(token: issued.token).status).to eq(:invalid)
    end

    it "leaves the active list once it is spent, so nothing offers to revoke it twice" do
      issued = issue_single_use
      tokens.redeem(token: issued.token)

      expect(tokens.active_tokens).to be_empty
    end

    it "frees the sender's own rate limit, so they can be handed another" do
      issued = issue_single_use
      tokens.redeem(token: issued.token)

      expect(issue_single_use).to be_ok
    end

    # The default has to stay the repeatable behaviour, or a link preview would
    # start burning every operator's `web-login` link.
    it "is off unless a caller asks for it" do
      issued = tokens.issue(identity_key: "telegram:telegram:2", operator: operator, communities: communities)
      tokens.redeem(token: issued.token)

      expect(tokens.redeem(token: issued.token)).to be_ok
    end
  end

  describe "#active_tokens and #revoke" do
    it "lists an issued token as active, most recently issued first" do
      tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      tokens.issue(identity_key: "telegram:telegram:2", operator: operator, communities: communities)

      active = tokens.active_tokens
      expect(active.size).to eq(2)
      expect(active.first[:operator]["native_id"]).to eq("80000012")
      expect(active.first[:communities].map { |c| c["slug"] }).to eq(%w[sample second])
    end

    it "keeps a redeemed token in the active list, since redeeming does not end it" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      tokens.redeem(token: issued.token)

      expect(tokens.active_tokens.size).to eq(1)
    end

    it "revokes an active token by its listed id, invalidating it" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      id = tokens.active_tokens.first[:id]

      expect(tokens.revoke(id: id)).to be(true)
      expect(tokens.active_tokens).to be_empty
      expect(tokens.redeem(token: issued.token).ok?).to be(false)
    end

    it "returns false revoking an unknown or already-revoked id" do
      expect(tokens.revoke(id: "nope")).to be(false)

      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      id = tokens.active_tokens.first[:id]
      tokens.revoke(id: id)
      expect(tokens.revoke(id: id)).to be(false)
    end

    it "revoking a token already redeemed several times still kills it" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      3.times { tokens.redeem(token: issued.token) }
      id = tokens.active_tokens.first[:id]

      expect(tokens.revoke(id: id)).to be(true)
      expect(tokens.redeem(token: issued.token).ok?).to be(false)
    end

    it "frees the rate limit immediately on revoke" do
      tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      id = tokens.active_tokens.first[:id]
      tokens.revoke(id: id)

      fresh = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      expect(fresh).to be_ok
    end
  end

  # The index is one key holding the whole list of live digests, so every writer
  # reads it, changes one entry and writes it back. An entry lost there leaves a
  # live token that active_tokens never shows and revoke can never reach.
  describe "two writers racing the index" do
    # A store with the real per-name lock every production backend gives, plus a
    # hook that holds one read open so a spec can place the second writer exactly
    # in the window rather than hoping to hit it.
    let(:store) do
      Class.new do
        attr_reader :reached

        def initialize
          @rows = {}
          @mutexes = {}
          @guard = Mutex.new
          @hold_key = nil
          @reached = Queue.new
          @release = Queue.new
        end

        def hold_next_read_of(key) = (@hold_key = key.to_s)

        def release!
          @release << :go
        end

        # The value is read BEFORE the hold, so the held caller comes out of it
        # carrying what it saw on the way in, which is the whole shape of a lost
        # update.
        def get_state(key)
          row = @rows[key.to_s]
          if @hold_key == key.to_s
            @hold_key = nil
            @reached << :in
            @release.pop
          end
          row && row[:value]
        end

        def put_state(key, value, expires_at: nil)
          @rows[key.to_s] = { value: value.to_s, expires_at: expires_at }
          nil
        end

        def with_advisory_lock(name, timeout: 5)
          mutex = @guard.synchronize { @mutexes[name.to_s] ||= Mutex.new }
          mutex.synchronize { yield }
        end
      end.new
    end

    def issue_as(identity)
      Thread.new { tokens.issue(identity_key: identity, operator: operator, communities: communities) }
    end

    it "keeps both tokens listed when two are issued at once" do
      store.hold_next_read_of(described_class::INDEX_KEY)
      first = issue_as("telegram:telegram:1")
      store.reached.pop

      second = issue_as("telegram:telegram:2")
      # Either blocked on the lock (the fix) or already finished (without it).
      Thread.pass while second.alive? && second.status != "sleep"

      store.release!
      [first, second].each(&:join)

      expect(tokens.active_tokens.length).to eq(2)
    end

    it "keeps a token listed when one is issued while another is revoked" do
      issued = tokens.issue(identity_key: "telegram:telegram:1", operator: operator, communities: communities)
      id = tokens.active_tokens.first[:id]

      store.hold_next_read_of(described_class::INDEX_KEY)
      revoking = Thread.new { tokens.revoke(id: id) }
      store.reached.pop

      issuing = issue_as("telegram:telegram:2")
      Thread.pass while issuing.alive? && issuing.status != "sleep"

      store.release!
      [revoking, issuing].each(&:join)

      expect(tokens.active_tokens.length).to eq(1)
      expect(tokens.redeem(token: issued.token).ok?).to be(false)
    end
  end
end
