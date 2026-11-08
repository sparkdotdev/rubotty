# frozen_string_literal: true

require "spec_helper"

# `/auth <token>`: the DM that turns a token somebody was handed into a role and
# a sign-in link, on both surfaces a DM can land on.
RSpec.describe Rubotty::ControlPlane::AuthCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db, logger: Rubotty::Log.null) }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:flow) do
    Rubotty::ControlPlane::OperatorFlow.new(models: models, registry: registry, logger: Rubotty::Log.null)
  end
  let(:reach) { Rubotty::ControlPlane::AdminReach.new(operator_flow: flow, logger: Rubotty::Log.null) }
  let(:community_viewers) do
    Rubotty::ControlPlane::CommunityViewers.new(models: models, audit: audit, logger: Rubotty::Log.null)
  end
  let(:dashboard_viewers) do
    Rubotty::ControlPlane::DashboardViewers.new(models: models, audit: audit, logger: Rubotty::Log.null)
  end
  let(:dashboard_administrators) do
    Rubotty::ControlPlane::DashboardAdministrators.new(models: models, audit: audit,
                                                       logger: Rubotty::Log.null)
  end
  let(:tokens) do
    Rubotty::ControlPlane::AuthTokens.new(
      models: models, operator_flow: flow, community_viewers: community_viewers,
      dashboard_viewers: dashboard_viewers, dashboard_administrators: dashboard_administrators,
      audit: audit, logger: Rubotty::Log.null
    )
  end

  # The same get_state/put_state surface the message map's key/value table has.
  let(:store) do
    Class.new do
      def initialize = @rows = {}

      def get_state(key)
        row = @rows[key.to_s]
        return nil if row.nil?
        return nil if row[:expires_at] && row[:expires_at] <= Time.now

        row[:value]
      end

      def put_state(key, value, expires_at: nil)
        @rows[key.to_s] = { value: value.to_s, expires_at: expires_at }
        nil
      end
    end.new
  end

  let(:web_login) { Rubotty::ControlPlane::WebLoginTokens.new(store: store, logger: Rubotty::Log.null) }

  subject(:command) do
    described_class.new(
      tokens: tokens, web_login: web_login, reach: reach, viewers: dashboard_viewers,
      administrators: dashboard_administrators, community_viewers: community_viewers,
      dashboard_url: "https://dash.example", logger: Rubotty::Log.null
    )
  end

  def newcomer = Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New")

  def admin_minter
    Rubotty::ControlPlane::AuthTokens::Minter.new(
      administrator: true, community_ids: [], label: "dashboard:administrator"
    )
  end

  def mint(**kwargs)
    tokens.mint(minter: admin_minter, **kwargs).token
  end

  def say(text, author: newcomer)
    command.redeem(adapter: :telegram, account: "telegram", author: author, token: text)
  end

  # The link the reply carries, so a spec can go and redeem it.
  def link_token(reply)
    reply[%r{operator-login\?token=(\S+)}, 1]
  end

  describe "an operator token" do
    it "grants operator and says which community" do
      reply = say(mint(community_id: community.id, operator: true))

      expect(reply).to include("you now operate sample")
      expect(flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                   native_id: "999888", username: "newbie")).not_to be_nil
    end
  end

  describe "a viewer token" do
    it "grants reading the one community and says so" do
      reply = say(mint(community_id: community.id, viewer: true))

      expect(reply).to include("you now read sample")
      expect(community_viewers.viewer?(community_id: community.id, adapter: "telegram",
                                       native_id: "999888", username: "newbie")).to be(true)
    end
  end

  describe "a token carrying both" do
    it "grants both and names the community once, since operating it already reads it" do
      reply = say(mint(community_id: community.id, operator: true, viewer: true))

      expect(reply).to include("you now operate sample")
      expect(reply.scan("sample").size).to eq(1)
      expect(community_viewers.viewer?(community_id: community.id, adapter: "telegram",
                                       native_id: "999888", username: "newbie")).to be(true)
    end
  end

  describe "a deployment-wide viewer token" do
    it "grants reading everything and says the shape of it" do
      reply = say(mint(community_id: nil, viewer: true))

      expect(reply).to include("you now read every community, and change nothing anywhere")
      expect(dashboard_viewers.viewer?(adapter: "telegram", native_id: "999888", username: "newbie")).to be(true)
    end
  end

  # The role a token can now also carry. The link that comes back with it has to
  # carry it too, otherwise the person it was just granted to would be rate
  # limited out of asking for one that does.
  describe "an administrator token" do
    it "grants the role and says what it is" do
      reply = say(mint(community_id: nil, administrator: true))

      expect(reply).to include("you now administer this deployment")
      expect(dashboard_administrators.administrator?(adapter: "telegram", native_id: "999888", username: "newbie")).to be(true)
    end

    it "sends back a link that already carries the role" do
      reply = say(mint(community_id: nil, administrator: true))

      expect(web_login.redeem(token: link_token(reply)).administrator).to be(true)
    end

    it "carries the handle on that link, so the dashboard can ask the roster again" do
      reply = say(mint(community_id: nil, administrator: true))

      expect(web_login.redeem(token: link_token(reply)).operator["username"]).to eq("newbie")
    end
  end

  describe "the sign-in link" do
    it "comes in the same reply, with the expiry stated" do
      reply = say(mint(community_id: community.id, operator: true))

      expect(reply).to include("https://dash.example/operator-login?token=")
      expect(reply).to match(/stops working in about \d+ minutes?/)
      expect(reply).to include("asks you to confirm")
    end

    it "works once and no more" do
      token = link_token(say(mint(community_id: community.id, operator: true)))

      expect(web_login.redeem(token: token)).to be_ok
      expect(web_login.redeem(token: token).status).to eq(:invalid)
    end

    it "expires whether or not it was used" do
      short = Rubotty::ControlPlane::WebLoginTokens.new(store: store, ttl: -10, logger: Rubotty::Log.null)
      brief = described_class.new(tokens: tokens, web_login: short, reach: reach, viewers: dashboard_viewers,
                                  community_viewers: community_viewers, dashboard_url: "https://dash.example",
                                  logger: Rubotty::Log.null)

      reply = brief.redeem(adapter: :telegram, account: "telegram", author: newcomer,
                           token: mint(community_id: community.id, operator: true))

      expect(web_login.redeem(token: link_token(reply)).status).to eq(:invalid)
    end

    it "carries exactly what the redeemer now holds" do
      token = link_token(say(mint(community_id: community.id, operator: true)))

      session = web_login.redeem(token: token)

      expect(session.community_ids).to eq([community.id])
      expect(session.viewer).to be(false)
    end

    it "carries the deployment-wide dimension when that is what was granted" do
      token = link_token(say(mint(community_id: nil, viewer: true)))

      session = web_login.redeem(token: token)

      expect(session.viewer).to be(true)
      expect(session.community_ids).to eq([])
    end
  end

  describe "a token that does not work" do
    it "answers the same thing whether it never existed, went already, or expired" do
      spent = mint(community_id: community.id, viewer: true)
      say(spent, author: Rubotty::Core::Author.new(native_id: "1", username: "first"))
      stale = mint(community_id: community.id, viewer: true)
      db[:auth_tokens].where(token_hash: Rubotty::ControlPlane::AuthTokens.hash_token(stale))
                      .update(expires_at: Time.now - 60)

      replies = [say("never-existed"), say(spent), say(stale)]

      expect(replies.uniq).to eq([Rubotty::ControlPlane::AuthTokens::REFUSAL])
    end

    it "asks for the token when the command arrives with nothing after it" do
      expect(say("")).to eq(described_class::HELP)
    end

    it "stops answering after a run of guesses" do
      Rubotty::ControlPlane::AuthTokens::ATTEMPT_MAX.times { say("guess") }

      expect(say("guess")).to eq(described_class::THROTTLED)
    end
  end

  # Both DM surfaces have to route the command to the same place, since somebody
  # holding a role reaches one and a stranger reaches the other.
  describe "on the DM surfaces" do
    let(:lane) do
      Rubotty::ControlPlane::ControlLane.new(
        operator_flow: flow, reach: reach, community_viewers: community_viewers,
        auth: command, logger: Rubotty::Log.null
      )
    end
    let(:console) do
      Rubotty::ControlPlane::OperatorConsole.new(
        operator_flow: flow, reach: reach, request_lane: lane, viewers: dashboard_viewers,
        community_viewers: community_viewers, auth: command, logger: Rubotty::Log.null
      )
    end

    # Already an operator of sample through the seeded configuration, so their DM
    # reaches the console rather than the lane.
    def boss = Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner")

    def other_community
      id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
      models.community[id]
    end

    it "redeems through the request lane, which is where a stranger's DM lands" do
      token = mint(community_id: community.id, viewer: true)

      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "/auth #{token}")

      expect(reply).to include("you now read sample")
    end

    it "redeems through the console, for somebody who already holds a role elsewhere" do
      elsewhere = other_community
      token = mint(community_id: elsewhere.id, operator: true)

      reply = console.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "/auth #{token}")

      expect(reply).to include("you now operate other-co")
    end

    it "leaves ordinary chatter that merely mentions the word alone" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer,
                             text: "who authorises this?")

      expect(reply).to eq(Rubotty::ControlPlane::ControlLane::DEFAULT_NOTICE)
    end

    it "asks for the token on the bare command rather than treating it as chatter" do
      reply = lane.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "/auth")

      expect(reply).to eq(described_class::HELP)
    end

    it "offers the command on the console's own help" do
      reply = console.handle_dm(adapter: :telegram, account: "telegram", author: boss, text: "help")

      expect(reply).to include("auth <token>")
    end

    it "declines honestly on a deployment with nowhere to redeem one" do
      bare = Rubotty::ControlPlane::ControlLane.new(operator_flow: flow, reach: reach,
                                                    logger: Rubotty::Log.null)

      reply = bare.handle_dm(adapter: :telegram, account: "telegram", author: newcomer, text: "/auth abc")

      expect(reply).to match(/not available on this deployment/)
    end
  end
end
