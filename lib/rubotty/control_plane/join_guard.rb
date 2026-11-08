# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Decides whether the bot stays in or leaves a space it finds itself in,
    # based on the membership event the adapter reports; the adapter carries
    # the decision out. The bot stays when a +platform_connections+ row maps
    # the space to a community (a stopped community still counts), when the
    # title is on the deployment-configured {ProtectedCommunities} whitelist, or when an
    # onboarding is in progress; otherwise it posts a notice and leaves. A
    # whitelisted title with no mapped community still asks for review, since
    # the whitelist only says the bot may not leave, not who it belongs to.
    class JoinGuard
      # The public notice posted in an unauthorized space just before leaving.
      DEFAULT_NOTICE =
        "This is a private bot and is not set up for this community, so it is leaving. " \
        "If you believe this is a mistake, please contact the bot's operator."

      # The fallback notice for a space the bot could NOT leave: no self-removal
      # permission, or the leave call itself failed. Posted at most once per space
      # (see {#record_leave_failure}); {PendingSpaces::INERT_NOTICE} aliases it.
      INERT_NOTICE =
        "This is a private bot and is not set up for this community. It will remain inert " \
        "and will not respond to any interactions. Please remove it from your server at " \
        "your earliest convenience. If you believe this is a mistake, please contact the " \
        "bot's operator."

      # The outcome of evaluating one membership event. +review+ is its own axis
      # alongside the stay/leave action, because a space can owe an operator a
      # decision while still being one the bot may never walk out of.
      Decision = Struct.new(:action, :community, :notice, :signal, :review, keyword_init: true) do
        def leave? = action == :leave

        def stay? = action == :stay

        # Whether this space still owes an operator a decision.
        def review? = review ? true : false
      end

      # @param authorization [AuthorizationDirectory] the authorized-spaces read
      # @param onboarding [#in_progress?, nil] the onboarding-in-progress signal
      #   ({OnboardingRegistry}); nil means "never in onboarding", so an unmapped
      #   space is left at once
      # @param notice [String] the departure notice for an unauthorized space
      # @param inert_notices [InertNotices, nil] the "cannot leave" once-only
      #   tracker; a fresh in-process one when not given
      # @param logger [#info, nil]
      def initialize(authorization:, onboarding: nil, notice: DEFAULT_NOTICE, inert_notices: nil, logger: nil)
        @authorization = authorization
        @onboarding = onboarding
        @notice = notice
        @inert_notices = inert_notices || InertNotices.new
        @logger = logger
      end

      # Evaluate a membership event and decide stay or leave.
      #
      # @param title [String, nil] the space title carried by the membership event
      #   (the Telegram my_chat_member chat title); a title on the deployment-configured
      #   {ProtectedCommunities} whitelist forces STAY regardless of DB state, and
      #   asks for a review when no row maps the space
      # @return [Decision]
      def on_join(adapter:, account:, external_id:, title: nil, inviter: nil, channel_sample: [])
        signal = SpaceJoinSignal.new(adapter: adapter, account: account, external_id: external_id,
                                     title: title, inviter: inviter, channel_sample: channel_sample)
        decision = decide(adapter: adapter, account: account, external_id: external_id, title: title)
        decision.signal = signal
        decision
      end

      # Whether the caller should post {INERT_NOTICE} for a space the bot just
      # failed to leave: true the first time this space is reported stuck, false
      # on every later call, however often the leave keeps failing.
      #
      # @return [Boolean]
      def record_leave_failure(adapter:, account:, external_id:)
        already = @inert_notices.posted?(adapter: adapter, account: account, external_id: external_id)
        @inert_notices.mark_posted!(adapter: adapter, account: account, external_id: external_id) unless already
        !already
      end

      private

      def decide(adapter:, account:, external_id:, title:)
        if @authorization.mapped?(adapter: adapter, account: account, external_id: external_id)
          community = @authorization.community_for(adapter: adapter, account: account, external_id: external_id)
          @logger&.info { "staying in authorized #{adapter} space #{external_id} (community #{community&.slug})" }
          return Decision.new(action: :stay, community: community)
        end

        # Being added IS the reviewable event, and a quiet room is the one nobody notices is missing.
        if @authorization.protected_title?(title)
          @logger&.info { "staying in protected #{adapter} space #{external_id}, and sending it for review" }
          return Decision.new(action: :stay, review: true)
        end

        if onboarding_in_progress?(adapter, account, external_id)
          @logger&.info { "staying in #{adapter} space #{external_id}: onboarding in progress" }
          return Decision.new(action: :stay)
        end

        @logger&.info { "leaving unauthorized #{adapter} space #{external_id}" }
        Decision.new(action: :leave, notice: @notice)
      end

      def onboarding_in_progress?(adapter, account, external_id)
        return false if @onboarding.nil?

        @onboarding.in_progress?(adapter: adapter, account: account, external_id: external_id)
      end
    end
  end
end
