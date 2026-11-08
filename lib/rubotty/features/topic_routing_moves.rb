# frozen_string_literal: true

module Rubotty
  module Features
    # The second of topic routing's two switches, and the one that acts. With
    # `topic_routing` on and this off, a finding is written to the audit log
    # and nothing else happens, which is how a room is meant to be watched
    # before anybody trusts it. Observes nothing: the routing service reads
    # this itself rather than through the pipeline.
    class TopicRoutingMoves < Base
      def self.feature_name = ::Rubotty::SemanticAnalysis::TopicRouter::MOVE_FEATURE

      def self.description
        "Lets topic_routing act: a message that fits another room better is reposted there and removed here."
      end

      def self.retention_notice
        "Switching this on for a room makes rubotty keep a repostable copy of a message it is " \
          "about to move, for as long as the move takes, in the same place a manual redirect " \
          "keeps one. The copy goes as soon as the move finishes. Every move is written to the " \
          "audit log naming the message, both rooms and the author, and the author is told in " \
          "the room the message left. In confirm mode the copy is kept longer: a proposal holds " \
          "the message text while it waits for an operator, and once answered it stays as a " \
          "training sample for the retention below, measured from the message's own date."
      end

      def self.default_enabled? = false

      def self.observes = [].freeze

      def self.config_schema
        service = ::Rubotty::SemanticAnalysis::TopicRouter
        proposals = ::Rubotty::ControlPlane::TopicMoveProposals
        Config::Schema.define do
          field :notify_author, :boolean, default: true,
                desc: "whether the author is told, in the room the message left, where it went"
          field :mode, :string, default: service::DEFAULT_MOVE_MODE, one_of: service::MOVE_MODES,
                desc: "act moves a message straight away. confirm describes the move to this " \
                      "community's operators instead and makes it only when one answers " \
                      "/approve, which is how a room is trained before anybody trusts it to " \
                      "act alone. Either way the finding is recorded."
          field :confirm_within_hours, :integer, default: proposals::DEFAULT_PENDING_HOURS,
                desc: "hours an unanswered proposal stays actionable before it lapses, so " \
                      "approving can never repost a message the room has moved on from. " \
                      "Capped at #{proposals::MAX_PENDING_HOURS}." do |value|
                  "must be a positive number of hours" unless value.to_i.positive?
                end
          field :training_retention_days, :integer, default: proposals::DEFAULT_WINDOW_DAYS,
                desc: "days an answered proposal is kept as a training sample, measured from " \
                      "the message's own date rather than the answer's. Capped at " \
                      "#{proposals::MAX_WINDOW_DAYS}." do |value|
                  "must be a positive number of days" unless value.to_i.positive?
                end
        end
      end
    end
  end
end
