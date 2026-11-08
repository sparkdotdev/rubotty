# frozen_string_literal: true

require "spec_helper"

# The name a person is bridged as, per platform. Attached to the person rather
# than to one account, because the whole point is that it follows them across the
# bridge and still resolves to their real account on the other side.
RSpec.describe Rubotty::ControlPlane::BridgedNicknames, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  subject(:nicknames) { described_class.new(models: models, logger: Rubotty::Log.null) }

  let(:alex) { models.person.where(community_id: community.id).order(:id).first }
  let(:other) do
    now = Time.now
    models.person.create(community_id: community.id, name: "someone-else", created_at: now, updated_at: now)
  end

  def set(person: alex, adapter: "discord", nickname: "owner", **rest)
    nicknames.set(community_id: community.id, person_id: person.id, adapter: adapter, nickname: nickname, **rest)
  end

  describe "#set" do
    it "records the name a person is shown as on one platform" do
      result = set

      expect(result.status).to eq(:set)
      expect(nicknames.for_person(community_id: community.id, person_id: alex.id)).to eq("discord" => "owner")
    end

    it "keeps a separate nickname per platform, which is the point of it" do
      set(adapter: "discord", nickname: "owner")
      set(adapter: "irc", nickname: "mattp")

      expect(nicknames.for_person(community_id: community.id, person_id: alex.id))
        .to eq("discord" => "owner", "irc" => "mattp")
    end

    it "replaces a person's own nickname on a platform rather than adding a second" do
      set(nickname: "owner")
      set(nickname: "sparkles")

      expect(nicknames.for_person(community_id: community.id, person_id: alex.id)).to eq("discord" => "sparkles")
      expect(models.bridged_nickname.where(community_id: community.id).count).to eq(1)
    end

    it "refuses a nickname somebody else already holds, naming the holder" do
      set(person: alex, nickname: "owner")

      result = set(person: other, nickname: "owner")

      expect(result.status).to eq(:taken)
      expect(result.holder.person_id).to eq(alex.id)
      expect(nicknames.for_person(community_id: community.id, person_id: other.id)).to be_empty
    end

    # A nickname is indexed alongside real handles, so one that collided would
    # quietly redirect the real holder's pings.
    it "refuses a name somebody already answers to for real on that platform" do
      directory = Rubotty::ControlPlane::IdentityDirectory.new(models: models)
      directory.record(community_id: community.id, adapter: :discord, native_id: "900", username: "realuser")

      expect(set(nickname: "realuser").status).to eq(:taken)
    end

    it "refuses a name that is a linked account's handle on that platform" do
      now = Time.now
      models.person_identity.create(person_id: other.id, adapter: "discord", native_id: "901",
                                    username: "linked", created_at: now)

      expect(set(person: alex, nickname: "linked").status).to eq(:taken)
    end

    it "lets a person claim a name they already answer to themselves" do
      now = Time.now
      models.person_identity.create(person_id: alex.id, adapter: "discord", native_id: "902",
                                    username: "mine", created_at: now)

      expect(set(person: alex, nickname: "mine").status).to eq(:set)
    end

    # IdentityRecorder writes an observed_identity row passively for basically
    # every message someone sends, so a person whose own Discord username
    # already matches their own recorded handle must still be able to claim it.
    it "lets a person claim a name only ever recorded passively as their own observed identity" do
      now = Time.now
      models.person_identity.create(person_id: alex.id, adapter: "discord", native_id: "904",
                                    created_at: now)
      directory = Rubotty::ControlPlane::IdentityDirectory.new(models: models)
      directory.record(community_id: community.id, adapter: :discord, native_id: "904", username: "bob")

      expect(set(person: alex, nickname: "bob").status).to eq(:set)
    end

    it "still refuses an observed identity that belongs to somebody else's linked account" do
      now = Time.now
      models.person_identity.create(person_id: other.id, adapter: "discord", native_id: "905",
                                    created_at: now)
      directory = Rubotty::ControlPlane::IdentityDirectory.new(models: models)
      directory.record(community_id: community.id, adapter: :discord, native_id: "905", username: "carol")

      expect(set(person: alex, nickname: "carol").status).to eq(:taken)
    end

    it "leaves a real handle on another platform alone, since it cannot collide there" do
      directory = Rubotty::ControlPlane::IdentityDirectory.new(models: models)
      directory.record(community_id: community.id, adapter: :telegram, native_id: "900", username: "realuser")

      expect(set(adapter: "discord", nickname: "realuser").status).to eq(:set)
    end

    it "compares the claim case-insensitively, so owner does not sneak past owner" do
      set(person: alex, nickname: "owner")

      expect(set(person: other, nickname: "owner").status).to eq(:taken)
    end

    it "lets the same nickname be held by different people on different platforms" do
      set(person: alex, adapter: "discord", nickname: "owner")

      expect(set(person: other, adapter: "irc", nickname: "owner").status).to eq(:set)
    end

    it "scopes the claim to a community" do
      other_id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
      theirs = models.person.where(community_id: other_id).order(:id).first
      set(person: alex, nickname: "owner")

      result = nicknames.set(community_id: other_id, person_id: theirs.id, adapter: "discord", nickname: "owner")

      expect(result.status).to eq(:set)
    end

    it "strips a leading sigil, so @owner and owner are one name" do
      expect(set(nickname: "@owner").nickname).to eq("owner")
    end

    # A bridged nickname is a display name, shown where a Discord or Telegram
    # name would be, and those carry spaces, accents and emoji as a matter of
    # course. The old rule was shaped like a handle and refused all three.
    describe "what a display name is allowed to be" do
      it "takes a name with a space and an emoji in it" do
        result = set(nickname: "River 🇵🇹")

        expect(result.status).to eq(:set)
        expect(result.nickname).to eq("River 🇵🇹")
      end

      it "takes a name that is simply not English" do
        ["João", "Müller", "Ægir", "안녕하세요", "Ольга"].each do |name|
          expect(set(nickname: name).status).to eq(:set), name
        end
      end

      it "collapses internal whitespace and trims the ends" do
        expect(set(nickname: "  River   the   Third \t").nickname).to eq("River the Third")
      end

      it "counts a flag as the one character a reader sees, not as two" do
        # Twelve flags is 24 code points and would blow a code-point budget of 64.
        flags = "🇵🇹" * 12

        expect(set(nickname: flags).status).to eq(:set)
      end

      it "still holds the length bound over an emoji-heavy name" do
        expect { set(nickname: "🇵🇹" * 65) }
          .to raise_error(described_class::Invalid, /between 2 and 64 characters/)
      end

      it "keeps the accent, so two spellings of one name stay two names" do
        set(person: alex, nickname: "João")

        expect(set(person: other, nickname: "Joao").status).to eq(:set)
      end
    end

    describe "what it refuses outright" do
      it "refuses one that is too short or too long" do
        expect { set(nickname: "a") }.to raise_error(described_class::Invalid, /characters/)
        expect { set(nickname: "a" * 65) }.to raise_error(described_class::Invalid, /characters/)
      end

      it "counts the bounds in graphemes, so a lone flag is one character and too short" do
        expect { set(nickname: "🇵🇹") }.to raise_error(described_class::Invalid, /characters/)
      end

      it "refuses a control character" do
        expect { set(nickname: "spar\u0007ky") }
          .to raise_error(described_class::Invalid, /control, zero-width or invisible/)
      end

      it "refuses the zero-width characters a confusable is built from" do
        ["spar\u200Dky", "spar\u200Bky", "spar\u202Eky", "spar\u3164ky", "spar\uFEFFky"].each do |bad|
          expect { set(nickname: bad) }
            .to raise_error(described_class::Invalid, /control, zero-width or invisible/), bad.inspect
        end
      end

      it "refuses a name that is nothing but whitespace" do
        ["   ", "\u00A0\u00A0\u00A0", "\t\n"].each do |blank|
          expect { set(nickname: blank) }
            .to raise_error(described_class::Invalid, /visible character/), blank.inspect
        end
      end

      # The one punctuation rule left, because @ is how a mention says which
      # platform it means.
      it "refuses an @ inside the name" do
        expect { set(nickname: "spar@ky") }.to raise_error(described_class::Invalid, /@/)
      end

      it "refuses a blank platform" do
        expect { set(adapter: "  ") }.to raise_error(described_class::Invalid, /platform/)
      end
    end

    # Opening the format up to the whole of Unicode is what makes this worth
    # pinning: the comparison key folds compatibility spellings together, so a
    # fullwidth or ligatured copy of a taken name is the taken name.
    describe "impersonation" do
      it "refuses a fullwidth copy of a nickname somebody already holds" do
        set(person: alex, nickname: "owner")

        expect(set(person: other, nickname: "ＯＷＮＥＲ").status).to eq(:taken)
      end

      it "refuses a fullwidth copy of a real handle on that platform" do
        directory = Rubotty::ControlPlane::IdentityDirectory.new(models: models)
        directory.record(community_id: community.id, adapter: :discord, native_id: "903", username: "realuser")

        expect(set(nickname: "ｒｅａｌｕｓｅｒ").status).to eq(:taken)
      end

      it "resolves a mention typed in a compatibility spelling to the real holder" do
        set(person: alex, nickname: "owner")

        expect(nicknames.person_id_for(community_id: community.id, nickname: "ＯＷＮＥＲ")).to eq(alex.id)
      end
    end
  end

  describe "#clear" do
    it "removes a person's nickname on one platform, leaving the others" do
      set(adapter: "discord", nickname: "owner")
      set(adapter: "irc", nickname: "mattp")

      result = nicknames.clear(community_id: community.id, person_id: alex.id, adapter: "discord")

      expect(result.status).to eq(:cleared)
      expect(nicknames.for_person(community_id: community.id, person_id: alex.id)).to eq("irc" => "mattp")
    end

    it "reports having nothing to clear rather than raising" do
      expect(nicknames.clear(community_id: community.id, person_id: alex.id, adapter: "discord").status)
        .to eq(:missing)
    end

    it "frees the name for somebody else" do
      set(person: alex, nickname: "owner")
      nicknames.clear(community_id: community.id, person_id: alex.id, adapter: "discord")

      expect(set(person: other, nickname: "owner").status).to eq(:set)
    end
  end

  describe "#person_id_for" do
    it "finds the holder whichever platform the nickname was claimed for" do
      set(person: alex, adapter: "discord", nickname: "owner")

      expect(nicknames.person_id_for(community_id: community.id, nickname: "owner")).to eq(alex.id)
    end

    it "ignores case and a leading sigil, the way a typed mention arrives" do
      set(person: alex, nickname: "owner")

      expect(nicknames.person_id_for(community_id: community.id, nickname: "@owner")).to eq(alex.id)
    end

    it "is nil for a name nobody holds" do
      expect(nicknames.person_id_for(community_id: community.id, nickname: "nobody")).to be_nil
    end

    it "is nil when two people hold it on different platforms, since it names neither" do
      set(person: alex, adapter: "discord", nickname: "owner")
      set(person: other, adapter: "irc", nickname: "owner")

      expect(nicknames.person_id_for(community_id: community.id, nickname: "owner")).to be_nil
    end
  end

  describe "#person_for" do
    it "finds the person behind an already-linked account" do
      identity = models.person_identity.where(person_id: alex.id).order(:id).first

      found = nicknames.person_for(
        community_id: community.id, adapter: identity.adapter, native_id: identity.native_id
      )

      expect(found.id).to eq(alex.id)
    end

    it "creates a person and its identity for an account nothing has linked yet" do
      found = nicknames.person_for(
        community_id: community.id, adapter: "discord", native_id: "5150", username: "newcomer"
      )

      expect(found.name).to eq("newcomer")
      expect(models.person_identity.where(person_id: found.id, adapter: "discord").first.native_id).to eq("5150")
    end

    it "returns the same person the second time, rather than a duplicate" do
      first = nicknames.person_for(community_id: community.id, adapter: "discord", native_id: "5150")
      second = nicknames.person_for(community_id: community.id, adapter: "discord", native_id: "5150")

      expect(second.id).to eq(first.id)
    end

    it "does not reach into another community's linked account" do
      other_id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
      theirs = models.person.where(community_id: other_id).order(:id).first
      identity = models.person_identity.where(person_id: theirs.id).order(:id).first

      found = nicknames.person_for(
        community_id: community.id, adapter: identity.adapter, native_id: identity.native_id
      )

      expect(found.id).not_to eq(theirs.id)
      expect(found.community_id).to eq(community.id)
    end

    it "is nil without a native id to key on" do
      expect(nicknames.person_for(community_id: community.id, adapter: "discord", native_id: "")).to be_nil
    end

    # Simulates two near-simultaneous callers: both see nil on their initial
    # read, and the second's write lands after a concurrent writer already
    # claimed (adapter, native_id). Without the unique index and rescue, this
    # would raise Sequel::UniqueConstraintViolation and leave an orphan person.
    it "falls back to the row a concurrent writer created, instead of raising or duplicating" do
      other # force creation so it exists before the race
      calls = 0
      allow(nicknames).to receive(:person_for_identity).and_wrap_original do |original, **kwargs|
        calls += 1
        result = original.call(**kwargs)
        if calls == 1 && result.nil?
          models.person_identity.create(
            person_id: other.id, community_id: community.id, adapter: "discord", native_id: "9999",
            created_at: Time.now
          )
        end
        result
      end
      people_before = models.person.where(community_id: community.id).count

      found = nicknames.person_for(community_id: community.id, adapter: "discord", native_id: "9999")

      expect(found.id).to eq(other.id)
      expect(models.person_identity.where(adapter: "discord", native_id: "9999").count).to eq(1)
      expect(models.person.where(community_id: community.id).count).to eq(people_before)
    end
  end

  describe "#person_for_identity (the dashboard people page's read-only lookup, issue #493)" do
    it "finds the person behind an already-linked account, same as #person_for" do
      identity = models.person_identity.where(person_id: alex.id).order(:id).first

      found = nicknames.person_for_identity(
        community_id: community.id, adapter: identity.adapter, native_id: identity.native_id
      )

      expect(found.id).to eq(alex.id)
    end

    it "is nil for an account nothing has linked yet, and creates nothing" do
      expect(models.person.count).to be_positive

      before_count = models.person.count
      found = nicknames.person_for_identity(community_id: community.id, adapter: "discord", native_id: "5150")

      expect(found).to be_nil
      expect(models.person.count).to eq(before_count)
    end

    it "scopes to the calling community even when another community links the same native id" do
      # The seed loads the same fixture into both communities, so the bootstrap
      # operator's telegram id is linked on both sides; this proves the lookup
      # resolves THIS community's own person rather than the other one's.
      other_id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
      theirs = models.person.where(community_id: other_id).order(:id).first
      identity = models.person_identity.where(person_id: theirs.id).order(:id).first

      found = nicknames.person_for_identity(
        community_id: community.id, adapter: identity.adapter, native_id: identity.native_id
      )

      expect(found.id).not_to eq(theirs.id)
      expect(found.community_id).to eq(community.id)
    end

    it "is nil for a blank community, platform or native id" do
      expect(nicknames.person_for_identity(community_id: nil, adapter: "discord", native_id: "1")).to be_nil
      expect(nicknames.person_for_identity(community_id: community.id, adapter: "", native_id: "1")).to be_nil
      expect(nicknames.person_for_identity(community_id: community.id, adapter: "discord", native_id: "")).to be_nil
    end
  end

  describe "nickname history (#1477)" do
    def enable_identity_history
      now = Time.now
      models.feature_setting.create(
        community_id: community.id, room_id: nil, feature: "identity_history", enabled: true,
        config: "{}", created_at: now, updated_at: now
      )
    end

    it "writes no history at all while identity_history is off" do
      set
      expect(nicknames.nickname_history(community_id: community.id, person_id: alex.id)).to be_empty
    end

    it "opens a history row for the first nickname once the feature is on" do
      enable_identity_history
      set(nickname: "owner")

      rows = nicknames.nickname_history(community_id: community.id, person_id: alex.id)
      expect(rows.length).to eq(1)
      expect(rows.first.nickname).to eq("owner")
      expect(rows.first.ended_at).to be_nil
    end

    it "closes the open row and opens a new one on a real rename" do
      enable_identity_history
      set(nickname: "owner")
      set(nickname: "owner_handle")

      rows = nicknames.nickname_history(community_id: community.id, person_id: alex.id)
      expect(rows.length).to eq(2)
      expect(rows.first.nickname).to eq("owner")
      expect(rows.first.ended_at).not_to be_nil
      expect(rows.last.nickname).to eq("owner_handle")
      expect(rows.last.ended_at).to be_nil
    end

    it "opens no new row for re-setting the same nickname" do
      enable_identity_history
      set(nickname: "owner")
      set(nickname: "owner")

      rows = nicknames.nickname_history(community_id: community.id, person_id: alex.id)
      expect(rows.length).to eq(1)
      expect(rows.first.ended_at).to be_nil
    end

    it "closes the open row, and opens nothing new, on clear" do
      enable_identity_history
      set(nickname: "owner")
      nicknames.clear(community_id: community.id, person_id: alex.id, adapter: "discord")

      rows = nicknames.nickname_history(community_id: community.id, person_id: alex.id)
      expect(rows.length).to eq(1)
      expect(rows.first.ended_at).not_to be_nil
    end

    it "keeps each platform's history separate" do
      enable_identity_history
      set(adapter: "discord", nickname: "owner")
      set(adapter: "telegram", nickname: "owner_handle")

      expect(nicknames.nickname_history(community_id: community.id, person_id: alex.id, adapter: "discord").length)
        .to eq(1)
      expect(nicknames.nickname_history(community_id: community.id, person_id: alex.id, adapter: "telegram").length)
        .to eq(1)
    end

    describe "#prune_expired_nickname_history (#1518)" do
      it "drops only closed rows past the retention window, never the open one" do
        enable_identity_history
        set(nickname: "owner")
        set(nickname: "owner_handle")

        dropped = nicknames.prune_expired_nickname_history(
          now: Time.now + described_class::NAME_HISTORY_RETENTION + 20
        )
        expect(dropped).to eq(1)

        rows = nicknames.nickname_history(community_id: community.id, person_id: alex.id)
        expect(rows.length).to eq(1)
        expect(rows.first.nickname).to eq("owner_handle")
        expect(rows.first.ended_at).to be_nil
      end

      it "leaves rows short of the retention window alone" do
        enable_identity_history
        set(nickname: "owner")
        set(nickname: "owner_handle")

        dropped = nicknames.prune_expired_nickname_history(now: Time.now + 3600)
        expect(dropped).to eq(0)
        expect(nicknames.nickname_history(community_id: community.id, person_id: alex.id).length).to eq(2)
      end
    end
  end
end
