# frozen_string_literal: true

require "spec_helper"

# Two questions kept apart: what an identity OPERATES (authoritative, fails
# closed) and what it could REQUEST in (generous, grants nothing).
RSpec.describe Rubotty::ControlPlane::AdminReach, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:flow) { Rubotty::ControlPlane::OperatorFlow.new(models: models, logger: Rubotty::Log.null) }

  subject(:reach) { described_class.new(operator_flow: flow, logger: Rubotty::Log.null) }

  # The seeded bootstrap operator, linked on BOTH platforms by the config.
  let(:telegram_id) { "80000012" }
  let(:discord_id) { "80000000000000013" }

  def sample = models.community.first

  # Its person row carries only the identity given, so a DM on another platform
  # reaches it solely through the identity directory.
  def second_community(adapter:, native_id:, operator: true)
    now = Time.now
    community = models.community.create(slug: "second", name: "Second Guild", status: "active",
                                        settings: "{}", created_at: now, updated_at: now)
    person = models.person.create(community_id: community.id, name: "Alex",
                                  created_at: now, updated_at: now)
    models.person_identity.create(person_id: person.id, adapter: adapter, native_id: native_id,
                                  created_at: now)
    if operator
      models.operator.create(community_id: community.id, person_id: person.id,
                             actions: JSON.generate("all"), scope: JSON.generate("all"),
                             granted_at: now, granted_by: "test")
    end
    community
  end

  # A bare community nobody has an operators row in, to prove the floor alone
  # surfaces it.
  def bare_community(slug: "third")
    now = Time.now
    models.community.create(slug: slug, name: "Third Guild", status: "active",
                            settings: "{}", created_at: now, updated_at: now)
  end

  # A handle the deployment-configured owner floor recognises, which grants every action in
  # every room of every community while writing no operators row at all.
  def floor_handle = "maintainer"

  describe "#operated" do
    it "finds the community the DM's own identity operates" do
      memberships = reach.operated(adapter: "telegram", native_id: telegram_id)

      expect(memberships.map(&:slug)).to eq(["sample"])
      expect(memberships.first.operator.community_id).to eq(sample.id)
      expect(memberships.first.label).to eq("sample (SAMPLE)")
    end

    # The floor writes no row, so a community where it was the only grant never
    # appeared here: missing from the console's "which one?" list, and a reply
    # to one of its alerts unresolvable, since the code search only ever ran
    # over the communities this method returned.
    it "surfaces a community the owner floor grants and no operators row does" do
      bare = bare_community

      slugs = reach.operated(adapter: "telegram", native_id: telegram_id, username: floor_handle).map(&:slug)

      expect(slugs).to include(bare.slug)
    end

    it "hands back a stand-in operator for a floor-only community, not nil" do
      bare = bare_community

      membership = reach.operated(adapter: "telegram", native_id: telegram_id, username: floor_handle)
                        .find { |candidate| candidate.slug == bare.slug }

      expect(membership.operator).to be_a(Rubotty::ControlPlane::OperatorFlow::FloorOperator)
      expect(membership.operator.community_id).to eq(bare.id)
    end

    # An approve or deny hands the operators row back to OperatorFlow, so the
    # real one has to win wherever both exist.
    it "keeps the real operators row for a community that has one" do
      membership = reach.operated(adapter: "telegram", native_id: telegram_id, username: floor_handle)
                        .find { |candidate| candidate.slug == "sample" }

      expect(membership.operator).not_to be_a(Rubotty::ControlPlane::OperatorFlow::FloorOperator)
      expect(membership.operator.community_id).to eq(sample.id)
    end

    # The floor is an additive grant for the handles it names and nobody else,
    # so an ordinary operator still sees only what their rows say.
    it "leaves an identity the floor does not name seeing only its own rows" do
      bare_community

      slugs = reach.operated(adapter: "telegram", native_id: telegram_id, username: "someone_else").map(&:slug)

      expect(slugs).to eq(["sample"])
    end

    it "reaches a community the same human operates under a DIFFERENT platform identity" do
      second_community(adapter: "discord", native_id: discord_id)

      # The second community knows only the Discord id, and one person row
      # links the two, so the hop follows a link an operator already made.
      expect(reach.operated(adapter: "telegram", native_id: telegram_id).map(&:slug))
        .to eq(%w[sample second])
    end

    it "orders by slug, so a numbered pick means the same thing on the next message" do
      second_community(adapter: "discord", native_id: discord_id)
      now = Time.now
      apex = models.community.create(slug: "apex", name: "Apex", status: "active",
                                     settings: "{}", created_at: now, updated_at: now)
      person = models.person.create(community_id: apex.id, name: "Alex", created_at: now, updated_at: now)
      models.person_identity.create(person_id: person.id, adapter: "telegram",
                                    native_id: telegram_id, created_at: now)
      models.operator.create(community_id: apex.id, person_id: person.id,
                             actions: JSON.generate("all"), scope: JSON.generate("all"),
                             granted_at: now, granted_by: "test")

      expect(reach.operated(adapter: "telegram", native_id: telegram_id).map(&:slug))
        .to eq(%w[apex sample second])
    end

    it "does NOT reach a community where the person is known but is not an operator" do
      second_community(adapter: "discord", native_id: discord_id, operator: false)

      expect(reach.operated(adapter: "telegram", native_id: telegram_id).map(&:slug)).to eq(["sample"])
    end

    it "fails closed for an unknown identity" do
      without_owner_floor

      expect(reach.operated(adapter: "telegram", native_id: "404404")).to be_empty
      expect(reach.operated(adapter: "telegram", username: "nobody")).to be_empty
      expect(reach.operated(adapter: "telegram")).to be_empty
    end

    # The seeded row carries the id AND the handle, and the handle used to be an
    # alternative to the id rather than an extra fact about it, so a DM pairing
    # any account with a known handle was that operator. The floor is held off:
    # it grants that same handle by name, which is its job, not this one.
    it "refuses a DM pairing its own account with an operator's handle" do
      without_owner_floor

      expect(reach.operated(adapter: "telegram", native_id: "12321", username: "sample_owner"))
        .to be_empty
    end

    # The other half, and the reason the floor exists: a handle it names IS its
    # owner, so any account carrying it reaches every community. A Telegram
    # handle can change hands, so that is the deployment's own recorded
    # decision (config/protected_operators.yml), never an inference here.
    it "does grant a floor handle every community, whatever account carries it" do
      bare_community

      slugs = reach.operated(adapter: "telegram", native_id: "12321", username: floor_handle).map(&:slug)

      expect(slugs).to include("sample", "third")
    end

    it "still recognises the account the handle actually belongs to" do
      expect(reach.operated(adapter: "telegram", native_id: telegram_id, username: "@Sample_Owner")
                  .map(&:slug)).to eq(["sample"])
    end

    # A handle alone leaves nothing to verify, so the authoritative question has
    # no answer for it. The request lane still takes one.
    it "refuses a DM the platform gave no account id for" do
      expect(reach.operated(adapter: "telegram", username: "@Sample_Owner")).to be_empty
    end

    # Every hop widens the walk, so a handle picked up as somebody's sibling
    # used to carry the DM into a community the sender never proved anything
    # in. The DM below is on Discord and never says the word "sample_owner".
    it "does not hop into a second community through a handle the walk picked up" do
      now = Time.now
      elsewhere = models.community.create(slug: "elsewhere", name: "Elsewhere", status: "active",
                                          settings: "{}", created_at: now, updated_at: now)
      person = models.person.create(community_id: elsewhere.id, name: "Alex",
                                    created_at: now, updated_at: now)
      models.person_identity.create(person_id: person.id, adapter: "telegram",
                                    username: "sample_owner", created_at: now)
      models.operator.create(community_id: elsewhere.id, person_id: person.id,
                             actions: JSON.generate("all"), scope: JSON.generate("all"),
                             granted_at: now, granted_by: "test")

      expect(reach.operated(adapter: "discord", native_id: discord_id).map(&:slug)).to eq(["sample"])
    end
  end

  # A config handle can name someone for mentions, but a message under that
  # handle cannot establish a privileged account binding.
  describe "#operated, on a handle-only operator row" do
    let(:notifier) { instance_double(Rubotty::ControlPlane::AdminNotifier, notify_operators!: 1) }

    subject(:reach) do
      described_class.new(operator_flow: flow, notifier: notifier, logger: Rubotty::Log.null)
    end

    # An operator named by handle alone, the shape Seed writes for a Telegram
    # @mention with no id behind it.
    def handled_community(handle: "alice", slug: "handled")
      now = Time.now
      community = models.community.create(slug: slug, name: "Handled", status: "active",
                                          settings: "{}", created_at: now, updated_at: now)
      person = models.person.create(community_id: community.id, name: handle,
                                    created_at: now, updated_at: now)
      models.person_identity.create(person_id: person.id, adapter: "telegram",
                                    username: handle, created_at: now)
      models.operator.create(community_id: community.id, person_id: person.id,
                             actions: JSON.generate("all"), scope: JSON.generate("all"),
                             granted_at: now, granted_by: "test")
      community
    end

    def identity_for(handle) = models.person_identity.where(adapter: "telegram", username: handle).first

    it "refuses the first account presenting a handle-only operator row" do
      handled_community

      expect(reach.operated(adapter: "telegram", native_id: "500500", username: "@Alice")).to be_empty
      expect(identity_for("alice").native_id).to be_nil
      expect(identity_for("alice").claimed_at).to be_nil
    end

    it "does not claim a privileged identity through its compatibility API" do
      handled_community

      expect(reach.claim(adapter: "telegram", native_id: "500500", username: "alice")).to be_empty
      expect(identity_for("alice").native_id).to be_nil
      expect(notifier).not_to have_received(:notify_operators!)
    end

    it "refuses both accounts when two presentations race the same handle" do
      handled_community
      results = %w[500500 12321].map do |native_id|
        Thread.new { reach.operated(adapter: "telegram", native_id: native_id, username: "alice") }
      end.map(&:value)

      expect(results).to eq([[], []])
      expect(identity_for("alice").native_id).to be_nil
    end

    it "recognises an account after a separate authorised promotion" do
      community = handled_community
      flow.promote(community_id: community.id, adapter: "telegram", native_id: "500500",
                    username: "alice", granted_by: "administrator")

      expect(reach.operated(adapter: "telegram", native_id: "500500", username: "alice").map(&:slug))
        .to eq(["handled"])
      expect(reach.operated(adapter: "telegram", native_id: "12321", username: "alice")).to be_empty
    end

    it "leaves an unclaimed handle worth nothing on its own" do
      handled_community

      expect(reach.operated(adapter: "telegram", username: "alice")).to be_empty
      expect(identity_for("alice").native_id).to be_nil
    end
  end

  describe "#identities" do
    # The generous match is what the request lane is built on, so it keeps
    # taking a handle: naming a candidate for a human to approve costs nothing.
    it "still expands a handle into the rest of that human's accounts" do
      keys = reach.identities(adapter: "telegram", username: "@Sample_Owner")

      expect(keys.map { |key| [key[:adapter], key[:native_id]] }).to include(["discord", discord_id])
    end

    it "returns the closure of one human's identities across platforms" do
      keys = reach.identities(adapter: "telegram", native_id: telegram_id)

      expect(keys.map { |key| [key[:adapter], key[:native_id]] })
        .to include(["telegram", telegram_id], ["discord", discord_id])
    end

    it "is just the sender for an identity the directory has never seen" do
      keys = reach.identities(adapter: "telegram", native_id: "404404")
      expect(keys.size).to eq(1)
    end
  end

  describe "#requestable" do
    it "offers the communities served on the account the DM arrived on" do
      expect(reach.requestable(adapter: "telegram", account: "telegram", native_id: "999888").map(&:slug))
        .to eq(["sample"])
    end

    it "offers a community the sender has merely been SEEN in, whatever account the DM arrived on" do
      elsewhere = models.community.create(slug: "elsewhere", name: "Elsewhere", status: "active",
                                          settings: "{}", created_at: Time.now, updated_at: Time.now)
      Rubotty::ControlPlane::IdentityDirectory.new(models: models).record(
        community_id: elsewhere.id, adapter: "telegram", native_id: "999888", username: "newbie"
      )

      expect(reach.requestable(adapter: "telegram", account: "unknown-token", native_id: "999888").map(&:slug))
        .to eq(["elsewhere"])
    end

    it "unions the two sources without repeating a community, in slug order" do
      Rubotty::ControlPlane::IdentityDirectory.new(models: models).record(
        community_id: sample.id, adapter: "telegram", native_id: "999888", username: "newbie"
      )

      expect(reach.requestable(adapter: "telegram", account: "telegram", native_id: "999888").map(&:slug))
        .to eq(["sample"])
    end

    it "is empty when nothing attributes the DM at all" do
      expect(reach.requestable(adapter: "telegram", account: "unknown-token", native_id: "999888"))
        .to be_empty
    end
  end
end
