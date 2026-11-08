# frozen_string_literal: true

module Rubotty
  module Features
    # Declaration only, in the same shape as {Backfill}: the banner is posted at
    # boot by Core::Runtime and #call never runs. Registering it here is what
    # gives an operator the per-community toggle, and what makes the default
    # visible somewhere other than an if statement in the runtime.
    class StartupBanner < Base
      def self.feature_name = "startup_banner"

      def self.description =
        "Posts the version and build banner into the community's announce room every time the bot starts. " \
        "Worth having on while a deployment is being worked on, and pure noise in a community that is " \
        "just talking to each other."

      # Off: a restart is the operator's business rather than the room's, and a
      # deploy needing several attempts would announce itself every time. Spelled
      # out despite {Base.default_enabled?} already saying false, since this is
      # the whole point of the feature.
      def self.default_enabled? = false
    end
  end
end
