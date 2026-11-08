# frozen_string_literal: true

require "spec_helper"

# /nickname against the real seeded SAMPLE control plane. What the command surface
# owns is the permission level and the wording; the rules about what a nickname
# may be and who already holds one live in ControlPlane::BridgedNicknames.
RSpec.describe Rubotty::Features::Nickname, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:nicknames) { Rubotty::ControlPlane::BridgedNicknames.new(models: models, logger: Rubotty::Log.null) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      nicknames: nicknames, registry: registry, ephemeral: ephemeral
    )
  end

  # The seeded bootstrap operator on Telegram.
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  def member
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New")
  end

  def run(text, author:, config: {})
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key("tg-general")
    msg = message(channel.endpoint, text: text, native_id: "m#{rand(100_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel,
                                                config: config))
  end

  def last_reply = adapter.delivered_to("tg-general").last&.body&.text

  def community_id = models.community.where(slug: "sample").first.id

  def held_by(author)
    person = nicknames.person_for(community_id: community_id, adapter: "telegram", native_id: author.native_id)
    person && nicknames.for_person(community_id: community_id, person_id: person.id)
  end

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat" do
      expect(described_class.feature_name).to eq("nickname")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "defaults to operators only, which is the level a community starts at" do
      field = described_class.config_schema.fields[:who_can_set]
      expect(field.default).to eq(described_class::WHO_OPERATORS)
      expect(field.one_of.map(&:to_s)).to contain_exactly("nobody", "operators", "everyone")
    end

    it "leaves an ordinary message alone so the bridge relays it" do
      expect(run("just chatting", author: boss)).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "leaves another feature's command alone" do
      expect(run("/watch aoe3", author: boss)).to be_continue
    end

    it "refuses rather than relays a recognised /nickname without a control plane" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "/nickname")))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/nickname")
    end

    it "still lets an unrecognised message continue with no control plane at all" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "setting one" do
    it "lets an operator choose the name they are bridged as on a platform" do
      outcome = run("/nickname discord owner", author: boss)

      expect(outcome).to be_halt
      expect(last_reply).to include("On discord you are now shown as owner")
      expect(held_by(boss)).to eq("discord" => "owner")
    end

    it "keeps one name per platform, so a second platform is a second choice" do
      run("/nickname discord owner", author: boss)
      run("/nickname telegram mattp", author: boss)

      expect(held_by(boss)).to eq("discord" => "owner", "telegram" => "mattp")
    end

    it "refuses a name somebody else already holds and says so" do
      run("/nickname discord owner", author: boss)

      run("/nickname discord owner", author: member, config: { who_can_set: "everyone" })

      expect(last_reply).to include("already taken on discord")
      expect(held_by(member)).to be_empty
    end

    it "refuses a platform this community does not bridge" do
      run("/nickname myspace owner", author: boss)

      expect(last_reply).to include("no myspace in this community")
    end

    # The dashboard takes the whole field, so the command has to take the whole
    # rest of the line or a name with a space in it would arrive truncated.
    it "takes a display name with spaces and emoji in it, whole" do
      run("/nickname discord River the Third 🇵🇹", author: boss)

      expect(last_reply).to include("shown as River the Third 🇵🇹")
      expect(held_by(boss)).to eq("discord" => "River the Third 🇵🇹")
    end

    it "passes the store's own refusal through in the reply" do
      run("/nickname discord a", author: boss)

      expect(last_reply).to include("characters")
      expect(held_by(boss)).to be_empty
    end

    it "makes the new name live without a restart" do
      run("/nickname discord owner", author: boss)

      person = registry.current.people.by_handle(:discord, "owner")
      expect(person).not_to be_nil
      expect(person.nickname_on(:discord)).to eq("owner")
    end
  end

  describe "who may set one" do
    it "lets an ordinary member set one at everyone" do
      run("/nickname discord newbie2", author: member, config: { who_can_set: "everyone" })

      expect(last_reply).to include("now shown as newbie2")
    end

    it "refuses an ordinary member at the operators default" do
      run("/nickname discord newbie2", author: member)

      expect(last_reply).to include("Only an operator")
      expect(held_by(member)).to be_empty
    end

    it "refuses everybody at nobody, operators included" do
      run("/nickname discord owner", author: boss, config: { who_can_set: "nobody" })

      expect(last_reply).to include("not being handed out")
      expect(held_by(boss)).to be_empty
    end

    it "treats an unrecognised level as the operators default rather than opening up" do
      run("/nickname discord newbie2", author: member, config: { who_can_set: "anyone at all" })

      expect(last_reply).to include("Only an operator")
    end
  end

  describe "showing what you are bridged as" do
    it "lists every platform with a chosen name" do
      run("/nickname discord owner", author: boss)
      run("/nickname telegram mattp", author: boss)

      run("/nickname", author: boss)

      expect(last_reply).to include("on discord: owner").and include("on telegram: mattp")
    end

    it "says so plainly when there is nothing set" do
      run("/nickname", author: boss)

      expect(last_reply).to include("not shown under a chosen name")
    end

    it "answers help without setting anything" do
      run("/nickname help", author: boss)

      expect(last_reply).to include("/nickname <platform> <name>")
      expect(held_by(boss)).to be_empty
    end
  end

  # An operator has to be able to see one before deciding to clear it.
  describe "reading the whole community's" do
    it "lists every claimed nickname for an operator" do
      run("/nickname discord owner", author: boss)
      run("/nickname discord rude", author: member, config: { who_can_set: "everyone" })

      run("/nickname list", author: boss)

      expect(last_reply).to include("owner on discord")
      expect(last_reply).to include("rude on discord")
    end

    it "says so plainly when nobody has one" do
      run("/nickname list", author: boss)

      expect(last_reply).to include("Nobody has chosen")
    end

    it "refuses an ordinary member, who has no business reading it" do
      run("/nickname discord owner", author: boss)

      run("/nickname list", author: member, config: { who_can_set: "everyone" })

      expect(last_reply).to include("Only an operator")
      expect(last_reply).not_to include("owner on discord")
    end
  end

  describe "clearing one" do
    it "drops your own on one platform and leaves the others" do
      run("/nickname discord owner", author: boss)
      run("/nickname telegram mattp", author: boss)

      run("/nickname clear discord", author: boss)

      expect(last_reply).to include("ordinary handle again")
      expect(held_by(boss)).to eq("telegram" => "mattp")
    end

    it "says there was nothing to clear rather than pretending" do
      run("/nickname clear discord", author: boss)

      expect(last_reply).to include("no nickname on discord to clear")
    end

    # The lever for a name that has become a problem.
    it "lets an operator clear somebody else's by naming it" do
      run("/nickname discord rude", author: member, config: { who_can_set: "everyone" })

      run("/nickname clear discord rude", author: boss)

      expect(last_reply).to include("Cleared rude on discord")
      expect(held_by(member)).to be_empty
    end

    it "refuses an ordinary member clearing somebody else's" do
      run("/nickname discord owner", author: boss)

      run("/nickname clear discord owner", author: member, config: { who_can_set: "everyone" })

      expect(last_reply).to include("Only an operator can clear")
      expect(held_by(boss)).to eq("discord" => "owner")
    end

    it "tells an operator when the name they named belongs to nobody" do
      run("/nickname clear discord ghost", author: boss)

      expect(last_reply).to include("Nobody here is called ghost")
    end

    it "clears a name with spaces in it, which is the only way to name one" do
      run("/nickname discord Rude Person", author: member, config: { who_can_set: "everyone" })

      run("/nickname clear discord Rude Person", author: boss)

      expect(last_reply).to include("Cleared Rude Person on discord")
      expect(held_by(member)).to be_empty
    end
  end

  describe "without a control plane to store one in" do
    subject(:feature) do
      described_class.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        nicknames: nil, ephemeral: ephemeral
      )
    end

    it "refuses the command rather than relaying it" do
      outcome = run("/nickname discord owner", author: boss)
      expect(outcome).to be_halt
      expect(last_reply).to include("/nickname")
    end
  end
end
