# frozen_string_literal: true

module Rubotty
  module Features
    # Whether a community's dashboard exposes creating and deleting
    # meta-channels. Observes no message kind, so the pipeline never runs it.
    # Read at the community-wide scope (`selector: "all"`) only.
    class ChannelManagement < Base
      def self.feature_name = "channel_management"

      def self.description = "Create and delete meta-channels for this community from the dashboard."

      # A fresh community shows no create/delete room controls until this is on.
      def self.default_enabled? = false

      def self.observes = [].freeze

      def self.config_schema = nil
    end
  end
end
