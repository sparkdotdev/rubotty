# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Notices an edit to the community_scripts table between control-plane
    # watcher ticks and reruns +sync+, since
    # {Core::Runtime#sync_recurring_scripts} otherwise only ran once, at
    # boot: a clock trigger added, changed or removed from the dashboard
    # while the bot kept running never got a durable wake until the whole
    # process restarted.
    class ScriptRecurrenceWatch < TableWatch
      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param sync [#call] rebuilds every recurring wake from the live table
      # @param logger [#warn, nil]
      def initialize(models:, sync:, logger: nil)
        super(models: models, sync: sync, table: :community_scripts, logger: logger)
      end
    end
  end
end
