# frozen_string_literal: true

module Rubotty
  module Features
    # The shared command markers every command-bearing feature reads through
    # {Core::CommandPrefix.from_scope}. Observes nothing and never runs: the
    # same shape as {FileRehosting} and {TelegramAvatars}, a flag other
    # features consult directly. Replaces what used to be seven separate
    # per-feature copies of the same setting.
    class CommandMarkers < Base
      def self.feature_name = Core::CommandPrefix::CONFIG_FEATURE

      def self.description = "The markers a command may start with, shared by every command-bearing feature."

      def self.default_enabled? = true

      def self.observes = [].freeze

      def self.config_schema
        Config::Schema.define do
          field :prefixes, :array, of: :string, default: Core::CommandPrefix::DEFAULT,
                           desc: "the markers a command may start with; \"/\" and \"!\" by default"
          field :prefix, :string, desc: "legacy single command marker, folded into `prefixes`"
        end
      end
    end
  end
end
