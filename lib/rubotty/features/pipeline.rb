# frozen_string_literal: true

module Rubotty
  module Features
    # The chain that runs the enabled features, in order, for one inbound message.
    # The loop guard's echo check runs once ahead of any feature, and a feature that
    # halts stops the chain.
    #
    # The return value is the value of the last feature that ran, or an empty array
    # when nothing ran or an echo was dropped.
    class Pipeline
      # @param features [Array<Features::Base>] in run order
      # @param loop_guard [Core::LoopGuard, nil] the pre-pipeline echo gate
      # @param registry [ControlPlane::Registry, nil] source of the live Snapshot
      #   for scope resolution; nil runs features by their static default
      # @param identity_recorder [ControlPlane::IdentityRecorder, nil] the
      #   passive identity recorder; nil makes it a no-op
      # @param operators [Core::Moderation::Directory, nil] the directory for a
      #   deployment with NO control plane; alongside a registry it raises
      def initialize(features:, loop_guard: nil, logger: nil, registry: nil, identity_recorder: nil,
                     operators: nil, content_policy_observer: nil)
        raise ArgumentError, "a control plane scopes operators per community; pass none here" if
          registry && operators

        @features = features.freeze
        @loop_guard = loop_guard
        @logger = logger
        @registry = registry
        @identity_recorder = identity_recorder
        @content_policy_observer = content_policy_observer
        @operators = operators
      end

      attr_reader :features

      # Run one inbound message through the chain.
      #
      # @param message [Core::Message]
      # @return [Array] the last feature's produced value, or []
      def handle(message)
        reason = @loop_guard&.echo?(message)
        if reason
          @logger&.debug { "dropped #{message.ref} as echo (#{reason})" }
          return []
        end

        community, channel = resolve_scope(message)

        # On the spine rather than in a feature, so the directory is built for every
        # message that resolves to a community whatever features are on.
        @identity_recorder&.record(message, community)
        @content_policy_observer&.observe(message, community)

        # Built once per message and threaded through every feature's Context
        # below, so a photo attachment's QR decode and OCR pass run at most
        # once no matter how many features ask for the result.
        attachment_text = AttachmentText.new(message, logger: @logger)

        result = []
        @features.each do |feature|
          next unless feature.class.observes.include?(message.kind)
          next unless enabled?(feature, community, channel)

          outcome = call_feature(feature, message, community, channel, attachment_text)
          result = outcome.value
          break if outcome.halt?
        end
        result
      end

      private

      def call_feature(feature, message, community, channel, attachment_text)
        feature.call(context_for(feature, message, community, channel, attachment_text))
      rescue StandardError => error
        @logger&.error do
          "feature #{feature.class.feature_name} failed for #{message.ref}: #{error.class}"
        end
        if feature.class.failure_policy == :continue
          Outcome.continue
        else
          Outcome.halt([])
        end
      end

      # Reads the Snapshot once so community and channel come from one consistent
      # view even if a reload swaps the reference mid-flight.
      def resolve_scope(message)
        return [nil, nil] if @registry.nil?

        snapshot = @registry.current
        channel = snapshot.channel_by_endpoint_key(message.origin.id)
        return [nil, nil] if channel.nil?

        [snapshot.community_by_id(channel.community_id), channel]
      end

      # Channel row over community default over code default when a control plane
      # resolved the scope; otherwise the feature's static default.
      def enabled?(feature, community, channel)
        return true if feature.class.always_enabled?
        return feature.class.default_enabled? if community.nil?

        community.feature_enabled?(channel, feature.class.feature_name)
      end

      def context_for(feature, message, community, channel, attachment_text)
        config = community ? community.feature_config(channel, feature.class.feature_name) : {}
        Context.new(
          message: message, community: community, channel: channel, config: config,
          logger: @logger, attachment_text: attachment_text, operators: @operators
        )
      end
    end
  end
end
