# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The control-plane migrations against a real MariaDB, the mirror of
# control_plane_pg_spec.rb, running only in the MariaDB storage job. Beyond the
# shared contract it proves one MariaDB-specific promise: the shared MySQL adapter
# strips DEFAULT off a TEXT column, and Dialect.prepare is what keeps it.
RSpec.describe "control-plane migrations on mariadb", if: ENV["TEST_MYSQL_DATABASE_URL"] do
  include_examples "the control-plane migration contract", :mdb, "TEST_MYSQL_DATABASE_URL"

  it "keeps the TEXT column defaults MariaDB would otherwise strip" do
    Rubotty::ControlPlane::Migrator.run(db)
    models = Rubotty::ControlPlane.models(db)
    now = Time.now

    community = models.community.create(slug: "c-defaults", name: "Defaults",
                                        created_at: now, updated_at: now)
    connection = models.platform_connection.create(
      community_id: community.id, adapter: "telegram", account: "tg",
      external_id: "-1001", created_at: now, updated_at: now
    )
    # A channel inserted WITHOUT relay, display_name or settings, exactly as channel
    # discovery does, relying on the "{}" defaults the dialect preserves. Unfixed, a
    # fresh MariaDB rejects this insert in strict mode or stores "".
    channel = models.channel.create(
      community_id: community.id, platform_connection_id: connection.id,
      adapter: "telegram", account: "tg", route_key: "-1001/1",
      endpoint_key: "ch:telegram:tg:-1001/1", created_at: now, updated_at: now
    )

    reloaded = models.channel[channel.id]
    expect(reloaded.relay).to eq("{}")
    expect(reloaded.display_name).to eq("{}")
    expect(reloaded.settings).to eq("{}")
    # community.settings carries the same kind of default and must survive too.
    expect(models.community[community.id].settings).to eq("{}")
  end
end
