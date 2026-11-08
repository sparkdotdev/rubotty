# frozen_string_literal: true

require "spec_helper"

# The config bootstrap for an operator the platform gives no id for, end to
# end: the seed writes a handle-only identity row, and messages under that
# handle cannot bind a privileged account. An explicit native-id grant is
# required before the account can operate the console.
RSpec.describe "an operator bootstrapped by handle", :control_plane do
  let(:yaml) do
    <<~YAML
      name: handled
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
        dc:
          adapter: discord
          token_env: DC_TOKEN
      storage:
        driver: memory
      behaviour:
        log_level: fatal
        purge_interval: 0
      rooms:
        - id: lounge
          endpoints:
            - id: tg-lounge
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
            - id: dc-lounge
              adapter: discord
              account: dc
              channel_id: "8000000000000000003"
      people:
        - name: alice
          identities:
            discord: ["900"]
          handles:
            telegram: ["alice"]
      operators:
        - name: alice
          identities:
            discord: ["900"]
    YAML
  end

  let(:env) { { "TG_TOKEN" => "tg-token", "DC_TOKEN" => "dc-token" } }
  let(:config) { Rubotty::Config::Loader.load_string(yaml, env: env) }
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:flow) { Rubotty::ControlPlane::OperatorFlow.new(models: models, logger: Rubotty::Log.null) }
  let(:reach) { Rubotty::ControlPlane::AdminReach.new(operator_flow: flow, logger: Rubotty::Log.null) }

  subject(:console) do
    Rubotty::ControlPlane::OperatorConsole.new(operator_flow: flow, reach: reach, logger: Rubotty::Log.null)
  end

  before { Rubotty::ControlPlane::Seed.from_model(config, models: models, slug: "handled") }

  def seed_again = Rubotty::ControlPlane::Seed.from_model(config, models: models, slug: "handled")

  def telegram_row = models.person_identity.where(adapter: "telegram").order(:id).first

  # No request lane is wired, so a sender the console does not recognise gets
  # nil rather than a reply.
  def dm(author) = console.handle_dm(adapter: :telegram, account: "tg", author: author, text: "whoami")

  def alice = Rubotty::Core::Author.new(native_id: "700", username: "alice")

  def impostor = Rubotty::Core::Author.new(native_id: "12321", username: "@Alice")

  it "seeds the operator as a handle with no account behind it" do
    expect([telegram_row.native_id, telegram_row.username, telegram_row.claimed_at])
      .to eq([nil, "alice", nil])
  end

  it "requires an explicit account grant before recognising a Telegram DM" do
    expect(dm(alice)).to be_nil
    expect(dm(impostor)).to be_nil
    expect(telegram_row.native_id).to be_nil
    expect(telegram_row.claimed_at).to be_nil
  end

  it "does not activate a handle-only operator after repeated messages or a reseed" do
    dm(alice)
    seed_again

    expect(telegram_row.native_id).to be_nil
    expect(dm(impostor)).to be_nil
    expect(dm(alice)).to be_nil
  end

  it "recognises a separately approved native account after its handle changes" do
    community = models.community.where(slug: "handled").first
    flow.promote(community_id: community.id, adapter: "telegram", native_id: "700",
                  username: "alice", granted_by: "administrator")

    renamed = Rubotty::Core::Author.new(native_id: "700", username: "renamed")
    expect(dm(renamed)).to include("operator of: handled")
    expect(dm(impostor)).to be_nil
  end
end
