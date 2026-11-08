# frozen_string_literal: true

require "time"
require "tzinfo"

# Before 2026-08-15 15:30 UTC, a bare event time was stored as though its
# wall-clock fields were already UTC. Correct still-scheduled events in a
# named IANA timezone once, preserving their intended local date and clock.
# Explicit UTC and offset inputs cannot be distinguished after storage, so
# only the non-UTC named-zone rows affected by that parser are eligible.
module LegacyEventTimezoneCorrection
  CUTOFF = Time.utc(2026, 8, 15, 15, 30, 0) unless const_defined?(:CUTOFF, false)

  module_function

  def stored_time(value)
    return value.to_time.utc if value.respond_to?(:to_time)

    Time.parse("#{value} UTC").utc
  end

  def corrected_time(value, zone)
    stored = stored_time(value)
    local = Time.utc(stored.year, stored.month, stored.day, stored.hour, stored.min, stored.sec)
    zone.local_to_utc(local, false) { |periods| periods.last }.utc
  end
end

Sequel.migration do
  up do
    events = self[:events]
    events.where(status: "scheduled").where { created_at < LegacyEventTimezoneCorrection::CUTOFF }
          .exclude(timezone: nil).exclude(timezone: "").each do |row|
      zone = TZInfo::Timezone.get(row[:timezone])
      starts_at = LegacyEventTimezoneCorrection.corrected_time(row[:starts_at], zone)
      ends_at = row[:ends_at] && LegacyEventTimezoneCorrection.corrected_time(row[:ends_at], zone)
      changes = {}
      changes[:starts_at] = starts_at if starts_at != LegacyEventTimezoneCorrection.stored_time(row[:starts_at])
      changes[:ends_at] = ends_at if ends_at && ends_at != LegacyEventTimezoneCorrection.stored_time(row[:ends_at])
      events.where(id: row[:id]).update(changes.merge(updated_at: Time.now.utc)) unless changes.empty?
    rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::PeriodNotFound
      # A legacy free-text timezone or an impossible spring-forward clock has
      # no safe conversion. Leaving that row alone is better than guessing.
      next
    end
  end

  down do
    # This is a one-way data correction. Reversing it would damage events
    # created after the parser fix or subsequently edited with the right time.
  end
end
