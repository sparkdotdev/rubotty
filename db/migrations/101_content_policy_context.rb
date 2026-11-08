# frozen_string_literal: true

# A check never judged a message alone: it is given the room's preceding lines
# and whatever the message replied to, and #1864 is on record as a match made
# on context rather than on the message. Neither table kept any of it, so the
# corpus a description is rewritten against was missing the half of the input
# that decided some of its own samples.
Sequel.migration do
  change do
    # Stored as it was sent and already truncated, with the other speakers
    # replaced by stable labels: which turn came from whom is what makes an
    # exchange readable, and their names teach a prompt nothing, the same
    # reasoning that keeps an author off the misfire row itself.
    alter_table(:content_policy_actions) do
      add_column :context, String, text: true
    end

    alter_table(:content_policy_misfires) do
      add_column :context, String, text: true
    end
  end
end
