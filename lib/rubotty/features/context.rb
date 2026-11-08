# frozen_string_literal: true

module Rubotty
  module Features
    # The immutable view of one message a feature receives. `community` and
    # `channel` are nil without a control plane; `config` is this feature's
    # resolved config, channel over community over code default.
    class Context
      attr_reader :script_requests

      attr_reader :message, :community, :channel, :config, :attachment_text

      # @param attachment_text [AttachmentText, nil] the QR/OCR extractor for
      #   +message+'s photo attachments, shared across every feature's
      #   Context for the same message so a photo is decoded and OCR'd at
      #   most once (see {Pipeline#handle}). A caller that builds one directly,
      #   a spec included, gets one scoped to just this Context instead.
      # @param operators [Core::Moderation::Directory, nil] read only where no
      #   community resolved; a resolved one answers with its own.
      # @param people [Core::Directory, nil] same, for mentionable people.
      def initialize(message:, community: nil, channel: nil, config: {}, logger: nil,
                     operators: nil, people: nil, attachment_text: nil)
        @message = message
        @community = community
        @channel = channel
        @config = config || {}
        @logger = logger
        @operators = operators
        @people = people
        @attachment_text = attachment_text || AttachmentText.new(message, logger: logger)
        # Outbound endpoint calls a script asked for, collected so nothing blocks
        # the pipeline.
        @script_requests = []
        freeze
      end

      # The operator directory in scope: the community's when one resolved, and
      # only then the one injected at construction. This order, not the other
      # one: an injected directory that outranked a resolved community would let
      # one line hand every command surface the merged deployment-wide view.
      def operators = @community&.operators || @operators

      # The mentionable-people directory in scope, same precedence and for the
      # same reason.
      def people = @community&.people || @people

      def rooms = @community&.rooms

      def logger = @logger

      # The shared command markers in scope for this message, resolved through
      # {Core::CommandPrefix.from_scope} rather than this feature's own config,
      # so every command-bearing feature reads the same community/room setting.
      def command_prefixes = Core::CommandPrefix.from_scope(@community, @channel)

      def halt(value = [], reason: nil) = Outcome.halt(value, reason: reason)

      def continue(value = []) = Outcome.continue(value)
    end
  end
end
