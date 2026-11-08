# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Resolves the room-scoped events policy: whether event scheduling is
    # turned on for a room and who may create an event there. Mirrors
    # {GuestInvites#room_policy} (community row then room row, room wins, same
    # "operators" default for an unrecognised value) and reads off
    # feature_settings rather than a live Snapshot, so a caller without a
    # Registry can resolve it. Deliberately READ ONLY: issuing an event, and
    # enforcing who_can_create against the person attempting one, belongs to
    # the creation surfaces.
    class EventPolicy
      # @param models [ControlPlane::Models] bound to the control-plane database
      def initialize(models:)
        @models = models
      end

      # The events policy for a room: whether the feature is ON (room row over the
      # community default) and WHO may create an event there.
      #
      # @param community [Models::Community]
      # @param room [Models::Room, nil] nil resolves the community default alone
      # @return [Hash] { enabled: Boolean, who_can_create: String }
      def room_policy(community:, room:)
        room_row, community_row, config = resolved_config(community_id: community.id, room_id: room&.id)
        enabled = if room_row then to_bool(room_row.enabled)
                  elsif community_row then to_bool(community_row.enabled)
                  else false
                  end
        who = config["who_can_create"].to_s
        who = Features::Events::WHO_OPERATORS unless Features::Events::WHO_CAN_CREATE.include?(who)
        { enabled: enabled, who_can_create: who }
      end

      # Whether an issuer in role +as+ (:operator or :member) may create an event
      # under a resolved +who_can_create+ value. An operator always may; a member
      # may only where the room is set to "everyone".
      def permitted?(who_can_create, as)
        return true if as.to_sym == :operator

        who_can_create.to_s == Features::Events::WHO_EVERYONE
      end

      # The reminder ladder an event with no override of its own uses: the
      # room's own default_reminder_intervals config over the community's,
      # over the feature's own hardcoded default. Read off feature_settings by
      # id, so {Events::Reminders} can resolve it from a durable job's payload
      # (community_id and room_id, never full Community/Room rows).
      #
      # @return [Array<Integer>]
      def reminder_intervals_for(community_id:, room_id:)
        configured = configured_reminder_intervals(community_id, room_id)
        configured.nil? ? Features::Events::DEFAULT_REMINDER_INTERVALS : configured
      end

      private

      # nil when the key was never configured at either scope, so the caller
      # falls back to the hardcoded default; an explicit empty array is
      # returned as-is, since a community may deliberately configure "no
      # reminders by default".
      def configured_reminder_intervals(community_id, room_id)
        _room_row, _community_row, config = resolved_config(community_id: community_id, room_id: room_id)
        value = config["default_reminder_intervals"]
        return nil if value.nil?

        Array(value).map(&:to_i).select(&:positive?)
      end

      # The room row, community row, and merged config (room over community)
      # for the events feature, shared by every caller that needs the
      # room-over-community precedence: {#room_policy} and
      # {#configured_reminder_intervals}.
      def resolved_config(community_id:, room_id:)
        rows = @models.feature_setting.where(community_id: community_id, feature: Features::Events.feature_name).all
        room_row = room_id && rows.find { |row| row.room_id == room_id }
        community_row = rows.find { |row| row.room_id.nil? }
        config = (community_row&.json_value(:config) || {}).merge(room_row&.json_value(:config) || {})
        [room_row, community_row, config]
      end

      # SQLite returns booleans as 0/1 through some Sequel paths, so normalise
      # rather than trusting the raw value (0 is truthy in Ruby).
      def to_bool(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end
    end
  end
end
