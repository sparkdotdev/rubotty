# frozen_string_literal: true

require "sequel"

# Helpers for the control-plane specs: a migrated in-memory database and the
# SAMPLE fixture configuration the specs own (spec/fixtures/control_plane), not
# the deployment's bridge.config.yaml. See issue #1355.
module ControlPlaneHelpers
  CONFIG_PATH = File.expand_path("../fixtures/control_plane/sample.config.yaml", __dir__)

  # Dummy env so the loader resolves the two token_env fields. No token is real.
  CONFIG_ENV = { "TELEGRAM_BOT_TOKEN" => "tg-token", "DISCORD_BOT_TOKEN" => "dc-token" }.freeze

  # The seeded fixture's bootstrap operator is "sample_owner", which is also
  # one of the deployment-configured owner floor's handles, so a spec about what an ORDINARY
  # operator's rows reach would otherwise be answered by the floor granting
  # every community instead. Silences the floor so the rows are what is tested;
  # the floor's own reach has its own examples.
  def without_owner_floor
    allow(Rubotty::Security::ProtectedOperators).to receive(:default)
      .and_return(Rubotty::Security::ProtectedOperators.new(usernames: [], matrix_ids: [], ids: {}))
  end

  def sample_model
    Rubotty::Config::Loader.load_file(CONFIG_PATH, env: CONFIG_ENV)
  end

  def migrated_db
    db = Sequel.sqlite
    Rubotty::ControlPlane.migrate!(db)
    db
  end

  def build_models(db)
    Rubotty::ControlPlane.models(db)
  end

  # A migrated db seeded with SAMPLE, plus its models, in one call.
  def seeded_sample(slug: "sample")
    db = migrated_db
    models = build_models(db)
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: slug)
    [db, models]
  end
end

RSpec.configure do |config|
  config.include ControlPlaneHelpers, :control_plane
end
