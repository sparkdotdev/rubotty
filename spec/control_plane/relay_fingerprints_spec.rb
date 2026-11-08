# frozen_string_literal: true

require "spec_helper"

# The content ledger a decision elsewhere can trust instead of the
# relay-claim ledger, which has nothing for a message that never relayed
# and cannot recognise a copy the bridge itself wrote. The digest must
# neither over- nor under-collide, and pruning is the only way a row leaves.
RSpec.describe Rubotty::ControlPlane::RelayFingerprints, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  # Second 30 of a 60 second bucket (2_000_000_010 / 60 is exactly 33333333.5),
  # so now and now + 2 share a bucket whatever second the suite runs at.
  let(:now) { Time.at(2_000_000_010) }

  let(:other) do
    models.community.create(slug: "other-co", name: "Other Co", status: "active",
                            settings: "{}", created_at: now, updated_at: now)
  end

  let(:ledger) { described_class.new(models: models, clock: -> { now }, window_seconds: 3600) }

  describe ".digest_for" do
    it "normalises before hashing, so surrounding whitespace changes nothing" do
      tight = described_class.digest_for(text: "hello world", author: "telegram:1", timestamp: now)
      padded = described_class.digest_for(text: "   hello world   ", author: "telegram:1", timestamp: now)

      expect(padded).to eq(tight)
    end

    it "normalises before hashing, so runs of internal whitespace collapse" do
      one_space = described_class.digest_for(text: "hello world", author: "telegram:1", timestamp: now)
      many_spaces = described_class.digest_for(text: "hello    world", author: "telegram:1", timestamp: now)
      newline = described_class.digest_for(text: "hello\nworld", author: "telegram:1", timestamp: now)

      expect(many_spaces).to eq(one_space)
      expect(newline).to eq(one_space)
    end

    it "normalises before hashing, so case changes nothing" do
      lower = described_class.digest_for(text: "hello world", author: "telegram:1", timestamp: now)
      shouted = described_class.digest_for(text: "HELLO WORLD", author: "telegram:1", timestamp: now)

      expect(shouted).to eq(lower)
    end

    it "does not collide two different authors saying the same word" do
      ada = described_class.digest_for(text: "lol", author: "telegram:1", timestamp: now)
      bob = described_class.digest_for(text: "lol", author: "telegram:2", timestamp: now)

      expect(ada).not_to eq(bob)
    end

    it "does not collide two different platforms' authors who share a native id" do
      telegram = described_class.digest_for(text: "lol", author: "telegram:1", timestamp: now)
      discord = described_class.digest_for(text: "lol", author: "discord:1", timestamp: now)

      expect(telegram).not_to eq(discord)
    end

    it "does not collide the same author saying the same word far apart in time" do
      first = described_class.digest_for(text: "lol", author: "telegram:1", timestamp: now)
      later = described_class.digest_for(text: "lol", author: "telegram:1", timestamp: now + (2 * 60 * 60))

      expect(first).not_to eq(later)
    end

    it "collides the same author saying the same word a few seconds apart" do
      first = described_class.digest_for(text: "lol", author: "telegram:1", timestamp: now)
      moments_later = described_class.digest_for(text: "lol", author: "telegram:1", timestamp: now + 2)

      expect(first).to eq(moments_later)
    end

    it "refuses to fingerprint blank text" do
      expect(described_class.digest_for(text: "   ", author: "telegram:1", timestamp: now)).to be_nil
      expect(described_class.digest_for(text: nil, author: "telegram:1", timestamp: now)).to be_nil
    end

    it "refuses to fingerprint an unattributed message" do
      expect(described_class.digest_for(text: "hello", author: nil, timestamp: now)).to be_nil
      expect(described_class.digest_for(text: "hello", author: "", timestamp: now)).to be_nil
    end

    it "refuses to fingerprint a message with no timestamp" do
      expect(described_class.digest_for(text: "hello", author: "telegram:1", timestamp: nil)).to be_nil
    end
  end

  describe "#record and #present?" do
    it "finds a recorded arrival on the endpoint it was recorded against" do
      ledger.record(community_id: community.id, endpoint_id: "tg-general",
                    text: "deploy finished", author: "telegram:1", timestamp: now)

      expect(
        ledger.present?(community_id: community.id, endpoint_id: "tg-general",
                        text: "deploy finished", author: "telegram:1", timestamp: now)
      ).to be(true)
    end

    it "does not find it on a different endpoint" do
      ledger.record(community_id: community.id, endpoint_id: "tg-general",
                    text: "deploy finished", author: "telegram:1", timestamp: now)

      expect(
        ledger.present?(community_id: community.id, endpoint_id: "dc-general",
                        text: "deploy finished", author: "telegram:1", timestamp: now)
      ).to be(false)
    end

    it "does not find content that was never recorded" do
      expect(
        ledger.present?(community_id: community.id, endpoint_id: "tg-general",
                        text: "never sent", author: "telegram:1", timestamp: now)
      ).to be(false)
    end

    it "will not reach into another community's row on the same endpoint id" do
      ledger.record(community_id: other.id, endpoint_id: "tg-general",
                    text: "deploy finished", author: "telegram:1", timestamp: now)

      expect(
        ledger.present?(community_id: community.id, endpoint_id: "tg-general",
                        text: "deploy finished", author: "telegram:1", timestamp: now)
      ).to be(false)
    end

    it "records nothing, and answers false, for content it cannot fingerprint" do
      expect(
        ledger.record(community_id: community.id, endpoint_id: "tg-general",
                      text: "", author: "telegram:1", timestamp: now)
      ).to be(false)
      expect(models.relay_fingerprint.count).to eq(0)
    end

    it "is idempotent: the same content recorded twice on the same endpoint is one row" do
      2.times do
        ledger.record(community_id: community.id, endpoint_id: "tg-general",
                      text: "deploy finished", author: "telegram:1", timestamp: now)
      end

      expect(models.relay_fingerprint.where(community_id: community.id, endpoint_id: "tg-general").count).to eq(1)
    end

    it "stores no message body anywhere in the row, only a digest" do
      secret_text = "the launch codes are 04390"
      ledger.record(community_id: community.id, endpoint_id: "tg-general",
                    text: secret_text, author: "telegram:1", timestamp: now)

      row = models.relay_fingerprint.first
      expect(row.columns).to contain_exactly(:id, :community_id, :endpoint_id, :digest, :created_at)
      expect(row.values.values.map(&:to_s)).to all(satisfy { |value| !value.include?("launch codes") })
    end
  end

  describe "#prune" do
    it "drops nothing still inside the window" do
      ledger.record(community_id: community.id, endpoint_id: "tg-general",
                    text: "fresh", author: "telegram:1", timestamp: now)

      expect(ledger.prune).to eq(0)
      expect(models.relay_fingerprint.count).to eq(1)
    end

    it "drops everything past the window and keeps what is still live" do
      # One instance for both writes, on a clock that never advances, so the
      # second write's throttled sweep (PRUNE_INTERVAL) cannot fire and remove
      # the row this test is about to age by hand.
      ledger.record(community_id: community.id, endpoint_id: "tg-general",
                    text: "stale", author: "telegram:1", timestamp: now)
      models.relay_fingerprint.where(endpoint_id: "tg-general").first.update(created_at: now - 7200)
      ledger.record(community_id: community.id, endpoint_id: "dc-general",
                    text: "fresh", author: "telegram:1", timestamp: now)

      expect(ledger.prune).to eq(1)
      expect(models.relay_fingerprint.count).to eq(1)
      expect(models.relay_fingerprint.first.endpoint_id).to eq("dc-general")
    end

    it "refuses a row past the window even when nothing has pruned it yet" do
      ledger.record(community_id: community.id, endpoint_id: "tg-general",
                    text: "old news", author: "telegram:1", timestamp: now)
      models.relay_fingerprint.first.update(created_at: now - 7200)

      expect(
        ledger.present?(community_id: community.id, endpoint_id: "tg-general",
                        text: "old news", author: "telegram:1", timestamp: now)
      ).to be(false)
      expect(models.relay_fingerprint.count).to eq(1)
    end
  end

  describe ".author_key" do
    origin = Rubotty::Core::Endpoint.new(id: "tg-general", adapter_name: :telegram, account: "telegram")

    it "combines the origin adapter with the platform's own user id" do
      message = Rubotty::Core::Message.new(
        kind: :chat, ref: Rubotty::Core::MessageRef.new("tg-general", "1"), origin: origin,
        author: Rubotty::Core::Author.new(native_id: "80000012")
      )

      expect(described_class.author_key(message)).to eq("telegram:80000012")
    end

    it "answers nil for a message with no attributable author" do
      message = Rubotty::Core::Message.new(
        kind: :system, ref: Rubotty::Core::MessageRef.new("tg-general", "1"), origin: origin,
        author: Rubotty::Core::Author.new(kind: :system)
      )

      expect(described_class.author_key(message)).to be_nil
    end
  end
end
