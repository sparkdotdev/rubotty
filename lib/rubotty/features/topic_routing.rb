# frozen_string_literal: true

module Rubotty
  module Features
    # The first of topic routing's two switches: classify, and record what was
    # found. Switching this on never moves anything, whatever it decides; that
    # takes `topic_routing_moves` as well. It only queues ordinary chat for a
    # background check, so a slow or unreachable connection never pauses the
    # bridge or changes the original message.
    class TopicRouting < Base
      def self.feature_name = ::Rubotty::SemanticAnalysis::TopicRouter::FEATURE

      def self.description
        "Checks in the background whether a message fits the room it was said in, and records the ones that fit another room better."
      end

      def self.retention_notice
        "A short excerpt of the few messages before each one is held in memory per endpoint, so " \
          "that a reply can be placed at all, and is sent with the check; it is never written " \
          "down and is lost on restart. " \
          "Message text is kept only in its pending room job while that check runs. A room with " \
          "topic_routing_moves switched on as well also keeps a repostable copy of the message " \
          "for as long as the move itself takes. A room set to announce a finding to the " \
          "operators puts a short excerpt of the message in that DM."
      end

      def self.default_enabled? = false

      def self.observes = %i[chat]

      def self.config_schema
        service = ::Rubotty::SemanticAnalysis::TopicRouter
        Config::Schema.define do
          field :subject, :string, multiline: true,
                desc: "what this room is for. Write as many clauses as it takes, separated by " \
                      "semicolons: the topics, the kinds of question, and the sites whose links " \
                      "belong here by name. For a room about property, \"Buying or selling " \
                      "property in Portugal; renting and tenancy; any links to Idealista or " \
                      "similar real estate websites\" places far more than one sentence would. " \
                      "A room with none is never classified and is never somewhere a message " \
                      "can be moved to, and neither is a room with this feature switched off, " \
                      "since leaving a room out of routing leaves it out in both directions."
          field :destination_only, :boolean, default: false,
                desc: "whether this room only ever RECEIVES. On, a message can be moved here " \
                      "but the room's own messages are never classified and so are never moved " \
                      "out, which is what a catch-all like off-topic wants: everything in it " \
                      "fits somewhere else by definition, and policing it would empty it."
          field :minimum_confidence, :float, range: 0.0..1.0, step: 0.05,
                default: service::DEFAULT_MINIMUM_CONFIDENCE,
                desc: "how well another room has to fit before that counts as a finding"
          field :confidence_margin, :float, range: 0.0..1.0, step: 0.05,
                default: service::DEFAULT_CONFIDENCE_MARGIN,
                desc: "how far another room has to beat this one by, on top of minimum_confidence, " \
                      "so two rooms described alike settle nothing"
          field :context_messages, :integer, default: service::DEFAULT_CONTEXT_MESSAGES,
                desc: "how many of the messages before it are sent along, so a short or " \
                      "referring message can be placed at all. A reply also carries what it " \
                      "was answering. 0 sends the message alone. Capped at " \
                      "#{service::MAX_CONTEXT_MESSAGES}."
          field :min_characters, :integer, default: service::DEFAULT_MIN_CHARACTERS,
                desc: "shortest message worth checking. Below this a message carries too little " \
                      "to place it, and short messages are most of a busy room."
          field :max_characters, :integer, default: service::DEFAULT_MAX_CHARACTERS,
                desc: "how much of a long message is sent for the check, which bounds what one " \
                      "check costs"
          field :cooldown_seconds, :integer, default: service::DEFAULT_COOLDOWN_SECONDS,
                desc: "shortest gap between two checks in this room, which is what bounds how " \
                      "much a busy room costs. 0 checks every eligible message."
          field :sample_percent, :integer, default: service::DEFAULT_SAMPLE_PERCENT,
                desc: "share of otherwise eligible messages to check, 1 to 100"
          field :announce_findings, :string, default: service::DEFAULT_ANNOUNCE,
                one_of: service::ANNOUNCE_MODES,
                desc: "where a finding goes when nothing was moved. room posts a self-deleting " \
                      "notice in the room the message was said in, operators DMs this community's " \
                      "operators a short excerpt, and off leaves the audit log as the only trace. " \
                      "Every finding is recorded whichever of the three this is."
          field Core::RemovalNotice::TTL_FIELD, :integer, default: Core::RemovalNotice::DEFAULT_TTL_SECONDS,
                desc: "seconds an in-room finding notice lives before it self-deletes. 0 leaves it up."
        end
      end

      def initialize(logger:, service: nil)
        @logger = logger
        @service = service
      end

      attr_reader :logger

      def call(context)
        @service&.enqueue(context)
        Outcome.continue([])
      rescue StandardError => e
        logger.warn { "topic routing: could not queue room work: #{e.class}" }
        Outcome.continue([])
      end
    end
  end
end
