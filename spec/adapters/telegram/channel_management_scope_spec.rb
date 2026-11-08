# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Issues #1781 and #1783. One Telegram token serves every community that
# bridged a topic on it, and neither channel management call had a parameter
# for a community at all, so both took whichever chat the account knew first.
# On deleteForumTopic that destroyed a topic in a supergroup that never asked.
RSpec.describe Rubotty::Adapters::Telegram::Adapter, "channel management on a shared token" do
  let(:http) { Fakes::TelegramHttp.new }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "error", io: logs) }
  let(:alpha) { CollidingCommunities::ALPHA }
  let(:beta) { CollidingCommunities::BETA }
  let(:alpha_chat) { CollidingCommunities::CHAT_IDS.fetch("alpha") }
  let(:beta_chat) { CollidingCommunities::CHAT_IDS.fetch("beta") }

  def telegram_endpoints_of(spec)
    colliding_endpoints(spec[:slug], spec[:id], adapters: [:telegram])
  end

  def adapter_over(endpoints)
    described_class.new(
      account: "shared",
      settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new,
      logger: logger,
      endpoints: endpoints
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
  end

  # The live shape: both communities on one account, alpha's chat first.
  let(:shared_token) { adapter_over(telegram_endpoints_of(alpha) + telegram_endpoints_of(beta)) }
  let(:one_chat) { adapter_over(telegram_endpoints_of(beta)) }

  describe "#delete_channel, which destroys content rather than merely disclosing it" do
    before { http.on("deleteForumTopic", true) }

    it "resolves a bare thread id inside the asking community, not the first chat on the account" do
      expect(shared_token.delete_channel("555", community_id: beta[:id])).to be(true)
      expect(http.calls("deleteForumTopic").first.params).to include(
        "chat_id" => beta_chat, "message_thread_id" => 555
      )
    end

    it "refuses a native id naming a chat that community bridges nothing in" do
      expect(shared_token.delete_channel("#{alpha_chat}/555", community_id: beta[:id])).to be(false)
      expect(http.called?("deleteForumTopic")).to be(false)
    end

    it "says which chat it refused to delete out of, at error level" do
      shared_token.delete_channel("#{alpha_chat}/555", community_id: beta[:id])

      expect(logs.string).to include("REFUSED", alpha_chat)
    end

    it "refuses a bare thread id for a community that bridges nothing here at all" do
      expect(shared_token.delete_channel("555", community_id: 99)).to be(false)
      expect(http.called?("deleteForumTopic")).to be(false)
    end

    it "still deletes a topic whose native id names its own community's chat" do
      expect(one_chat.delete_channel("#{beta_chat}/555", community_id: beta[:id])).to be(true)
      expect(http.calls("deleteForumTopic").first.params).to include("chat_id" => beta_chat)
    end
  end

  describe "#create_channel" do
    before { http.on("createForumTopic", { "message_thread_id" => 555, "name" => "Gaming" }) }

    it "provisions into the asking community's supergroup, not whichever sorts first" do
      expect(shared_token.create_channel(name: "Gaming", community_id: beta[:id])).to eq("#{beta_chat}/555")
      expect(http.calls("createForumTopic").first.params).to include("chat_id" => beta_chat)
    end

    it "refuses rather than provisioning for a community that bridges nothing here" do
      expect(shared_token.create_channel(name: "Gaming", community_id: 99)).to be_nil
      expect(http.called?("createForumTopic")).to be(false)
    end

    it "names the topic it refused to create, at error level" do
      shared_token.create_channel(name: "Gaming", community_id: 99)

      expect(logs.string).to include("REFUSED", "Gaming")
    end
  end

  # Issue #1783: the contract carried no community, so an implementation with
  # nothing to scope by was the only one that could be written.
  describe "the shape of the calls" do
    it "has no overload of either call that takes a bare name or native id" do
      expect { shared_token.create_channel(name: "Gaming") }.to raise_error(ArgumentError)
      expect { shared_token.delete_channel("555") }.to raise_error(ArgumentError)
    end

    it "refuses an explicit nil community rather than falling back to the account" do
      expect { one_chat.create_channel(name: "Gaming", community_id: nil) }.to raise_error(ArgumentError)
      expect { one_chat.delete_channel("555", community_id: nil) }.to raise_error(ArgumentError)
    end
  end
end
