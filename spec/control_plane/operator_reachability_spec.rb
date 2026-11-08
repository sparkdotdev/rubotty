# frozen_string_literal: true

require "spec_helper"

# Which operator accounts a DM actually reaches. A bot cannot open a private
# chat with somebody who has never opened one with it, so an operator can hold
# a perfectly good grant and hear nothing; this is what remembers that.
RSpec.describe Rubotty::ControlPlane::OperatorReachability, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:operator) { models.operator.where(community_id: community.id).first }
  let(:identity) { models.person_identity.where(person_id: operator.person_id, adapter: "telegram").first }

  subject(:reachability) { described_class.new(models: models, logger: Rubotty::Log.null) }

  def reread(row) = models.person_identity[row.id]

  it "records a refusal against the account it was aimed at" do
    reachability.refused(identity.id, "chat not found")

    expect(reread(identity).dm_refused_at).not_to be_nil
    expect(reread(identity).dm_refused_reason).to eq("chat not found")
  end

  it "clears the refusal once a DM to that account lands" do
    reachability.refused(identity.id, "chat not found")
    reachability.delivered(identity.id)

    expect(reread(identity).dm_refused_at).to be_nil
    expect(reread(identity).dm_refused_reason).to be_nil
  end

  it "keeps a platform's essay inside the column" do
    reachability.refused(identity.id, "x" * 500)

    expect(reread(identity).dm_refused_reason.length).to eq(described_class::REASON_LIMIT)
  end

  it "shrugs off a nil identity rather than raising" do
    expect { reachability.refused(nil, "nobody") }.not_to raise_error
    expect { reachability.delivered(nil) }.not_to raise_error
  end

  describe "#unreachable" do
    it "names who cannot be reached, on which platform and why" do
      reachability.refused(identity.id, "chat not found")

      entry = reachability.unreachable(community_id: community.id).first
      expect(entry[:adapter]).to eq("telegram")
      expect(entry[:native_id]).to eq(identity.native_id)
      expect(entry[:reason]).to eq("chat not found")
      expect(entry[:person]).to eq(models.person[operator.person_id].name)
    end

    it "is empty while every operator account is reachable" do
      expect(reachability.unreachable(community_id: community.id)).to be_empty
    end

    # The screen and the alert audience read the same resolver, so an owner
    # the floor grants and no row does still shows up here when a DM to them
    # is refused; before this they were absent from both.
    it "names a deployment-configured operator who holds no grant of their own" do
      # Resolved before the delete: the row is reached through the operator
      # that is about to stop existing, and a lazy let would find nothing.
      refused = identity
      models.operator.where(community_id: community.id).delete
      reachability.refused(refused.id, "chat not found")

      entry = reachability.unreachable(community_id: community.id).first
      expect(entry[:adapter]).to eq("telegram")
      expect(entry[:native_id]).to eq(refused.native_id)
    end

    # An operator of one community must never show up as another's problem.
    it "never reads another community's operators" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      reachability.refused(identity.id, "chat not found")

      expect(reachability.unreachable(community_id: other.id)).to be_empty
    end
  end

  describe "#probe" do
    def adapter_double(sends:)
      Class.new do
        attr_reader :sent

        define_method(:initialize) { @sent = [] }
        define_method(:supports_admin_dm?) { true }
        define_method(:send_admin_dm) do |native_id, text|
          @sent << [native_id, text]
          sends
        end
      end.new
    end

    def probing(adapter)
      account = models.platform_connection.where(community_id: community.id, adapter: "telegram").first.account
      described_class.new(models: models, adapters: { [:telegram, account] => adapter },
                          logger: Rubotty::Log.null)
    end

    def probe(instance)
      instance.probe(community_id: community.id, adapter: "telegram",
                     native_id: identity.native_id, text: "you are an operator now")
    end

    it "delivers, and clears an older refusal on the way" do
      reachability.refused(identity.id, "chat not found")
      adapter = adapter_double(sends: Rubotty::Core::DmReceipt.new(native_id: "1"))

      expect(probe(probing(adapter))).to eq(:delivered)
      expect(adapter.sent.first.first).to eq(identity.native_id)
      expect(reread(identity).dm_refused_at).to be_nil
    end

    it "records a refusal when the platform will not take the DM" do
      expect(probe(probing(adapter_double(sends: nil)))).to eq(:refused)
      expect(reread(identity).dm_refused_at).not_to be_nil
    end

    # A platform with no DM at all says nothing about the account, so it is
    # neither a refusal to remember nor a delivery to celebrate.
    it "answers unknown when this deployment cannot DM on that platform" do
      quiet = Class.new do
        def supports_admin_dm? = false
      end.new

      expect(probe(probing(quiet))).to eq(:unknown)
      expect(reread(identity).dm_refused_at).to be_nil
    end

    it "answers unknown with no loaded connection at all" do
      instance = described_class.new(models: models, adapters: {}, logger: Rubotty::Log.null)
      expect(probe(instance)).to eq(:unknown)
    end

    it "treats a platform that blows up as a refusal rather than raising" do
      angry = Class.new do
        def supports_admin_dm? = true
        def send_admin_dm(*) = raise(StandardError, "network gone")
      end.new

      expect(probe(probing(angry))).to eq(:refused)
      expect(reread(identity).dm_refused_reason).to include("network gone")
    end
  end
end
