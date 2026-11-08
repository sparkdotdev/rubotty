# frozen_string_literal: true

# What the last webhook resolution on this channel actually found: active
# (posting under the sender's own name), degraded (the bot lacks Manage
# Webhooks or an explicit webhook_url is bad, so it silently fell back to
# posting as itself) or off (webhook: off, an operator's own choice). Written
# by Core::PuppetStatusSweep from each live adapter's own cache, nil until a
# message has actually gone out through the channel since the last restart.
Sequel.migration do
  change do
    alter_table(:channels) do
      add_column :puppet_status, String, size: 16
      add_column :puppet_checked_at, DateTime
    end
  end
end
