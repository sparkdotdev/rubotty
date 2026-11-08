# frozen_string_literal: true

module Rubotty
  module Features
    # Declaration only, in the same shape as {StartupBanner}: the operator DM
    # is sent at boot by Core::Runtime and #call never runs. Orthogonal to
    # {StartupBanner} rather than a variant of it: either can be on without
    # the other, and a community running both gets a room banner and an
    # operator DM from the same restart.
    class OperatorStartupDm < Base
      def self.feature_name = "operator_startup_dm"

      def self.description =
        "DMs every operator of the community the same version and build banner the room copy shows, " \
        "each time the bot starts, ephemeral like the room banner but longer lived. Independent of " \
        "startup_banner: turn either on alone, or both together."

      # Off, for the same reason {StartupBanner.default_enabled?} is: a
      # restart is the operator's own business, and a deploy that takes
      # several attempts should not DM the same people every time.
      def self.default_enabled? = false
    end
  end
end
