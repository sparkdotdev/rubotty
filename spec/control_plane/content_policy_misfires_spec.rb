# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::ContentPolicyMisfires, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.now }
  let(:store) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  # The row a reversal copies from, with only the fields the corpus reads.
  ActionRow = Struct.new(:adapter, :endpoint_id, :policy, :action, :body, :reasoning,
                         :confidence, :context, :created_at, keyword_init: true)

  def action_row(**overrides)
    ActionRow.new(
      **{ adapter: "telegram", endpoint_id: "tg-general", policy: "Potentially offensive language",
          action: "flag_notify", body: "this whole process is bullshit",
          reasoning: "Uses a vulgarity", confidence: 0.61, context: nil,
          created_at: now - 60 }.merge(overrides)
    )
  end

  def record(**overrides)
    store.record(community_id: community.id, action_row: action_row(**overrides),
                 statement: "ordinary venting, aimed at nobody", reversed_by: "telegram:mel")
  end

  # A check never judged the message alone, so a sample that drops what it was
  # judged beside cannot say whether the verdict came from the message or from
  # the room around it.
  it "carries the context the check was given across from the action" do
    sample = %({"recent_messages":[{"author":"member 1","text":"AIMA closed it again"}]})

    row = record(context: sample)

    expect(row.context).to eq(sample)
  end

  it "keeps a row from before the context was captured, rather than refusing it" do
    row = record(context: nil)

    expect(row.context).to be_nil
    expect(row.body).to eq("this whole process is bullshit")
  end

  it "keeps the four things a description gets rewritten against" do
    row = record

    expect(row.body).to eq("this whole process is bullshit")
    expect(row.reasoning).to eq("Uses a vulgarity")
    expect(row.confidence).to be_within(0.001).of(0.61)
    expect(row.statement).to eq("ordinary venting, aimed at nobody")
  end

  # The corpus is about the text and the judgement. An author's identity would
  # be the one field in it that could hurt somebody, and it teaches a prompt
  # nothing, so the schema has nowhere to put it.
  it "has no column for the author, so a sample can never carry one" do
    expect(models.content_policy_misfire.columns).not_to include(:author_name)
    expect(models.content_policy_misfire.columns).not_to include(:author_native_id)
  end

  it "separates when the policy fired from when somebody called it wrong" do
    row = record

    expect(row.acted_at).to be_within(2).of(now - 60)
    expect(row.created_at).to be_within(2).of(now)
  end

  it "answers nil rather than raising, since the reversal already happened" do
    expect(store.record(community_id: community.id, action_row: nil)).to be_nil
    expect(store.record(community_id: nil, action_row: action_row)).to be_nil
  end

  it "reads them newest first, which is the order somebody tuning reads in" do
    record(body: "older")
    newest = record(body: "newer")

    expect(store.recent(community_id: community.id).first.id).to eq(newest.id)
  end

  it "counts them per policy, which is what says whose wording to rewrite" do
    record
    record
    record(policy: "Racially insensitive language")

    counts = store.counts_by_policy(community_id: community.id)
    expect(counts).to eq("Potentially offensive language" => 2, "Racially insensitive language" => 1)
  end

  it "never reads out of the community that owns it" do
    record
    other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                    created_at: now, updated_at: now)

    expect(store.recent(community_id: other.id)).to be_empty
    expect(store.counts_by_policy(community_id: other.id)).to be_empty
  end

  it "drops one sample by id, and only inside its own community" do
    row = record
    other = models.community.create(slug: "other2", name: "Other", status: "active", settings: "{}",
                                    created_at: now, updated_at: now)

    expect(store.delete(community_id: other.id, id: row.id)).to be(false)
    expect(store.delete(community_id: community.id, id: row.id)).to be(true)
    expect(store.recent(community_id: community.id)).to be_empty
  end

  describe "the window" do
    it "holds a stored value to the ceiling where it is read" do
      expect(described_class.window_days(365)).to eq(described_class::MAX_WINDOW_DAYS)
      expect(described_class.window_days(30)).to eq(30)
      expect(described_class.window_days(0)).to eq(described_class::DEFAULT_WINDOW_DAYS)
      expect(described_class.window_days(nil)).to eq(described_class::DEFAULT_WINDOW_DAYS)
    end

    it "is ninety days, long enough for a tuning cycle and no longer" do
      expect(described_class::MAX_WINDOW_DAYS).to eq(90)
    end

    it "drops what has lapsed and keeps what has not" do
      record
      old = described_class.new(models: models, logger: Rubotty::Log.null,
                                clock: -> { now - (91 * 86_400) })
      old.record(community_id: community.id, action_row: action_row, statement: "stale")

      expect(store.prune(window_days: 90)).to eq(1)
      expect(store.recent(community_id: community.id).length).to eq(1)
    end
  end
end
