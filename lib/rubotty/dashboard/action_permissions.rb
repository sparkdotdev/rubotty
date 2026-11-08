# frozen_string_literal: true

module Rubotty
  module Dashboard
    # What an operator is allowed to CHANGE, per action, from the database. The
    # read half is scoped separately, see {Role::GLOBAL_READ_ACTIONS}. Toggling a
    # feature and editing it are separate grants: an edit can quietly disarm it.
    class ActionPermissions
      # The parts of the dashboard that are not a feature: whole sections an
      # operator either administers or does not.
      SECTION_ACTIONS = {
        moderate_user: "Moderate people (warn, mute, ban)",
        manage_rooms: "Rooms: create and delete",
        manage_discovered: "Rooms: map, approve and reject",
        manage_operator_requests: "Operator requests: approve and reject",
        # Separate from moderate_user, since stopping a move in flight sanctions nobody.
        manage_redirection: "Redirection: stop a move that is still running",
        # Gated because clearing an alert hides work from the next operator to look.
        manage_alerts: "Alerts: mark them as seen",
        # Gated because resending a dead-lettered delivery means a third party receives it.
        manage_webhooks: "Webhooks: send a failed delivery again",
        # Gated because closing a session ends it for everybody in the room mid-game.
        manage_participation: "Room games: close a session that is stuck"
      }.freeze

      # Two grants per feature, in catalog order.
      def self.feature_actions
        Features::Catalog.names.each_with_object({}) do |name, out|
          label = name.tr("_", " ")
          out[:"toggle_#{name}"] = "Turn #{label} on and off"
          out[:"configure_#{name}"] = "Edit what #{label} does"
        end
      end

      # Every grant, as action => label, computed once at load.
      ACTIONS = feature_actions.merge(SECTION_ACTIONS).freeze

      def initialize(models:)
        @models = models
      end

      def operator_write_actions
        rows.select { |row| row[:operator_writable] }.map { |row| row[:action] }
      end

      # Every grant with its current state. An action nobody has decided on
      # reads as denied.
      def rows
        stored = @models.dashboard_action_permission.all.each_with_object({}) do |row, map|
          map[row.action.to_sym] = row.operator_writable
        end
        ACTIONS.map do |action, label|
          {
            action: action,
            label: label,
            group: SECTION_ACTIONS.key?(action) ? "Sections" : "Features",
            operator_writable: stored.fetch(action, Role::DEFAULT_WRITE_ACTIONS.include?(action))
          }
        end
      end

      # The same rows, split into section grants and per-feature grants.
      def grouped_rows = rows.group_by { |row| row[:group] }

      def update(values)
        now = Time.now
        ACTIONS.each_key do |action|
          writable = values.key?(action.to_s) || values.key?(action)
          row = @models.dashboard_action_permission.where(action: action.to_s).first
          if row
            row.update(operator_writable: writable, updated_at: now)
          else
            @models.dashboard_action_permission.create(
              action: action.to_s, operator_writable: writable, created_at: now, updated_at: now
            )
          end
        end
      end
    end
  end
end
