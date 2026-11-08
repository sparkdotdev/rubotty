# frozen_string_literal: true

require "spec_helper"

# What a content policy action did, kept only long enough for an operator to
# disagree with it, and named by a code short enough to type back into a DM.
RSpec.describe Rubotty::ControlPlane::ContentPolicyActions, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 8, 27, 12, 0, 0) }

  subject(:actions) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  def record(**overrides)
    actions.record(
      **{ community_id: community.id, adapter: "telegram", endpoint_id: "tg-general",
          native_id: "9001", action: "delete", author_native_id: "80000012",
          author_name: "Ada", policy: "WhatsApp groups", body: "join my group" }.merge(overrides)
    )
  end

  describe "#record" do
    it "keeps what reversing needs, including the text nothing else holds" do
      row = record

      expect(row.action).to eq("delete")
      expect(row.body).to eq("join my group")
      expect(row.native_id).to eq("9001")
      expect(row.reversed_at).to be_nil
    end

    it "mints a code an operator can read off a phone" do
      code = record.code

      expect(code.length).to eq(described_class::CODE_LENGTH)
      expect(code).to match(/\A[#{described_class::CODE_ALPHABET}]+\z/)
      expect(code).not_to match(/[aeiou01lio]/)
    end

    it "refuses a row with no message to point at, rather than writing a useless one" do
      expect(record(native_id: "")).to be_nil
    end
  end

  describe "#find" do
    it "reads a code back case and hash insensitively, the way somebody types it" do
      row = record

      expect(actions.find(community_id: community.id, code: row.code.upcase)&.id).to eq(row.id)
      expect(actions.find(community_id: community.id, code: "##{row.code}")&.id).to eq(row.id)
    end

    # One community's code must never reach another's action.
    it "never reaches out of its own community" do
      row = record
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: now, updated_at: now)

      expect(actions.find(community_id: other.id, code: row.code)).to be_nil
    end
  end

  describe "#reverse!" do
    it "claims the row once and refuses the second operator" do
      row = record

      expect(actions.reverse!(row, by: "Jesse")).to be(true)
      expect(actions.reverse!(models.content_policy_action[row.id], by: "Dean")).to be(false)
      expect(models.content_policy_action[row.id].reversed_by).to eq("Jesse")
    end
  end

  describe "#prune" do
    # Two different messages, since one message keeps one open record however
    # often it is judged and the second call would otherwise reuse the first.
    it "drops a row past the window and leaves one inside it" do
      old_row = record(native_id: "9001")
      models.content_policy_action.where(id: old_row.id).update(created_at: now - (31 * 86_400))
      fresh = record(native_id: "9002")

      actions.prune(window_days: 30)

      expect(models.content_policy_action[old_row.id]).to be_nil
      expect(models.content_policy_action[fresh.id]).not_to be_nil
    end
  end

  describe ".window_days" do
    it "holds a configured window to the ceiling and falls back below the floor" do
      expect(described_class.window_days(7)).to eq(7)
      expect(described_class.window_days(365)).to eq(described_class::MAX_WINDOW_DAYS)
      expect(described_class.window_days(0)).to eq(described_class::DEFAULT_WINDOW_DAYS)
      expect(described_class.window_days(nil)).to eq(described_class::DEFAULT_WINDOW_DAYS)
    end
  end
  # Content policy watches edits as well as fresh messages, so one message is
  # judged more than once. Two codes for one message would mean reversing one
  # leaves the other standing, with the reaction still on it.
  describe "a message judged more than once" do
    def record_for(native_id: "m1", **overrides)
      actions.record(**{ community_id: community.id, adapter: "telegram", endpoint_id: "tg-general",
                         native_id: native_id, action: "flag_notify", policy: "Offensive language",
                         body: "first text", reasoning: "first reason", confidence: 0.8 }.merge(overrides))
    end

    it "keeps one open record per message rather than minting a second code" do
      first = record_for
      second = record_for(body: "edited text", reasoning: "second reason", confidence: 0.9)

      expect(second.id).to eq(first.id)
      expect(second.code).to eq(first.code)
    end

    it "carries the newer judgement onto the row it reuses" do
      record_for
      again = record_for(body: "edited text", reasoning: "second reason", confidence: 0.9)

      expect(again.body).to eq("edited text")
      expect(again.reasoning).to eq("second reason")
      expect(again.confidence).to be_within(0.001).of(0.9)
    end

    # Once it is answered the row is closed, so a later match on the same
    # message is a new decision and earns its own code.
    it "mints a fresh code after the open one has been reversed" do
      first = record_for
      actions.reverse!(first, by: "telegram:mel")
      second = record_for

      expect(second.id).not_to eq(first.id)
    end

    it "keeps a different message on its own record" do
      first = record_for
      other = record_for(native_id: "m2")

      expect(other.id).not_to eq(first.id)
    end
  end

  describe "the open list a bare vindicate is answered with" do
    it "shows what is still reversible, newest first, and hides what is not" do
      older = record(native_id: "m1", action: "flag_notify", policy: "A")
      newer = record(native_id: "m2", action: "delete", policy: "B")
      actions.reverse!(older, by: "telegram:mel")

      codes = actions.recent(community_id: community.id).map(&:code)
      expect(codes).to eq([newer.code])
    end

    it "never reaches out of its own community" do
      record(native_id: "m1", action: "flag_notify", policy: "A")
      other = models.community.create(slug: "elsewhere", name: "Elsewhere", status: "active",
                                      settings: "{}", created_at: Time.now, updated_at: Time.now)

      expect(actions.recent(community_id: other.id)).to be_empty
    end
  end

end
