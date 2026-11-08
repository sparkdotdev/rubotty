# frozen_string_literal: true

require "spec_helper"

# A DM to the bot creates a real request. Where several communities could be
# meant, the lane asks rather than guessing.
RSpec.describe Rubotty::ControlPlane::ControlLane, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:flow) do
    Rubotty::ControlPlane::OperatorFlow.new(models: models, registry: registry, logger: Rubotty::Log.null)
  end

  subject(:lane) { described_class.new(operator_flow: flow, logger: Rubotty::Log.null) }

  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New")
  end

  describe "#request?" do
    it "recognises the common ways to ask" do
      ["operator", "/operator", "operator request", "request operator",
       "I want to become an operator", "become operator"].each do |text|
        expect(lane.request?(text)).to be(true), "expected #{text.inspect} to be recognised"
      end
    end

    it "does not fire on ordinary chatter" do
      ["hello", "how are the operators today", "cooperate with me"].each do |text|
        expect(lane.request?(text)).to be(false), "expected #{text.inspect} not to be recognised"
      end
    end
  end

  describe "#handle_dm" do
    it "creates a request against the single community the account serves and confirms it" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")

      expect(reply).to match(/request to become an operator.*SAMPLE/i)
      pending = flow.pending(community_id: models.community.first.id)
      expect(pending.size).to eq(1)
      expect(pending.first.requester_native_id).to eq("999888")
    end

    it "deduplicates a repeat DM request" do
      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator")
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator")
      expect(reply).to match(/already have a pending/i)
      expect(flow.pending(community_id: models.community.first.id).size).to eq(1)
    end

    it "tells an existing operator there is nothing to request" do
      boss = Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner")
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "operator request")
      expect(reply).to match(/already an operator/i)
    end

    it "answers an unrecognised DM with the public-information notice (#31), taking no other action" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "hi bot")
      expect(reply).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
      expect(reply).to match(/select handful of private communities/i)
      expect(flow.pending(community_id: models.community.first.id)).to be_empty
    end

    it "de-duplicates the notice per sender when a cooldown store is wired, so a spammer is not answered on every line" do
      store = Rubotty::Storage::Memory.new
      cooled = described_class.new(operator_flow: flow, cooldown_store: store, logger: Rubotty::Log.null)

      first = cooled.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "hi bot")
      second = cooled.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "still there?")
      other = Rubotty::Core::Author.new(native_id: "111222", username: "someone-else")
      elsewhere = cooled.handle_dm(adapter: :telegram, account: "telegram", author: other, text: "hello?")

      expect(first).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
      expect(second).to be_nil
      expect(elsewhere).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
    end

    it "can have its notice overridden, and a nil notice stays silent as before #31" do
      custom = described_class.new(operator_flow: flow, notice: "not for you", logger: Rubotty::Log.null)
      expect(custom.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "hi"))
        .to eq("not for you")

      muted = described_class.new(operator_flow: flow, notice: nil, logger: Rubotty::Log.null)
      expect(muted.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "hi")).to be_nil
    end

    it "stays silent when it cannot identify the author" do
      expect(lane.handle_dm(adapter: :telegram, account: "telegram", author: nil, text: "operator request"))
        .to be_nil
    end

    it "is inert with no operations service wired" do
      bare = described_class.new(operator_flow: nil)
      expect(bare.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator")).to be_nil
    end

    # #1884: pressing Start is how a private chat with the bot comes into
    # existence, so it is the first thing anybody ever sends us.
    it "welcomes somebody who presses Start, saying what the bot is and where to go next" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "/start")

      expect(reply).to match(/\AHello, and welcome\./)
      expect(reply).to match(/select handful of private communities/i)
      expect(reply).to match(%r{/role operator})
      expect(flow.pending(community_id: models.community.first.id)).to be_empty
    end

    # A deep link puts a payload after the word, and it is still the button.
    it "welcomes the same way when a deep-link payload rides after the word" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer,
                             text: "/start sample-invite")

      expect(reply).to match(/\AHello, and welcome\./)
    end

    # Silence at the one word a chat cannot avoid sending is exactly what reads
    # as a broken bot, so the cooldown does not get to swallow it.
    it "answers the welcome even once the notice cooldown has fired for that sender" do
      store = Rubotty::Storage::Memory.new
      cooled = described_class.new(operator_flow: flow, cooldown_store: store, logger: Rubotty::Log.null)
      cooled.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "hi bot")

      reply = cooled.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "/start")

      expect(reply).to match(/\AHello, and welcome\./)
    end

    it "reads a bare stop as asking to be left alone, and takes no other action" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "/stop")

      expect(reply).to eq(described_class::QUIET_NOTICE)
      expect(reply).to match(/block or mute this chat/i)
      expect(flow.pending(community_id: models.community.first.id)).to be_empty
    end
  end

  # A request filed against the wrong community can be APPROVED there, which is
  # why the lane asks instead of picking one.
  describe "choosing the community (#250)" do
    # A second live community on the same account, so a DM could mean either.
    def add_second_community
      now = Time.now
      second = models.community.create(slug: "second", name: "Second Guild", status: "active",
                                       settings: "{}", created_at: now, updated_at: now)
      conn = models.platform_connection.create(community_id: second.id, adapter: "telegram",
                                               account: "telegram", external_id: "-100999",
                                               created_at: now, updated_at: now)
      models.channel.create(community_id: second.id, platform_connection_id: conn.id,
                            adapter: "telegram", account: "telegram", route_key: "-100999/1",
                            endpoint_key: "tg-second", label: "s", receives: true, sends: true,
                            relay: "{}", display_name: "{}", settings: '{"chat_id":"-100999"}',
                            created_at: now, updated_at: now)
      second
    end

    let(:store) { Rubotty::Storage::Memory.new }

    subject(:lane) do
      described_class.new(operator_flow: flow, cooldown_store: store, logger: Rubotty::Log.null)
    end

    it "names the community it filed against, even with only one candidate" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")
      expect(reply).to match(/SAMPLE/)
    end

    it "asks which community rather than filing against an assumed one" do
      second = add_second_community

      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")

      expect(reply).to match(/Which community/i)
      expect(reply).to match(/1\. sample \(SAMPLE\)/)
      expect(reply).to match(/2\. second \(Second Guild\)/)
      expect(reply).to match(/Nothing has been filed yet/)
      expect(flow.pending(community_id: models.community.first.id)).to be_empty
      expect(flow.pending(community_id: second.id)).to be_empty
    end

    it "files against the community the requester picks by number" do
      second = add_second_community

      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "2")

      expect(reply).to match(/request to become an operator of Second Guild/i)
      expect(flow.pending(community_id: second.id).size).to eq(1)
      expect(flow.pending(community_id: models.community.first.id)).to be_empty
    end

    it "files against the community the requester picks by slug" do
      second = add_second_community

      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "second")

      expect(reply).to match(/Second Guild/)
      expect(flow.pending(community_id: second.id).size).to eq(1)
    end

    it "takes the community from the gesture itself when it names one" do
      second = add_second_community

      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer,
                             text: "/operator second")

      expect(reply).to match(/Second Guild/)
      expect(flow.pending(community_id: second.id).size).to eq(1)
    end

    it "reads the community's full name in the gesture as readily as its slug" do
      second = add_second_community

      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer,
                             text: "request operator in Second Guild")

      expect(reply).to match(/Second Guild/)
      expect(flow.pending(community_id: second.id).size).to eq(1)
    end

    # A slug that is also an ordinary word must not be read out of a sentence
    # that was not naming a community.
    it "asks rather than reading a slug out of a sentence that merely contains the word" do
      second = add_second_community

      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer,
                             text: "request operator for the second time please")

      expect(reply).to match(/Which community/i)
      expect(flow.pending(community_id: second.id)).to be_empty
    end

    it "asking twice does not file twice" do
      second = add_second_community

      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")
      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")
      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "2")
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")

      expect(reply).to match(/already have a pending operator request of Second Guild/i)
      expect(flow.pending(community_id: second.id).size).to eq(1)
      expect(flow.pending(community_id: models.community.first.id)).to be_empty
    end

    it "answering the same question twice does not file twice either" do
      second = add_second_community

      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")
      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "2")
      # The question is answered, so a second bare "2" is ordinary chatter again.
      second_reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "2")

      expect(second_reply).to eq(described_class::DEFAULT_NOTICE)
      expect(flow.pending(community_id: second.id).size).to eq(1)
    end

    it "reads a bare number as chatter when no question is outstanding" do
      add_second_community

      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "2")

      expect(reply).to eq(described_class::DEFAULT_NOTICE)
      expect(models.operator_request.count).to eq(0)
    end

    it "keeps the once-only notice behaviour while a question is outstanding" do
      add_second_community

      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "operator request")
      first = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "hi bot")
      second = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "still there?")

      expect(first).to eq(described_class::DEFAULT_NOTICE)
      expect(second).to be_nil
    end

    # The candidates come from the sender's identity, so an account serving no
    # community is not a dead end while the directory knows where they are.
    it "asks about the communities the sender has been SEEN in when the account attributes nothing" do
      second = add_second_community
      directory = Rubotty::ControlPlane::IdentityDirectory.new(models: models)
      [models.community.first, second].each do |community|
        directory.record(community_id: community.id, adapter: "telegram",
                         native_id: "999888", username: "newbie", display: "New Bie")
      end

      reply = lane.handle_dm(adapter: :telegram, account: "other-token", author: newcomer,
                             text: "request operator")
      expect(reply).to match(/Which community/i)
      expect(reply).to match(/second \(Second Guild\)/)

      filed = lane.handle_dm(adapter: :telegram, account: "other-token", author: newcomer, text: "2")
      expect(filed).to match(/Second Guild/)
      expect(flow.pending(community_id: second.id).size).to eq(1)
    end

    it "still dead-ends honestly when nothing at all can be attributed" do
      reply = lane.handle_dm(adapter: :telegram, account: "unknown-token", author: newcomer,
                             text: "request operator")
      expect(reply).to match(/could not find a community/i)
      expect(models.operator_request.count).to eq(0)
    end
  end

  # The other role: asking to read ONE community and change nothing in it. It
  # is scoped, so the lane asks which community exactly as it does for an
  # operator request, and an operator of that community decides it.
  describe "a viewer request" do
    let(:community_viewers) do
      Rubotty::ControlPlane::CommunityViewers.new(models: models, logger: Rubotty::Log.null)
    end

    subject(:lane) do
      described_class.new(operator_flow: flow, community_viewers: community_viewers, logger: Rubotty::Log.null)
    end

    def ask(text)
      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: text)
    end

    def community = models.community.first

    it "recognises the common ways to ask" do
      ["/role viewer", "viewer", "request viewer",
       "I would like to become a viewer"].each do |text|
        recognised = !lane.role_asked(text).nil? || lane.viewer_request?(text)
        expect(recognised).to be(true), "expected #{text.inspect} to be recognised"
      end
    end

    it "does not fire on ordinary chatter" do
      ["hello", "who is viewing the logs", "reviewer notes"].each do |text|
        expect(lane.viewer_request?(text)).to be(false), "expected #{text.inspect} not to be recognised"
      end
    end

    it "records a pending request against the community and says an operator decides it" do
      reply = ask("/role viewer")

      expect(reply).to match(/operator there will review it/i)
      pending = community_viewers.pending(community_id: community.id)
      expect(pending.size).to eq(1)
      expect(pending.first[:requester_native_id]).to eq("999888")
      expect(pending.first[:requester_username]).to eq("newbie")
    end

    it "files nothing a second time" do
      ask("/role viewer")
      reply = ask("/role viewer")

      expect(reply).to match(/already have a pending/i)
      expect(community_viewers.pending(community_id: community.id).size).to eq(1)
    end

    it "takes the smaller ask when a message names both roles" do
      ask("I would like to become a viewer, or an operator if that is easier")

      expect(community_viewers.pending(community_id: community.id).size).to eq(1)
      expect(models.operator_request.count).to eq(0)
    end

    it "tells somebody who already reads the community there is nothing to ask for" do
      community_viewers.grant(community_id: community.id, adapter: "telegram",
                              handle: "newbie", native_id: "999888", granted_by: "admin")

      expect(ask("/role viewer")).to match(/already read/i)
      expect(community_viewers.pending(community_id: community.id)).to be_empty
    end

    # A lane with nowhere to file one says so rather than promising what it
    # cannot keep.
    it "answers plainly when no roster is wired" do
      bare = described_class.new(operator_flow: flow, logger: Rubotty::Log.null)

      expect(bare.viewer_request?("/role viewer")).to be(false)
      expect(bare.handle_dm(adapter: :telegram, account: "telegram", author: newcomer,
                            text: "/role viewer")).to match(/not available on this deployment/i)
    end

    # The deployment-wide dimension reads every OTHER community too, so no DM
    # asks for it: an administrator hands it out from the dashboard.
    it "never files a deployment-wide request, whatever the wording" do
      deployment = Rubotty::ControlPlane::DashboardViewers.new(models: models, logger: Rubotty::Log.null)

      ["/role viewer", "admin-viewer", "I want to read every community"].each { |text| ask(text) }

      expect(deployment.pending).to be_empty
    end
  end

  # One verb, with the role as its argument, so a role added later mints no new
  # command word.
  describe "the role command" do
    let(:community_viewers) do
      Rubotty::ControlPlane::CommunityViewers.new(models: models, logger: Rubotty::Log.null)
    end

    subject(:lane) do
      described_class.new(operator_flow: flow, community_viewers: community_viewers, logger: Rubotty::Log.null)
    end

    def ask(text)
      lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: text)
    end

    def community = models.community.first

    it "files an operator request for `/role operator`" do
      reply = ask("/role operator")

      expect(reply).to match(/request to become an operator/i)
      expect(flow.pending(community_id: community.id).size).to eq(1)
      expect(community_viewers.pending(community_id: community.id)).to be_empty
    end

    it "files a viewer request for `/role viewer`" do
      reply = ask("/role viewer")

      expect(reply).to match(/request to become a viewer/i)
      expect(community_viewers.pending(community_id: community.id).size).to eq(1)
      expect(flow.pending(community_id: community.id)).to be_empty
    end

    it "lists the roles when the command names none" do
      reply = ask("/role")

      expect(reply).to match(/role operator/)
      expect(reply).to match(/role viewer/)
      expect(flow.pending(community_id: community.id)).to be_empty
    end

    it "lists them again for a role nobody has, rather than going quiet" do
      expect(ask("/role wizard")).to match(/which role/i)
    end

    # Muscle memory keeps working, and the reply says what to type next time.
    it "still answers the old `/operator` word, and names the new one" do
      reply = ask("/operator")

      expect(reply).to match(/request to become an operator/i)
      expect(reply).to include("/role operator")
      expect(flow.pending(community_id: community.id).size).to eq(1)
    end
  end
end
