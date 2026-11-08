# frozen_string_literal: true

require "spec_helper"

# The credential behind `/auth`: minted by somebody who already holds what it
# hands over, shown once, spent once, and refused identically however it fails.
RSpec.describe Rubotty::ControlPlane::AuthTokens, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:other) do
    id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
    models.community[id]
  end
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db, logger: Rubotty::Log.null) }
  let(:operator_flow) { Rubotty::ControlPlane::OperatorFlow.new(models: models, logger: Rubotty::Log.null) }
  let(:community_viewers) do
    Rubotty::ControlPlane::CommunityViewers.new(models: models, audit: audit, logger: Rubotty::Log.null)
  end
  let(:dashboard_viewers) do
    Rubotty::ControlPlane::DashboardViewers.new(models: models, audit: audit, logger: Rubotty::Log.null)
  end
  let(:dashboard_administrators) do
    Rubotty::ControlPlane::DashboardAdministrators.new(models: models, audit: audit,
                                                       logger: Rubotty::Log.null)
  end
  let(:now) { Time.now }
  let(:clock) { -> { @now || now } }

  subject(:tokens) do
    described_class.new(
      models: models, operator_flow: operator_flow, community_viewers: community_viewers,
      dashboard_viewers: dashboard_viewers, dashboard_administrators: dashboard_administrators,
      audit: audit, logger: Rubotty::Log.null, clock: clock
    )
  end

  # The administrator, who may mint anything anywhere.
  def admin(label: "dashboard:administrator")
    described_class::Minter.new(administrator: true, community_ids: [], label: label)
  end

  # An operator of the communities named, and of nothing else.
  def operator_of(*rows)
    described_class::Minter.new(administrator: false, community_ids: rows.map(&:id),
                                may_grant_operator: true, label: "an operator")
  end

  # A credential that is read-write inside a community without holding the
  # operator role there, which is what a developer API key is.
  def key_for(*rows)
    described_class::Minter.new(administrator: false, community_ids: rows.map(&:id), label: "a key")
  end

  def redeem(token, username: "ada", native_id: "77", adapter: "telegram", display: "Ada")
    tokens.redeem(token: token, adapter: adapter, native_id: native_id, username: username, display: display)
  end

  def actions(slug)
    audit.query(community: slug, source: described_class::AUDIT_SOURCE).map(&:action)
  end

  describe "#mint" do
    it "hands back a raw token once and stores only its digest" do
      issued = tokens.mint(minter: admin, community_id: community.id, operator: true)

      expect(issued.token).not_to be_empty
      expect(db[:auth_tokens].first[:token_hash]).to eq(described_class.hash_token(issued.token))
      expect(db[:auth_tokens].select_map(:token_hash)).not_to include(issued.token)
    end

    it "refuses a token that grants nothing" do
      expect { tokens.mint(minter: admin, community_id: community.id) }
        .to raise_error(described_class::Invalid, /grant something/)
    end

    it "defaults to a lifetime rather than making the minter pick one" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)

      expect(issued.row[:expires_at].to_time).to be_within(5).of(now + described_class::DEFAULT_TTL)
    end

    it "refuses a lifetime longer than the ceiling" do
      expect { tokens.mint(minter: admin, community_id: community.id, viewer: true, ttl_seconds: 999_999_999) }
        .to raise_error(described_class::Invalid, /longer than/)
    end

    it "records the issue in the community's audit trail" do
      tokens.mint(minter: admin, community_id: community.id, operator: true)

      expect(actions(community.slug)).to include("auth_token_issued")
    end

    it "records a deployment-wide issue under the deployment's own name" do
      tokens.mint(minter: admin, viewer: true)

      expect(actions(described_class::AUDIT_SCOPE)).to include("auth_token_issued")
    end
  end

  # The load-bearing rule: nobody widens their own reach by writing themselves a
  # token, so both directions are asserted rather than only the refusal.
  describe "who may mint what" do
    it "lets an operator of a community mint one for that community" do
      issued = tokens.mint(minter: operator_of(community), community_id: community.id, operator: true)

      expect(issued.row[:community_id]).to eq(community.id)
    end

    it "refuses an operator minting the deployment-wide viewer" do
      expect { tokens.mint(minter: operator_of(community), community_id: nil, viewer: true) }
        .to raise_error(described_class::Invalid, /administrator/)
    end

    it "refuses an operator minting into a community they do not operate" do
      expect { tokens.mint(minter: operator_of(community), community_id: other.id, viewer: true) }
        .to raise_error(described_class::Invalid, /do not operate/)
    end

    it "lets an administrator mint the deployment-wide viewer" do
      issued = tokens.mint(minter: admin, community_id: nil, viewer: true)

      expect(issued.row[:community_id]).to be_nil
    end

    it "refuses an operator role with no community to hold it" do
      expect { tokens.mint(minter: admin, community_id: nil, operator: true, viewer: true) }
        .to raise_error(described_class::Invalid, /has to name one/)
    end

    # Handing out operator makes a person who can change the community. A
    # credential with write access there but no operator role of its own would
    # be reaching past itself, so it is held to the viewer alone.
    it "refuses a viewer-only credential minting an operator token" do
      expect { tokens.mint(minter: key_for(community), community_id: community.id, operator: true) }
        .to raise_error(described_class::Invalid, /needs an operator/)
    end

    it "still lets that credential mint a viewer token, which changes nothing" do
      issued = tokens.mint(minter: key_for(community), community_id: community.id, viewer: true)

      expect(issued.row[:community_id]).to eq(community.id)
    end

    it "refuses the operator half even when a viewer half rides along with it" do
      expect do
        tokens.mint(minter: key_for(community), community_id: community.id, operator: true, viewer: true)
      end.to raise_error(described_class::Invalid, /needs an operator/)
      expect(tokens.list(every: true)).to be_empty
    end

    it "lets an administrator mint an operator token" do
      issued = tokens.mint(minter: admin, community_id: community.id, operator: true)

      expect(tokens.grant_words(issued.row)).to eq("operator")
    end

    it "refuses a mint that says nobody made it" do
      nameless = described_class::Minter.new(administrator: true, community_ids: [], label: " ")

      expect { tokens.mint(minter: nameless, community_id: community.id, viewer: true) }
        .to raise_error(described_class::Invalid, /who made it/)
    end
  end

  # The administrator role is the widest thing a token can carry, so the gate on
  # minting one is the strictest: an administrator, no community named, and the
  # check taken before any row exists.
  describe "a token that hands over the administrator role" do
    it "lets an administrator mint one" do
      issued = tokens.mint(minter: admin, community_id: nil, administrator: true)

      expect(issued.row[:community_id]).to be_nil
      expect(tokens.administrator_token?(issued.row)).to be(true)
      expect(tokens.grant_words(issued.row)).to eq("administrator of the deployment")
    end

    it "refuses an operator of a community, whose reach ends at that community" do
      expect { tokens.mint(minter: operator_of(community), community_id: nil, administrator: true) }
        .to raise_error(described_class::Invalid, /administrator's to hand out/)
      expect(tokens.list(every: true)).to be_empty
    end

    it "refuses a credential that is only read-write inside a community" do
      expect { tokens.mint(minter: key_for(community), community_id: nil, administrator: true) }
        .to raise_error(described_class::Invalid, /administrator's to hand out/)
      expect(tokens.list(every: true)).to be_empty
    end

    it "refuses one that names a community, since the role covers all of them" do
      expect { tokens.mint(minter: admin, community_id: community.id, administrator: true) }
        .to raise_error(described_class::Invalid, /names no community/)
      expect(tokens.list(every: true)).to be_empty
    end

    # Nothing widens itself: the refusal comes before the insert, not after.
    it "writes no row at all when it is refused" do
      expect { tokens.mint(minter: operator_of(community), community_id: nil, administrator: true) }
        .to raise_error(described_class::Invalid)
      expect(db[:auth_tokens].count).to eq(0)
    end

    it "makes the presenter an administrator when it is redeemed" do
      issued = tokens.mint(minter: admin, community_id: nil, administrator: true)

      result = redeem(issued.token)

      expect(result).to be_ok
      expect(result.granted.administrator).to be(true)
      expect(dashboard_administrators.administrator?(adapter: "telegram", native_id: "77", username: "ada")).to be(true)
    end

    it "records the grant against the handle, never the display name" do
      issued = tokens.mint(minter: admin, community_id: nil, administrator: true)
      redeem(issued.token, username: "ada", display: "Ada Lovelace")

      expect(dashboard_administrators.administrator?(adapter: "telegram", username: "adalovelace"))
        .to be(false)
    end

    it "binds a grant to the native account even without a public username" do
      issued = tokens.mint(minter: admin, community_id: nil, administrator: true)

      result = redeem(issued.token, username: nil)

      expect(result.granted.administrator).to be(true)
      expect(result.granted.problems).to be_empty
      expect(dashboard_administrators.administrator?(adapter: "telegram", native_id: "77")).to be(true)
    end

    it "is spent once, so a second presentation is refused like any other dead token" do
      issued = tokens.mint(minter: admin, community_id: nil, administrator: true)
      redeem(issued.token)

      expect(redeem(issued.token, native_id: "88").status).to eq(:invalid)
    end

    it "hands over nothing once it has been revoked" do
      issued = tokens.mint(minter: admin, community_id: nil, administrator: true)
      tokens.revoke(public_id: issued.row[:public_id], revoked_by: "admin", every: true)

      expect(redeem(issued.token).status).to eq(:invalid)
      expect(dashboard_administrators.administrator?(adapter: "telegram", native_id: "77", username: "ada")).to be(false)
    end

    # A deployment-wide token can carry either role or both, so the viewer half
    # is still applied on its own when the administrator half is absent.
    it "leaves a viewer-only deployment token granting only the viewer" do
      issued = tokens.mint(minter: admin, community_id: nil, viewer: true)

      result = redeem(issued.token)

      expect(result.granted.deployment_viewer).to be(true)
      expect(result.granted.administrator).to be(false)
      expect(dashboard_administrators.administrator?(adapter: "telegram", native_id: "77", username: "ada")).to be(false)
    end
  end

  describe "#redeem" do
    it "makes the presenter an operator of the community the token names" do
      issued = tokens.mint(minter: admin, community_id: community.id, operator: true)

      result = redeem(issued.token)

      expect(result).to be_ok
      expect(result.granted.operated.slug).to eq(community.slug)
      expect(operator_flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                            native_id: "77", username: "ada")).not_to be_nil
    end

    it "makes the presenter a viewer of the community the token names" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)

      result = redeem(issued.token)

      expect(result).to be_ok
      expect(community_viewers.viewer?(community_id: community.id, adapter: "telegram",
                                       native_id: "77", username: "ada")).to be(true)
    end

    it "hands over both halves when the token carries both" do
      issued = tokens.mint(minter: admin, community_id: community.id, operator: true, viewer: true)

      redeem(issued.token)

      expect(operator_flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                            native_id: "77", username: "ada")).not_to be_nil
      expect(community_viewers.viewer?(community_id: community.id, adapter: "telegram",
                                       native_id: "77", username: "ada")).to be(true)
    end

    it "hands over reading every community when the token carries that" do
      issued = tokens.mint(minter: admin, community_id: nil, viewer: true)

      result = redeem(issued.token)

      expect(result.granted.deployment_viewer).to be(true)
      expect(dashboard_viewers.viewer?(adapter: "telegram", native_id: "77", username: "ada")).to be(true)
    end

    # The token binds to whoever presents it, which is the whole model: nobody
    # is named on it in advance.
    it "binds the token to the person who presented it" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)

      redeem(issued.token, username: "bea", native_id: "88")

      row = db[:auth_tokens].first
      expect(row[:redeemed_username]).to eq("bea")
      expect(row[:redeemed_native_id]).to eq("88")
    end

    it "records the redemption in the audit trail" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)

      redeem(issued.token)

      expect(actions(community.slug)).to include("auth_token_redeemed")
    end

    it "refuses a token that has already been spent" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      redeem(issued.token)

      expect(redeem(issued.token, username: "bea", native_id: "88").status).to eq(:invalid)
      expect(community_viewers.viewer?(community_id: community.id, adapter: "telegram",
                                       username: "bea")).to be(false)
    end

    it "refuses a token that has expired" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true, ttl_seconds: 60)
      @now = now + 3600

      expect(redeem(issued.token).status).to eq(:invalid)
    end

    it "refuses a token that was revoked before it was used" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      tokens.revoke(public_id: issued.row[:public_id], revoked_by: "boss", every: true)

      expect(redeem(issued.token).status).to eq(:invalid)
    end

    it "refuses a token nobody ever minted" do
      expect(redeem("not-a-real-token").status).to eq(:invalid)
    end

    # A guess must not be able to tell one kind of dead token from another, so
    # every failure has to be the same answer and the same word.
    it "answers unknown, spent and expired identically" do
      spent = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      redeem(spent.token)
      stale = tokens.mint(minter: admin, community_id: community.id, viewer: true, ttl_seconds: 60)
      @now = now + 3600

      outcomes = [redeem("never-existed"), redeem(spent.token), redeem(stale.token)].map(&:status)

      expect(outcomes).to eq(%i[invalid invalid invalid])
      expect(described_class::REFUSAL).to be_a(String)
    end

    it "spends the token before anything else can go wrong" do
      issued = tokens.mint(minter: admin, community_id: community.id, operator: true)
      allow(operator_flow).to receive(:promote).and_raise(Sequel::Error, "gone")

      result = redeem(issued.token)

      expect(result).to be_ok
      expect(result.granted.problems).not_to be_empty
      expect(db[:auth_tokens].first[:redeemed_at]).not_to be_nil
    end

    it "refuses a presenter with no platform id at all" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)

      expect(tokens.redeem(token: issued.token, adapter: "telegram", native_id: nil).status).to eq(:invalid)
    end
  end

  describe "the redemption rate limit" do
    it "stops answering after a run of attempts from one identity" do
      described_class::ATTEMPT_MAX.times { redeem("guess") }

      expect(redeem("guess").status).to eq(:rate_limited)
    end

    it "counts a good token against the limit too, so a run cannot be laundered" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      (described_class::ATTEMPT_MAX - 1).times { redeem("guess") }
      redeem(issued.token)

      expect(redeem("guess").status).to eq(:rate_limited)
    end

    it "counts per identity, so one guesser cannot lock everybody else out" do
      described_class::ATTEMPT_MAX.times { redeem("guess") }

      expect(redeem("guess", username: "bea", native_id: "88").status).to eq(:invalid)
    end

    it "lets the window pass and answers again" do
      described_class::ATTEMPT_MAX.times { redeem("guess") }
      @now = now + described_class::ATTEMPT_WINDOW + 1

      expect(redeem("guess").status).to eq(:invalid)
    end
  end

  describe "#revoke" do
    it "takes an unused token back and records it" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)

      result = tokens.revoke(public_id: issued.row[:public_id], community_id: community.id,
                             revoked_by: "boss")

      expect(result.status).to eq(:removed)
      expect(actions(community.slug)).to include("auth_token_revoked")
    end

    it "refuses to rewrite a token that has already been used" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      redeem(issued.token)

      result = tokens.revoke(public_id: issued.row[:public_id], community_id: community.id,
                             revoked_by: "boss")

      expect(result.status).to eq(:spent)
    end

    it "does not reach a token in another community" do
      issued = tokens.mint(minter: admin, community_id: community.id, viewer: true)

      result = tokens.revoke(public_id: issued.row[:public_id], community_id: other.id, revoked_by: "boss")

      expect(result.status).to eq(:not_found)
    end
  end

  describe "#list" do
    it "keeps one community's tokens out of another's" do
      here = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      tokens.mint(minter: admin, community_id: other.id, viewer: true)

      expect(tokens.list(community_id: community.id).map { |row| row[:public_id] })
        .to eq([here.row[:public_id]])
    end

    it "lists the deployment-wide ones on their own" do
      tokens.mint(minter: admin, community_id: community.id, viewer: true)
      wide = tokens.mint(minter: admin, community_id: nil, viewer: true)

      expect(tokens.list(community_id: nil).map { |row| row[:public_id] }).to eq([wide.row[:public_id]])
    end

    it "lists everything for the administrator's own view" do
      tokens.mint(minter: admin, community_id: community.id, viewer: true)
      tokens.mint(minter: admin, community_id: nil, viewer: true)

      expect(tokens.list(every: true).size).to eq(2)
    end
  end

  describe "#state_of" do
    it "reads live, spent, revoked and expired apart for a list to show" do
      live = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      spent = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      revoked = tokens.mint(minter: admin, community_id: community.id, viewer: true)
      redeem(spent.token)
      tokens.revoke(public_id: revoked.row[:public_id], revoked_by: "boss", every: true)

      expect(tokens.state_of(reread(live))).to eq("live")
      expect(tokens.state_of(reread(spent))).to eq("spent")
      expect(tokens.state_of(reread(revoked))).to eq("revoked")

      @now = now + described_class::DEFAULT_TTL + 60
      expect(tokens.state_of(reread(live))).to eq("expired")
    end
  end

  # A deployment whose code arrived before the migration reads nothing and
  # refuses honestly, rather than failing to build its control plane at all.
  describe "before the migration has run" do
    let(:bare) { described_class.new(models: models, logger: Rubotty::Log.null) }

    before { db.drop_table?(:auth_tokens, :auth_token_redemptions) }

    it "lists nothing" do
      expect(bare.list(every: true)).to eq([])
    end

    it "refuses a mint with a message a page can print" do
      expect { bare.mint(minter: admin, community_id: community.id, viewer: true) }
        .to raise_error(described_class::Invalid, /not available/)
    end

    it "refuses a redemption the same way every other bad token is refused" do
      expect(bare.redeem(token: "anything", adapter: "telegram", native_id: "77").status).to eq(:invalid)
    end
  end

  def reread(issued)
    db[:auth_tokens].where(public_id: issued.row[:public_id]).first
  end
end
