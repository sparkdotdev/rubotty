# frozen_string_literal: true

# Announcer#refresh_one always re-rendered a tracked card under "New event",
# since event_cards never recorded which heading it was actually posted
# under. An edited event re-posts under "Event updated"; the next RSVP on
# that copy edited the text right back to "New event". Existing rows predate
# this column and were every one of them posted as a fresh card, so "New
# event" is the correct backfill default rather than a guess.
Sequel.migration do
  up do
    alter_table(:event_cards) do
      add_column :heading, String, size: 40, null: false, default: "New event"
    end
  end

  down do
    alter_table(:event_cards) do
      drop_column :heading
    end
  end
end
