# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The control lane for DM control gestures: a private chat owns no
    # channel, so a DM to a shared bot misses the channel resolver and lands
    # here instead of being dropped. Recognizes `/role operator` (or
    # `viewer`) and `/auth <token>` as a thin, I/O-free layer over
    # {OperatorFlow}, resolving candidates via {AdminReach#requestable}.
    # Reading EVERY community is a separate, deployment-wide role handed out
    # from the dashboard, never requestable here, so a DM lane that could ask
    # for it would blur the smaller ask and the larger one.
    class ControlLane
      # A trailing community is allowed after the role, so `/role operator sample`
      # files without a round trip. %r{} delimiters, so a stray slash cannot
      # terminate the literal.
      ROLE = %r{\A\s*/?roles?\b\s*(?<role>[a-z][a-z-]*)?}i

      # Presenting a token. Anchored at the start, so a message that merely
      # mentions the word is chatter, and the token itself is taken verbatim: it
      # is case sensitive and nothing here may tidy it.
      AUTH = %r{\A\s*/?auth\b\s*(?<token>\S+)?}i

      # Liberal recognition, since a DM to the bot is already directed: a message
      # STARTING with (/)operator counts, and the intent phrases count anywhere.
      # The bare word is the alias `/role operator` replaced.
      REQUEST = %r{
        (?:
          \A\s*/?operator\b                          # starts with operator / /operator
          | \brequest\s+operator\b                   # request operator, anywhere
          | \bbe(?:come)?\s+(?:an?\s+)?operator\b     # be or become (an) operator
        )
      }ix

      # The viewer request, recognized the same liberal way and checked FIRST, so
      # a message naming both roles is read as the smaller ask rather than the
      # larger one.
      VIEWER_REQUEST = %r{
        (?:
          \A\s*/?viewer\b                              # starts with viewer
          | \brequest\s+viewer\b                       # request viewer, anywhere
          | \bbe(?:come)?\s+(?:an?\s+)?viewer\b        # be or become a viewer
        )
      }ix

      # What the reply to the old word says, so somebody typing it from memory
      # learns the name without being refused.
      ALIAS_NOTICE = "By the way, the name for this now is `/role operator`. `/operator` still works."

      # A bare answer to the "which community?" question: just a number or a slug.
      # Strict, so only a message that is nothing but an answer reads as one.
      PICK = /\A\s*[#]?([a-z0-9][a-z0-9_-]*)\s*\z/i

      # The gesture's own vocabulary, dropped before asking whether what remains
      # names a community.
      GESTURE_WORDS = %w[
        a an the to in of for my me please request role roles operator operators viewer viewers
        become be being status access read
      ].freeze

      # The client owns these two words in a private chat. `/start` is what the
      # Start button sends and how the chat comes into existence at all, and a
      # deep link puts a payload after it, so anything may follow the word.
      # `/stop` is how somebody asks a bot to leave them alone. Both are
      # answered here before any gesture of ours gets a look at them.
      WELCOME = %r{\A\s*/?start\b}i

      QUIET = %r{\A\s*/?stop\b}i

      # What this bot is, in one sentence, matching the description already
      # registered with the clients. The single place a DM says it, so the
      # welcome and the unsolicited notice cannot drift apart.
      DESCRIPTION =
        "Rubotty is a moderation, administration, utility and bridging bot that " \
        "powers a select handful of private communities."

      # Where somebody the deployment does not know goes next, named rather than
      # left to guess.
      PUBLIC_HELP =
        "There is nothing here for the general public. If you are meant to be running a " \
        "community where Rubotty is active, send `/role operator` and I will take it from " \
        "there. Otherwise, please contact that community's administrators."

      # The honest answer to the client's own "leave me alone" word: nothing was
      # shut down, and the lever that does work is the client's. {OperatorConsole}
      # says this too, so the two lanes answer /stop the same way.
      QUIET_NOTICE =
        "Nothing has been stopped. Here `/stop` is how somebody asks a bot to leave them " \
        "alone, so if you would rather not hear from me, block or mute this chat."

      # The public-information notice an unsolicited DM gets. Overridable per
      # deployment through the constructor.
      DEFAULT_NOTICE =
        "#{DESCRIPTION} No interactions are available to the general public. If you believe " \
        "you are meant to be an operator/moderator in a community where Rubotty is active, " \
        "please contact the administrators. Thank you.".freeze

      # Seconds of quiet after answering one sender. A fresh DM after the window
      # gets the notice again.
      DEFAULT_NOTICE_COOLDOWN = 3600

      # How long an unanswered "which community?" question stays open: long enough
      # to go read the list, short enough that a bare number weeks later is chatter.
      DEFAULT_ASK_TTL = 3600

      # Key namespaces on the bridge_state table, so this bookkeeping cannot
      # collide with another key.
      NOTICE_PREFIX = "dm_notice"

      ASK_PREFIX = "dm_request_ask"

      # Every dependency below is optional; missing one narrows what the lane
      # can do rather than raising, EXCEPT +operator_flow+, without which the
      # lane answers nothing at all.
      #
      # @param cooldown_store [#get_state, #put_state, nil] the +bridge_state+
      #   store; nil disables notice de-duplication and bare-number answers.
      # @param auth [AuthCommand, nil] where a presented token is redeemed. Nil
      #   leaves `/auth` declining rather than swallowing a token.
      def initialize(operator_flow:, reach: nil, notice: DEFAULT_NOTICE, cooldown_store: nil,
                     notice_cooldown: DEFAULT_NOTICE_COOLDOWN, ask_ttl: DEFAULT_ASK_TTL,
                     community_viewers: nil, auth: nil, logger: nil, reports: nil)
        @operator_flow = operator_flow
        @reach = reach || (operator_flow && AdminReach.new(operator_flow: operator_flow, logger: logger))
        @community_viewers = community_viewers
        @auth = auth
        @notice = notice
        @cooldown_store = cooldown_store
        @notice_cooldown = notice_cooldown
        @ask_ttl = ask_ttl
        @logger = logger
        # The report branch, which is the one thing here a member with no
        # standing anywhere may reach.
        @reports = reports
        @logger = logger
      end

      # A member reporting a message in the bot's own chat: /report with a
      # forwarded message, or /report with a link to one. Nil means this DM was
      # not that, and the rest of the lane answers it as before.
      REPORT = /\A\s*[\/!.]?report\b/i

      def report_reply(adapter, account, author, text, subject)
        report_dm(adapter: adapter, account: account, author: author, text: text, subject: subject)
      end

      # The report branch on its own, public because a deployment with a control
      # plane wires the operator console as its DM lane rather than this one, and
      # reporting has to stay reachable from there without the console growing a
      # reports dependency of its own or gating it behind operator standing.
      #
      # @return [String, nil] the answer, or nil when this DM is not a report
      def report_dm(adapter:, account:, author:, text:, subject: nil)
        return nil if @reports.nil? || !REPORT.match?(text.to_s)

        @reports.from_dm(adapter: adapter, account: account, author: author,
                         text: text.to_s, subject: subject)
      rescue StandardError => e
        @logger&.warn { "control lane: could not take a reported message: #{e.class}: #{e.message}" }
        "Something went wrong taking that report. Try again in a moment."
      end

      # Whether +text+ is a recognized operator-request gesture.
      def request?(text) = REQUEST.match?(text.to_s)

      # Whether +text+ is the client's own onboarding word, which every private
      # chat opens with and which therefore always deserves an answer.
      def welcome?(text) = WELCOME.match?(text.to_s)

      # Whether +text+ is the client's own "leave me alone" word.
      def quiet?(text) = QUIET.match?(text.to_s)

      # The token +text+ presents, "" for the bare command, or nil when the
      # message is not that command at all.
      def token_presented(text)
        match = AUTH.match(text.to_s)
        match && match[:token].to_s
      end

      # Whether +text+ asks to read a community, and there is somewhere to file
      # that.
      def viewer_request?(text) = !@community_viewers.nil? && VIEWER_REQUEST.match?(text.to_s)

      # The role +text+ names through the `/role` command: :operator, :viewer,
      # :none for the command with no role after it, or nil when the message is
      # not that command at all. An unknown role reads as :none, so a typo gets
      # the list rather than silence.
      def role_asked(text)
        match = ROLE.match(text.to_s)
        return nil if match.nil?

        case match[:role].to_s.downcase
        when "operator", "operators" then :operator
        when "viewer", "viewers" then :viewer
        else :none
        end
      end

      # Returns the reply, or nil to stay silent. The client's own reserved
      # words are answered first, then a recognized gesture either files the
      # request, naming the community, or asks which one; anything else gets
      # the notice, de-duplicated per sender.
      #
      # @param quoted [String, nil] the replied-to text, read only by the
      #   console; accepted here so one DM shape fits either lane
      # @return [String, nil]
      def handle_dm(adapter:, account:, author:, text:, quoted: nil, subject: nil)
        return nil if author.nil? || author.native_id.nil?

        # Before the operator flow is even consulted, and before the nil guard
        # below: reporting is for everybody, and a reporter has no operator
        # membership to resolve a community from. Putting it inside the console
        # is how it would have been gated by accident.
        report = report_reply(adapter, account, author, text, subject)
        return report unless report.nil?
        return nil if @operator_flow.nil?

        presented = token_presented(text)
        named = role_asked(text)
        if welcome?(text)
          welcome_reply(adapter, account, author)
        elsif quiet?(text)
          QUIET_NOTICE
        elsif presented
          redeem_token(adapter, account, author, presented)
        elsif named
          role_command(named, adapter, account, author, text)
        elsif viewer_request?(text)
          handle_viewer_request(adapter, account, author, text)
        elsif request?(text)
          with_alias_notice(handle_request(adapter, account, author, text))
        else
          answer = pending_answer(adapter, account, author, text)
          answer || notice_reply(adapter, account, author)
        end
      rescue StandardError => e
        @logger&.warn { "control lane: could not handle a DM request: #{e.class}: #{e.message}" }
        nil
      end

      private

      # The greeting somebody who is not set up here gets for pressing Start:
      # what the bot is, then where to go next. It never waits on the notice
      # cooldown, since silence at the first word a chat can carry is the very
      # thing that reads as a broken bot, but it does refresh the cooldown so
      # the chatter after it is not answered twice over.
      def welcome_reply(adapter, account, author)
        mark_notified(adapter, account, author)
        "Hello, and welcome. #{DESCRIPTION} #{PUBLIC_HELP}"
      end

      # `/auth <token>`. Nothing here decides anything: the decision was taken
      # when the token was minted, so this hands the presented string straight
      # to the one place that knows what it is worth.
      def redeem_token(adapter, account, author, token)
        return unavailable_auth_reply if @auth.nil?

        @auth.redeem(adapter: adapter, account: account, author: author, token: token)
      end

      def unavailable_auth_reply
        "Redeeming a token is not available on this deployment. Try `/role operator` if you are meant " \
          "to be running a community here."
      end

      # `/role <name>`. The role decides which request is filed; the community it
      # is filed in is resolved exactly the same way for both.
      def role_command(named, adapter, account, author, text)
        case named
        when :operator then handle_request(adapter, account, author, text)
        when :viewer then viewer_role(adapter, account, author, text)
        else role_help
        end
      end

      def viewer_role(adapter, account, author, text)
        return unavailable_viewer_reply if @community_viewers.nil?

        handle_viewer_request(adapter, account, author, text)
      end

      def role_help
        "Which role? `/role operator` changes things in a community. `/role viewer` reads one and " \
          "changes nothing in it. Reading every community is a separate role an administrator hands " \
          "out, and it is not something to ask for here."
      end

      def unavailable_viewer_reply
        "Asking to read a community is not available on this deployment. " \
          "Try `/role operator` if you are meant to be running one."
      end

      # Append the notice that names the command, for somebody who typed the old
      # word. Never for a reply the lane decided to stay silent on.
      def with_alias_notice(reply)
        return reply if reply.nil?

        "#{reply}\n\n#{ALIAS_NOTICE}"
      end

      # Resolve the candidates and file a viewer request, the same way an
      # operator request is resolved: one candidate files against it, several
      # ask, none is an honest dead end. An operator of the community decides it,
      # because reading that community reaches no further than they already do.
      def handle_viewer_request(adapter, account, author, text)
        candidates = candidates_for(adapter, account, author)
        return no_community_reply(:viewer) if candidates.empty?

        chosen = candidates.size == 1 ? candidates.first : named_in(candidates, text)
        chosen ||= standing_viewer(candidates, adapter, author)
        return ask_which(adapter, account, author, candidates, :viewer) if chosen.nil?

        file_viewer(chosen, adapter, account, author)
      end

      # The candidate this requester already reads or has an open viewer request
      # in, so asking again reports where that stands instead of repeating the
      # question. Nil when there are several or none.
      def standing_viewer(candidates, adapter, author)
        matches = candidates.select do |community|
          already_viewer?(community, adapter, author) || open_viewer_request?(community, adapter, author)
        end
        matches.size == 1 ? matches.first : nil
      end

      def already_viewer?(community, adapter, author)
        @community_viewers.viewer?(
          community_id: community.id, adapter: adapter,
          native_id: author.native_id, username: author.username
        )
      end

      def open_viewer_request?(community, adapter, author)
        @community_viewers.pending(community_id: community.id).any? do |request|
          request[:adapter].to_s == adapter.to_s &&
            request[:requester_native_id].to_s == author.native_id.to_s
        end
      end

      def file_viewer(community, adapter, account, author)
        result = @community_viewers.request(
          community_id: community.id, adapter: adapter,
          native_id: author.native_id, username: author.username, display: author.any_name
        )
        clear_ask(adapter, account, author)
        viewer_reply_for(result, community)
      end

      def viewer_reply_for(result, community)
        where = " of #{community.name}"

        case result.status
        when :created
          "Thanks! Your request to become a viewer#{where} is in. An operator there will review it. " \
            "A viewer reads that community and changes nothing in it."
        when :duplicate
          "You already have a pending viewer request#{where}. Hang tight; an operator will review it."
        when :already_viewer
          "You already read #{community.name}."
        else
          "I could not file that request#{where} right now."
        end
      end

      # Resolve the candidates and act: file when there is exactly one, or when
      # the gesture itself named one ("operator sample", "/operator 2"); otherwise
      # ask, and file nothing.
      def handle_request(adapter, account, author, text)
        candidates = candidates_for(adapter, account, author)
        return no_community_reply(:operator) if candidates.empty?

        chosen = candidates.size == 1 ? candidates.first : named_in(candidates, text)
        chosen ||= standing(candidates, adapter, author)
        return ask_which(adapter, account, author, candidates, :operator) if chosen.nil?

        file(chosen, adapter, account, author)
      end

      # The candidate this requester already has an open request or operator status
      # in, so asking again reports where that stands instead of repeating the
      # question. Nil when there are several or none.
      def standing(candidates, adapter, author)
        matches = candidates.select do |community|
          already_operator?(community, adapter, author) || open_request?(community, adapter, author)
        end
        matches.size == 1 ? matches.first : nil
      end

      def already_operator?(community, adapter, author)
        return true if Security::ProtectedOperators.default.owner?(
          adapter: adapter, username: author.username, native_id: author.native_id
        )

        !@operator_flow.resolve_operator(
          community_id: community.id, adapter: adapter,
          native_id: author.native_id, username: author.username
        ).nil?
      end

      def open_request?(community, adapter, author)
        @operator_flow.pending(community_id: community.id).any? do |request|
          request.adapter.to_s == adapter.to_s &&
            request.requester_native_id.to_s == author.native_id.to_s
        end
      end

      # The answer to an outstanding question, or nil: counts only while a question
      # is open, so a stray "2" is chatter and gets the notice. The role asked
      # about is remembered with the question, so the answer files the same one.
      def pending_answer(adapter, account, author, text)
        role = asked_role(adapter, account, author)
        return nil if role.nil?

        match = PICK.match(text.to_s)
        return nil if match.nil?

        candidates = candidates_for(adapter, account, author)
        chosen = pick(candidates, match[1])
        return nil if chosen.nil?

        role == :viewer ? file_viewer(chosen, adapter, account, author) : file(chosen, adapter, account, author)
      end

      # Create the request against one named community. Idempotent: a second answer
      # finds the pending row rather than filing a duplicate.
      def file(community, adapter, account, author)
        result = @operator_flow.request(
          community_id: community.id, adapter: adapter,
          native_id: author.native_id, username: author.username, display: author.any_name
        )
        clear_ask(adapter, account, author)
        reply_for(result, community)
      end

      def candidates_for(adapter, account, author)
        return [] if @reach.nil?

        @reach.requestable(
          adapter: adapter, account: account,
          native_id: author.native_id, username: author.username
        )
      end

      # The community the gesture itself named, or nil, so "/operator sample" files
      # without a round trip. The gesture words are stripped and what remains must
      # be just the community, whole; anything less certain falls through to the ask.
      def named_in(candidates, text)
        remainder = text.to_s.downcase.gsub(/[^a-z0-9_\-\s]/, " ").split - GESTURE_WORDS
        return nil if remainder.empty?

        whole = remainder.join(" ")
        by_name = candidates.find { |community| community.name.to_s.downcase == whole }
        return by_name if by_name
        return nil unless remainder.size == 1

        pick(candidates, remainder.first)
      end

      # One candidate by position or slug. The list is never stored; {AdminReach}
      # orders by slug, so the numbering matches the question's.
      def pick(candidates, token)
        return by_index(candidates, token) if token.match?(/\A\d+\z/)

        candidates.find { |community| community.slug.to_s.casecmp?(token) }
      end

      def by_index(candidates, token)
        index = token.to_i
        return nil if index < 1 || index > candidates.size

        candidates[index - 1]
      end

      def ask_which(adapter, account, author, candidates, role)
        mark_asked(adapter, account, author, role)
        lines = if role == :viewer
                  ["Which community are you asking to read?"]
                else
                  ["Which community are you requesting operator status in?"]
                end
        candidates.each_with_index do |community, index|
          lines << "  #{index + 1}. #{community.slug} (#{community.name})"
        end
        lines << ""
        lines << "Reply with the number, or the short name, and I will file it there. " \
                 "Nothing has been filed yet."
        lines.join("\n")
      end

      def reply_for(result, community)
        where = " of #{community.name}"

        case result.status
        when :created
          "Thanks! Your request to become an operator#{where} is in. A current operator will review it."
        when :duplicate
          "You already have a pending operator request#{where}. Hang tight; an operator will review it."
        when :already_operator
          "You are already an operator#{where}."
        else
          "I could not file that request#{where} right now."
        end
      end

      def no_community_reply(role)
        wanted = role == :viewer ? "read" : "request operator status in"
        "I could not find a community to #{wanted} from this chat. " \
          "If you are meant to be an operator somewhere Rubotty runs, please contact its administrators."
      end

      # The notice for an unrecognized DM, or nil when it is disabled or this
      # sender was answered inside the cooldown. Recording the send is best effort.
      def notice_reply(adapter, account, author)
        return nil if @notice.nil? || @notice.to_s.empty?
        return nil if recently_notified?(adapter, account, author)

        mark_notified(adapter, account, author)
        @notice
      end

      def recently_notified?(adapter, account, author)
        return false if @cooldown_store.nil?

        !@cooldown_store.get_state(notice_key(adapter, account, author)).nil?
      rescue StandardError
        false
      end

      def mark_notified(adapter, account, author)
        return if @cooldown_store.nil?

        @cooldown_store.put_state(
          notice_key(adapter, account, author), "1", expires_at: Time.now + @notice_cooldown
        )
      rescue StandardError => e
        @logger&.warn { "control lane: could not record a DM notice cooldown: #{e.message}" }
        nil
      end

      def notice_key(adapter, account, author)
        "#{NOTICE_PREFIX}:#{adapter}:#{account}:#{author.native_id}"
      end

      # Which role an outstanding question is about, or nil when none is open. Only
      # the role is stored; the candidate list is derived again, in the same
      # order, on the answering message.
      def asked_role(adapter, account, author)
        return nil if @cooldown_store.nil?

        stored = @cooldown_store.get_state(ask_key(adapter, account, author))
        return nil if stored.nil? || stored.empty?

        stored == "viewer" ? :viewer : :operator
      rescue StandardError
        nil
      end

      def mark_asked(adapter, account, author, role)
        return if @cooldown_store.nil?

        @cooldown_store.put_state(ask_key(adapter, account, author), role.to_s,
                                  expires_at: Time.now + @ask_ttl)
      rescue StandardError => e
        @logger&.warn { "control lane: could not record a DM community question: #{e.message}" }
        nil
      end

      def clear_ask(adapter, account, author)
        return if @cooldown_store.nil?

        # Written already expired, because the state store has no delete. A second
        # in the past, so a backend storing whole seconds cannot round it forward.
        @cooldown_store.put_state(ask_key(adapter, account, author), "", expires_at: Time.now - 1)
      rescue StandardError => e
        @logger&.warn { "control lane: could not clear a DM community question: #{e.message}" }
        nil
      end

      def ask_key(adapter, account, author)
        "#{ASK_PREFIX}:#{adapter}:#{account}:#{author.native_id}"
      end
    end
  end
end
