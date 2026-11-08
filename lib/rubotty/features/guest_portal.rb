# frozen_string_literal: true

module Rubotty
  module Features
    # Room-scoped feature flag and config for the guest portal; {ControlPlane::GuestInvites}
    # refuses invites where it is off. The flag is read live, but the guest endpoint only
    # joins a room when the router builds topology at bot start, so enabling it needs a
    # bot restart before the endpoint actually routes.
    class GuestPortal < Base
      # Operators always may issue where guests are allowed; "everyone"
      # additionally lets a normal member issue one.
      WHO_OPERATORS = "operators"
      WHO_EVERYONE = "everyone"
      WHO_CAN_INVITE = [WHO_OPERATORS, WHO_EVERYONE].freeze

      def self.feature_name = "guest_portal"

      def self.description =
        "Lets an operator, or any member when who_can_invite is set to everyone, issue a " \
        "time-limited guest link into a room."

      # A fresh community accepts no guests until an operator enables a room.
      def self.default_enabled? = false

      def self.observes = [].freeze

      def self.config_schema
        Config::Schema.define do
          field :who_can_invite, :string, default: WHO_OPERATORS, one_of: WHO_CAN_INVITE,
                desc: "who may issue a guest invite for this room: operators (default) or everyone"
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                                                       desc: "seconds a /guest reply lives before it " \
                                                             "self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the /guest invocation itself is removed together with its reply"
        end
      end
    end
  end
end
