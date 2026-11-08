# frozen_string_literal: true

require "spec_helper"

# Who a script may know about, and how much an id promises. `person_identities`
# is the registry an operator wrote, so it can say two accounts are one human;
# `observed_identities` is what watching the room learned and deliberately
# cannot. That difference has to show up in the id, not be smoothed over.
RSpec.describe Rubotty::ControlPlane::Participants, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }

  subject(:participants) { described_class.new(models: models, directory: directory) }

  def community(slug)
    stamp = Time.now
    db[:communities].insert(slug: slug, name: slug.upcase, status: "active",
                            settings: "{}", created_at: stamp, updated_at: stamp)
  end

  let(:community_id) { community("alpha") }
  let(:other_community_id) { community("beta") }

  def person(name, community: community_id, identities: [])
    stamp = Time.now
    id = db[:people].insert(community_id: community, name: name, created_at: stamp, updated_at: stamp)
    identities.each do |adapter, native_id, username|
      db[:person_identities].insert(person_id: id, adapter: adapter.to_s, native_id: native_id,
                                    username: username, created_at: stamp)
    end
    id
  end

  def seen(adapter:, native_id:, username: nil, display: nil, community: community_id)
    directory.record(community_id: community, adapter: adapter, native_id: native_id,
                     username: username, display: display)
  end

  describe "#describe" do
    it "answers a person id when the registry links that account to somebody" do
      id = person("Ada Lovelace", identities: [[:telegram, "111", "ada"]])

      found = participants.describe(community_id: community_id, adapter: :telegram,
                                    native_id: "111", display: "Ada")

      expect(found.id).to eq("person:#{id}")
      expect(found.display).to eq("Ada")
      expect(found.platform).to eq("telegram")
    end

    # The whole reason the id exists: the display name is the thing that moves.
    it "answers the same id after they rename themselves" do
      person("Ada Lovelace", identities: [[:telegram, "111", "ada"]])

      first = participants.describe(community_id: community_id, adapter: :telegram,
                                    native_id: "111", display: "Ada")
      later = participants.describe(community_id: community_id, adapter: :telegram,
                                    native_id: "111", display: "somebody else entirely")

      expect(later.id).to eq(first.id)
    end

    # One human's two accounts are one id only where somebody linked them.
    it "follows a linked person across platforms" do
      person("Ada Lovelace", identities: [[:telegram, "111", "ada"], [:discord, "222", "ada"]])

      telegram = participants.describe(community_id: community_id, adapter: :telegram, native_id: "111")
      discord = participants.describe(community_id: community_id, adapter: :discord, native_id: "222")

      expect(discord.id).to eq(telegram.id)
    end

    # And is honest rather than clever where nobody has.
    it "answers a per account id for somebody the registry does not know" do
      found = participants.describe(community_id: community_id, adapter: :telegram,
                                    native_id: "999", display: "Passing By")

      expect(found.id).to eq("telegram:999")
    end

    it "keeps two unlinked accounts of the same human apart, rather than guessing" do
      telegram = participants.describe(community_id: community_id, adapter: :telegram, native_id: "999")
      discord = participants.describe(community_id: community_id, adapter: :discord, native_id: "999")

      expect(discord.id).not_to eq(telegram.id)
    end

    it "answers nothing without enough to key on" do
      expect(participants.describe(community_id: community_id, adapter: :telegram, native_id: nil)).to be_nil
      expect(participants.describe(community_id: nil, adapter: :telegram, native_id: "1")).to be_nil
    end
  end

  describe "#resolve" do
    it "finds somebody by the handle they are seen under" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada Lovelace")

      expect(participants.resolve(community_id: community_id, name: "ada").id).to eq("telegram:111")
    end

    it "finds them by display name too, and takes the @ off a handle" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada Lovelace")

      expect(participants.resolve(community_id: community_id, name: "Ada Lovelace")).not_to be_nil
      expect(participants.resolve(community_id: community_id, name: "@ada")).not_to be_nil
    end

    # The one that matters. Two people answer to the name, and awarding to the
    # wrong one is invisible, so the answer is nothing.
    it "answers nothing when the name means two different people" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada Lovelace")
      seen(adapter: :discord, native_id: "222", username: "ada", display: "Ada Something Else")

      expect(participants.resolve(community_id: community_id, name: "ada")).to be_nil
    end

    # Same two accounts, linked to one human this time, so there is only one
    # answer to give and it can be given.
    it "answers once the two accounts are known to be the same person" do
      id = person("Ada Lovelace", identities: [[:telegram, "111", "ada"], [:discord, "222", "ada"]])
      seen(adapter: :telegram, native_id: "111", username: "ada")
      seen(adapter: :discord, native_id: "222", username: "ada")

      expect(participants.resolve(community_id: community_id, name: "ada").id).to eq("person:#{id}")
    end

    it "answers nothing for a name nobody here goes by" do
      seen(adapter: :telegram, native_id: "111", username: "ada")

      expect(participants.resolve(community_id: community_id, name: "nobody")).to be_nil
    end

    # An exact match settles it, so a longer handle that merely contains the
    # name does not make the name ambiguous.
    it "prefers an exact match over one that merely contains it" do
      seen(adapter: :telegram, native_id: "111", username: "ada")
      seen(adapter: :telegram, native_id: "222", username: "adalovelace")

      expect(participants.resolve(community_id: community_id, name: "ada").id).to eq("telegram:111")
    end

    it "will not reach into another community" do
      seen(adapter: :telegram, native_id: "111", username: "ada", community: other_community_id)

      expect(participants.resolve(community_id: community_id, name: "ada")).to be_nil
    end

    # Fifty sightings that all sort ahead of the real "ada" and resolve to one
    # wrong person collapse to a single candidate once the search is truncated
    # at MATCH_LIMIT, previously handed back with full confidence. Refusing is
    # the only safe answer once the search may have left the real match out.
    it "refuses rather than guessing when more sightings match than MATCH_LIMIT can hold" do
      identities = (1..50).map { |i| [:telegram, "wrong-#{i}", format("aaa-ada%02d", i)] }
      person("Not Ada", identities: identities)
      identities.each do |adapter, native_id, username|
        seen(adapter: adapter, native_id: native_id, username: username)
      end
      seen(adapter: :telegram, native_id: "the-real-one", username: "ada")

      expect(participants.resolve(community_id: community_id, name: "ada")).to be_nil
    end
  end

  describe "#identities" do
    it "answers every account a person has, so a whisper can pick one" do
      id = person("Ada Lovelace", identities: [[:telegram, "111", "ada"], [:discord, "222", "adal"]])

      found = participants.identities(community_id: community_id, id: "person:#{id}")

      expect(found.map(&:adapter)).to contain_exactly("telegram", "discord")
      expect(found.map(&:native_id)).to contain_exactly("111", "222")
    end

    it "answers the one account behind an unlinked id" do
      seen(adapter: :telegram, native_id: "111", username: "ada", display: "Ada")

      found = participants.identities(community_id: community_id, id: "telegram:111")

      expect(found.map(&:native_id)).to eq(["111"])
      expect(found.first.username).to eq("ada")
    end

    # An id arrives from a script, so it may be made up or kept from a room the
    # script no longer runs in. Nothing is answered on the strength of the id
    # alone.
    it "answers nothing for an account this community has never seen" do
      expect(participants.identities(community_id: community_id, id: "telegram:404")).to be_empty
    end

    it "answers nothing for a person in another community" do
      id = person("Ada", community: other_community_id, identities: [[:telegram, "111", "ada"]])

      expect(participants.identities(community_id: community_id, id: "person:#{id}")).to be_empty
    end

    it "answers nothing for something that is not an id at all" do
      expect(participants.identities(community_id: community_id, id: "person")).to be_empty
      expect(participants.identities(community_id: community_id, id: "")).to be_empty
      expect(participants.identities(community_id: community_id, id: nil)).to be_empty
    end
  end
end
