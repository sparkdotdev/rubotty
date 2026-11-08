# frozen_string_literal: true

require "spec_helper"

# space_external_id's case statement used to have no branch for api_wrapper,
# so a room built from an api_wrapper endpoint raised Rubotty::Error from
# inside upsert_connection, and Seed#run's own db.transaction aborted the
# whole seed rather than just that one connection.
RSpec.describe "seeding an api_wrapper room", :control_plane do
  let(:env) { { "WRAPPER_SECRET" => "whsec_test" } }

  def api_wrapper_yaml
    <<~YAML
      name: api wrapper seed test
      accounts:
        wrapper:
          adapter: api_wrapper
          webhook_url: https://example.invalid/hook
          signing_secret_env: WRAPPER_SECRET
      rooms:
        - id: lounge
          endpoints:
            - id: wrapper-lounge
              adapter: api_wrapper
              account: wrapper
              channel_id: "lounge"
            - id: wrapper-lounge-overflow
              adapter: api_wrapper
              account: wrapper
              channel_id: "lounge-overflow"
    YAML
  end

  let(:model) { Rubotty::Config::Loader.load_string(api_wrapper_yaml, env: env) }
  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  it "seeds the room and its endpoints without raising" do
    expect do
      Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "wrapper-test")
    end.not_to raise_error

    expect(models.room.count).to eq(1)
    expect(models.channel.where(adapter: "api_wrapper").count).to eq(2)
  end

  it "scopes the platform connection by account, the same as a live account resolves" do
    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "wrapper-test")

    connection = models.platform_connection.where(adapter: "api_wrapper", account: "wrapper").first
    expect(connection).not_to be_nil
    expect(connection.external_id).to eq("wrapper")
  end
end
