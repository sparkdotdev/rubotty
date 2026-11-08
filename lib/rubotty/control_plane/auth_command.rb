# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The `/auth <token>` DM: grants whatever the token carries and replies with
    # a single-use dashboard sign-in link, since the token was put in front of
    # somebody in a chat message rather than fetched by the operator who asked
    # for it. One implementation behind both DM surfaces, so it answers the same
    # way whether the sender already holds a role or holds none at all (the
    # ordinary case). The dashboard redeems only on a POST from its confirmation
    # page, never the GET the link itself is, so a platform's link preview
    # cannot spend it.
    class AuthCommand
      # What the reply says when the command arrives with nothing after it.
      HELP = "Send `/auth` and then the token you were given, like `/auth abcd1234`."

      # What too many presentations in a row get. Deliberately says nothing
      # about whether any of them was close.
      THROTTLED = "That is a lot of tokens in a short while. Wait a few minutes, then send the one " \
                  "you were given again."

      # @param tokens [AuthTokens] the credential store
      # @param web_login [WebLoginTokens, nil] where the sign-in link comes
      #   from. Nil leaves the reply without one, which is what a deployment
      #   with no state store can honestly offer.
      # @param reach [AdminReach, nil] the shared DM community resolution, so
      #   the link is scoped to exactly what the sender now holds
      def initialize(tokens:, web_login: nil, reach: nil, viewers: nil, administrators: nil,
                     community_viewers: nil, dashboard_url: nil, logger: nil)
        @tokens = tokens
        @web_login = web_login
        @reach = reach
        @viewers = viewers
        @administrators = administrators
        @community_viewers = community_viewers
        @dashboard_url = dashboard_url
        @logger = logger
      end

      # Redeem a presented token for the DM's sender.
      #
      # @param adapter [Symbol, String] the platform the DM arrived on
      # @param account [String] the credential it arrived on
      # @param author [Core::Author, nil] who sent it
      # @param token [String, nil] the raw string they typed
      # @return [String] the reply text
      def redeem(adapter:, account:, author:, token:)
        return HELP if presence(token).nil?
        return AuthTokens::REFUSAL if author.nil? || author.native_id.nil?

        result = @tokens.redeem(
          token: token, adapter: adapter, native_id: author.native_id,
          username: author.username, display: author.any_name
        )
        case result.status
        when :ok then welcome(result.granted, adapter, account, author)
        when :rate_limited then THROTTLED
        else AuthTokens::REFUSAL
        end
      rescue StandardError => e
        @logger&.warn { "auth command: could not redeem a token: #{e.class}: #{e.message}" }
        AuthTokens::REFUSAL
      end

      private

      # The whole successful reply: what was just handed over, anything that
      # could not be, and the sign-in link.
      def welcome(granted, adapter, account, author)
        lines = [granted_sentence(granted)]
        lines.concat(Array(granted&.problems))
        link = login_line(adapter, account, author)
        lines << link unless link.nil?
        lines.join("\n")
      end

      def granted_sentence(granted)
        parts = []
        parts << "you now operate #{granted.operated.slug}" if granted&.operated
        # Only when they do not also operate it: an operator already reads their
        # own community, and saying both would read as two separate grants.
        parts << "you now read #{granted.viewed.slug}" if granted&.viewed && granted.operated.nil?
        parts << "you now read every community, and change nothing anywhere" if granted&.deployment_viewer
        parts << "you now administer this deployment" if granted&.administrator
        return "That token has been used up, and it turned out to grant nothing new." if parts.empty?

        "Done: #{parts.join(", and ")}."
      end

      # The sign-in link, scoped to everything the sender holds after the grants
      # above, not just what this token added: one link, one session, the whole
      # standing.
      def login_line(adapter, account, author)
        return nil if @web_login.nil?

        communities, viewer, viewed, administrator = standing(adapter, author)
        outcome = @web_login.issue(
          identity_key: "#{adapter}:#{account}:#{author.native_id}",
          operator: {
            adapter: adapter.to_s, account: account.to_s, native_id: author.native_id.to_s,
            # The handle the rosters are keyed on, so the dashboard can ask them
            # again when the link is redeemed rather than trust what it carries.
            username: presence(author.username),
            label: presence(author.any_name) || "token holder"
          },
          communities: communities, viewer: viewer, viewer_communities: viewed,
          administrator: administrator, single_use: true
        )
        case outcome.status
        when :issued then issued_line(outcome)
        when :rate_limited
          "You already have a sign-in link outstanding. Use that one, or wait for it to expire and " \
            "send `web-login`."
        end
      end

      def issued_line(outcome)
        "Sign in to the dashboard: #{login_url(outcome.token)}\n" \
          "It asks you to confirm, then works once and stops working in about " \
          "#{minutes_until(outcome.expires_at)}. Keep it to yourself: anybody who has it signs in as you."
      end

      # What the sender holds now: the communities they operate, whether they
      # read the whole deployment, the communities they read without operating
      # them, and whether they administer the deployment.
      def standing(adapter, author)
        memberships = operated(adapter, author)
        communities = memberships.map do |membership|
          { id: membership.community.id, slug: membership.community.slug, name: membership.community.name }
        end
        viewer = @viewers&.viewer?(adapter: adapter, username: author.username,
                                   native_id: author.native_id) || false
        administrator = @administrators&.administrator?(adapter: adapter, username: author.username,
                                                        native_id: author.native_id) || false
        viewed = viewed_ids(adapter, author) - communities.map { |entry| entry[:id] }
        [communities, viewer, viewed, administrator]
      end

      def operated(adapter, author)
        return [] if @reach.nil?

        @reach.operated(adapter: adapter, native_id: author.native_id, username: author.username)
      end

      def viewed_ids(adapter, author)
        return [] if @community_viewers.nil?

        @community_viewers.communities_for(
          adapter: adapter, username: author.username, native_id: author.native_id
        )
      end

      def login_url(token)
        base = presence(@dashboard_url).to_s.sub(%r{/+\z}, "")
        "#{base}/operator-login?token=#{token}"
      end

      def minutes_until(time)
        minutes = ((time - Time.now) / 60.0).round
        minutes = 1 if minutes < 1
        "#{minutes} minute#{minutes == 1 ? "" : "s"}"
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
