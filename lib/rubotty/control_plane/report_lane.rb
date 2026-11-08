# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The DM half of reporting: /report with a message forwarded to the bot, or
    # /report with a link to one. Sits outside every operator check, because a
    # reporter has no standing anywhere and that is the point. Which community
    # a report is about is the question the console never had to answer, since
    # it reads that off the sender's memberships: a link resolves on its own, a
    # forward that kept its origin resolves the same way, and one that lost it
    # falls back to the single community the reporter is known in, since
    # offering a list would be telling them which communities exist here.
    class ReportLane
      # What a DM report is about, built by the adapter that read the DM. Not a
      # {Core::Message}: a private chat has no endpoint, so there is no origin
      # to give one, and this carries only what a report actually needs.
      Subject = Struct.new(:author, :target, :body, :adapter, :reporter_native_id, keyword_init: true)

      NOTHING_NAMED = "Forward me the message, or paste a link to it, and put /report with it."
      NOWHERE_KNOWN = "I could not tell which community that message is in. Paste a link to it instead."
      RATE_LIMITED = "You have reported several messages recently, so this one was not passed on. Try later."
      TAKEN = "Thank you. The operators have been told"

      # @param reports [MemberReports] the store
      # @param registry [#current] the live snapshot, for resolving an endpoint
      # @param notifier [#notify_operators!] where a report reaches the operators
      # @param identities [IdentityDirectory, nil] what the reporter is known to
      #   be a member of, for a forward that named nothing
      def initialize(reports:, registry:, notifier: nil, identities: nil, logger: nil)
        @reports = reports
        @registry = registry
        @notifier = notifier
        @identities = identities
        @logger = logger
      end

      # @return [String, nil] the reply to send back, or nil to stay quiet
      def from_dm(adapter:, account:, author:, text:, subject: nil)
        target = target_of(text, subject)
        return NOTHING_NAMED if target.nil?

        community = target[:community]
        return NOWHERE_KNOWN if community.nil?

        file(adapter, author, community, target, subject)
      end

      private

      # A link first, since it names one message exactly. Then a forward that
      # kept its origin. A forward that lost it is evidence rather than a
      # handle: the words are kept and the operators can go looking, but nothing
      # here can offer to delete it.
      def target_of(text, subject)
        from_link(text) || from_forward(subject)
      end

      def from_link(text)
        link = text.to_s[%r{https?://\S+}]
        return nil if link.nil?

        parsed = Core::Permalink.parse(link)
        return nil if parsed.nil?

        located = locate(parsed)
        return nil if located.nil?

        { community: located[:community], endpoint_id: located[:endpoint].id,
          native_id: parsed.native_id, route: "link", author: nil, body: nil }
      end

      # The endpoint a parsed link names, searched across every community, since
      # a link carries no tenant of its own.
      def locate(parsed)
        snapshot = @registry&.current
        return nil if snapshot.nil?

        snapshot.communities.each do |community|
          community.rooms.each do |room|
            endpoint = Core::Permalink.endpoint_for(parsed, room.endpoints)
            return { community: community, endpoint: endpoint } if endpoint
          end
        end
        nil
      end

      # A forward. Where it kept its origin, that origin resolves to an endpoint
      # exactly as a pasted link does, through the same matcher. Where it did
      # not, the words are still worth delivering: an operator can read them and
      # go looking, and the report simply names no message to act on.
      def from_forward(subject)
        return nil if subject.nil? || subject.author.nil?

        located = subject.target && locate(subject.target)
        {
          community: located ? located[:community] : sole_membership(subject),
          endpoint_id: located && located[:endpoint].id,
          native_id: located && subject.target.native_id,
          route: "forward",
          author: { native_id: subject.author.native_id, display: subject.author.any_name },
          body: subject.body
        }
      end

      # The one community this reporter is a known member of. Exactly one, or
      # nothing: asking them to pick from a list would be telling somebody with
      # no standing which communities exist here.
      def sole_membership(subject)
        return nil if @identities.nil? || subject.reporter_native_id.nil?

        snapshot = @registry&.current
        return nil if snapshot.nil?

        seen = snapshot.communities.select do |community|
          !@identities.entry(community_id: community.id, adapter: subject.adapter.to_s,
                             native_id: subject.reporter_native_id.to_s).nil?
        end
        seen.length == 1 ? seen.first : nil
      rescue StandardError
        nil
      end

      def file(adapter, author, community, target, subject)
        filed = @reports.file(
          community_id: community.id, route: target[:route],
          reporter: { adapter: adapter, native_id: author.native_id, display: author.any_name },
          endpoint_id: target[:endpoint_id], native_id: target[:native_id],
          author: target[:author], body: target[:body] || subject&.body
        )
        return RATE_LIMITED if filed.rate_limited?

        notified = alert(community, filed)
        @reports.acknowledged!(filed.row) if filed.row
        return "I could not save that report. Try again in a moment." if filed.row.nil?
        return "Thank you. Your report has been added to #{filed.row.code}." unless filed.first?
        return "#{TAKEN}, and your report is #{filed.row.code}." if notified

        "Your report is saved as #{filed.row.code}, but I could not notify the operators."
      end

      def alert(community, filed)
        return false if @notifier.nil? || !filed.first? || filed.row.nil?

        delivery = @notifier.notify_operators!(community_id: community.id, text: alert_text(community, filed.row))
        delivery.respond_to?(:none?) && !delivery.none?
      rescue StandardError => e
        @logger&.warn { "report lane: could not tell the operators: #{e.message}" }
        false
      end

      def alert_text(community, row)
        where = row.native_id.nil? ? "forwarded with no link back to it" : "reported by link or forward"
        [
          "#{community.name}: #{row.reporter_display || "a member"} reported a message " \
            "from #{row.author_display || "somebody"} (#{row.code}, #{where}).",
          quoted(row.body)
        ].compact.join(" ")
      end

      QUOTE_CHARS = 300

      def quoted(body)
        text = body.to_s.strip
        return nil if text.empty?

        text = "#{text[0, QUOTE_CHARS]}…" if text.length > QUOTE_CHARS
        "It said: \"#{text}\""
      end
    end
  end
end
