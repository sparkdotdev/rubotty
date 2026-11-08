# frozen_string_literal: true

module Rubotty
  module ContentPolicy
    # Reversing one content policy action, named back by the code its alert
    # carried. {ControlPlane::OperatorConsole} takes `/vindicate <code> <why>`
    # in a DM and hands the code here; this puts back whatever the action
    # took away. A removed message is reposted everywhere it was removed
    # from, a flag's reaction comes off, and the author is told a human
    # disagreed with the call. Every step is best effort and none of them
    # gives the claim back, so a platform refusing one leaves the others
    # done rather than losing the whole reversal.
    class Vindication
      include Features::AdapterLookup

      AUDIT_SOURCE = "content_policy"
      AUDIT_ACTION = "vindicate"

      # The names the two posts go out under, distinct from the check's own
      # notices so a sweep can tell a restoration from the removal it undoes.
      RESTORE_NAME = "content policy restore"
      NOTICE_NAME = "content policy vindication"

      # Ten minutes for the in-room notice an unreachable author gets: long
      # enough that somebody who was away when it landed still reads it, short
      # enough that the room is not left carrying it.
      NOTICE_TTL = 600

      # What the console says back. `status` is :unknown for a code that
      # resolves to nothing, :already when somebody got there first, :reversed
      # once the claim is ours, and :failed when the reversal broke. The last
      # two were one answer until a crash spent an afternoon reading as a code
      # that had never existed.
      # `removed` says whether the action had taken the message down at all,
      # which is what tells a failed restore apart from a flag that never
      # removed anything and so had nothing to put back.
      Outcome = Struct.new(:status, :action, :author, :policy, :restored, :removed, :told_author,
                           :silent, keyword_init: true)

      # @param actions [ControlPlane::ContentPolicyActions, nil] the record store,
      #   nil without a control plane, which leaves the console command inert
      # @param misfires [ControlPlane::ContentPolicyMisfires, nil] where a reversed
      #   action is kept as a sample the policy's description gets rewritten against
      # @param registry [ControlPlane::Registry, nil] where the routing view of a
      #   community is read from, since the console hands in its control-plane row
      def initialize(adapters:, ephemeral:, actions: nil, misfires: nil, moderation: nil,
                     warnings_store: nil, reposts: nil, audit: nil, cleanup: nil, logger: nil,
                     registry: nil)
        @adapters = adapters
        @ephemeral = ephemeral
        @registry = registry
        @actions = actions
        @misfires = misfires
        @moderation = moderation
        @warnings_store = warnings_store
        @reposts = reposts
        @audit = audit || Core::AuditLog::Null.new
        @cleanup = cleanup
        @logger = logger
      end

      attr_reader :logger

      def available? = !@actions.nil?

      # The actions still open to reversal, for the console to list when an
      # operator asks to vindicate without naming one.
      def recent(community_id:)
        @actions&.recent(community_id: community_id) || []
      rescue StandardError => e
        logger&.warn { "content policy: could not list open actions: #{e.message}" }
        []
      end

      # Whether +code+ names an action in this community at all. Answers the
      # console's question of which community a reply to an alert is about,
      # since a code is unique per community rather than across them.
      def holds?(community_id:, code:)
        !@actions&.find(community_id: community_id, code: code).nil?
      rescue StandardError => e
        logger&.warn { "content policy: could not look up #{code}: #{e.message}" }
        false
      end

      # Reverse the action +code+ names inside +community+.
      #
      # @param operator [String] how the operator is named in the audit trail
      # @param statement [String, nil] the operator's own words, shown to the author
      # @return [Outcome]
      def vindicate(community:, code:, operator:, statement: nil)
        record = @actions&.find(community_id: community.id, code: code)
        return Outcome.new(status: :unknown) if record.nil?
        return seen(record) unless record.reversed_at.nil?
        return seen(record) unless @actions.reverse!(record, by: operator)

        undo(community, record, operator, statement)
      rescue StandardError => e
        logger&.warn { "content policy: could not vindicate #{code}: #{e.class}: #{e.message}" }
        Outcome.new(status: :failed)
      end

      private

      def seen(record)
        Outcome.new(status: :already, action: record.action, author: record.author_name, policy: record.policy)
      end

      # The claim is already ours by here, so each step below swallows its own
      # failure: a room the bot has since left must not keep the author's
      # notice from going out, or the audit line from being written.
      def undo(community, record, operator, statement)
        endpoint = endpoint_for(community, record)
        # Ahead of the restore, because clearing the reaction is what says
        # whether the author took the message down themselves.
        self_deleted = unflag(endpoint, record) == :gone
        restored = restore(community, endpoint, record, statement, self_deleted: self_deleted)
        unwarn(community, record)
        dmed = tell_author(community, endpoint, record, statement,
                           restored: restored, self_deleted: self_deleted)
        announced = announce_reversal(endpoint, record, statement,
                                      restored: restored, self_deleted: self_deleted)
        record_misfire(community, record, operator, statement)
        record_audit(community, record, operator, statement)
        Outcome.new(status: :reversed, action: record.action, author: record.author_name,
                    policy: record.policy, restored: restored,
                    removed: Service::REMOVES.include?(record.action) || self_deleted,
                    # A restoration counts as telling them: it is in the room under
                    # their own name and carries the apology and the line saying
                    # the copy is theirs to take down.
                    told_author: dmed || announced || restored,
                    silent: record.action == Service::NOTIFY)
      end

      # The ROUTING view of a community, which is the only one carrying rooms
      # that know their endpoints. The console hands in its control-plane row,
      # whose own rooms are Sequel rows with no endpoint lookup on them, so
      # taking that at face value raised inside the reversal. Falls back to
      # what was handed in, which is what a caller already holding the
      # snapshot passes anyway.
      def routed(community)
        @registry&.current&.community_by_id(community.id) || community
      end

      def room_for(community, record)
        routed(community)&.rooms&.find { |room| room.include?(record.endpoint_id) }
      end

      # Nil rather than raising, so a reversal whose room cannot be resolved
      # still clears the strike, tells the author and writes its audit line.
      # Every step after this one already swallows its own failure; this one
      # runs before them and used to take the whole reversal down with it.
      def endpoint_for(community, record)
        room_for(community, record)&.endpoint(record.endpoint_id)
      rescue StandardError => e
        logger&.warn { "content policy: could not resolve the endpoint for #{record.code}: #{e.message}" }
        nil
      end

      # Put the message back wherever the removal reached, which is every
      # endpoint of its room. Only the endpoint it was written on can mention
      # its author, since a native id means nothing on the other platforms.
      # A message this feature removed always comes back. One it only flagged
      # comes back too when its author deleted it themselves, which is the case
      # the spec is about: the flag was wrong, the member took their own message
      # down over it, and putting it back is the whole apology.
      def restore(community, endpoint, record, statement, self_deleted: false)
        return false unless Service::REMOVES.include?(record.action) || self_deleted
        return false if endpoint.nil? || record.body.to_s.strip.empty?

        targets = room_for(community, record)&.endpoints || [endpoint]
        landed = targets.count do |target|
          repost(community, target, record, statement,
                 mention: target.id == endpoint.id, self_deleted: self_deleted)
        end
        landed.positive?
      end

      def repost(community, target, record, statement, mention:, self_deleted: false)
        body = restored_body(target, record, statement, mention: mention, self_deleted: self_deleted)
        group = @ephemeral.post(endpoints: [target], body: body, name: RESTORE_NAME)
        note_reposts(community, target, record, group)
        group.any?
      rescue StandardError => e
        logger&.warn { "content policy: could not restore #{record.native_id} on #{target.id}: #{e.message}" }
        false
      end

      # A restored message is the bot's own post carrying somebody else's
      # words, so nothing about it says who it speaks for. This is what lets
      # that member take it down again with /delete, and lets nobody else.
      def note_reposts(community, target, record, group)
        return if @reposts.nil? || record.author_native_id.to_s.empty?
        # A native id grants nothing in another platform or account namespace.
        # Cross-platform copies need a verified identity before granting delete.
        source = endpoint_for(community, record)
        return unless source && source.adapter_name.to_s == record.adapter.to_s &&
                      target.adapter_name == source.adapter_name && target.account == source.account
        if %w[irc xmpp].include?(record.adapter.to_s)
          return if Security::GrantIdentity.native_id(adapter: record.adapter,
            native_id: record.author_native_id).nil?
        end

        group.copies.each do |copy|
          @reposts.record(
            community_id: community.id, adapter: target.adapter_name, endpoint_id: copy.endpoint.id,
            native_id: copy.native_id, author_native_id: record.author_native_id, identity_verified: true
          )
        end
      rescue StandardError => e
        logger&.warn { "content policy: could not note a restoration: #{e.message}" }
      end

      # The original quoted under its author's name, then the apology and the
      # operator's own words in italics beneath it. Quoting rather than
      # impersonating: no platform here lets the bot post as somebody else,
      # so the attribution has to be visible text.
      def restored_body(endpoint, record, statement, mention:, self_deleted: false)
        name = author_label(record)
        head = "#{name} wrote:\n"
        original = record.body.to_s
        tail = apology_lines(statement, self_deleted: self_deleted, marker: marker_for(endpoint)).join("\n")
        text = "#{head}#{original}\n\n#{tail}"
        quote_begin = head.length
        tail_begin = quote_begin + original.length + 2
        spans = [Core::Span.new(kind: :blockquote, begin_index: quote_begin, end_index: quote_begin + original.length),
                 Core::Span.new(kind: :italic, begin_index: tail_begin, end_index: tail_begin + tail.length)]
        spans << mention_span(endpoint, record, name) if mention
        Core::RichText.new(text, spans)
      end

      # The wording differs on who took the message down. A member who deleted
      # their own message over a flag did not ask for it back, so the line says
      # what happened and how to undo it rather than presenting it as a favour.
      def apology_lines(statement, self_deleted: false, marker: "/")
        lines = [
          if self_deleted
            "Restored: an operator reviewed this and found the flag was wrong. #{author_label_word} " \
              "had deleted it themselves over it, so it is back. Sorry about that. To take it down " \
              "again, reply to this message with #{marker}delete."
          else
            "Restored: an operator reviewed this and found it was removed in error. Sorry about that."
          end
        ]
        lines << "The operator said: #{statement}" unless statement.to_s.strip.empty?
        lines
      end

      # Third person in the room, where everybody is reading it, rather than
      # the "you" the DM uses.
      def author_label_word = "Its author"

      # Only a flag ever placed one, and only the warning reaction is taken
      # off: anything a member added stays where they put it.
      # Clearing the reaction doubles as the only way to learn whether the
      # message is still there, since Telegram tells a bot nothing when a
      # member deletes their own. Only "no such message" counts: a refusal or a
      # rate limit read as gone would repost something still in the room.
      #
      # @return [Symbol] :gone, :cleared, or :unknown
      def unflag(endpoint, record)
        return :unknown if record.action != Service::FLAG_NOTIFY || endpoint.nil?

        adapter = adapter_for(endpoint)
        return :unknown if adapter.nil? || !adapter.capabilities_for(endpoint).reactions?

        adapter.sync_reactions(endpoint, record.native_id, desired: [], previous: [Service::WARNING_REACTION])
        :cleared
      rescue MessageGoneError
        logger&.info { "content policy: #{record.native_id} on #{endpoint.id} is gone, so its author deleted it" }
        :gone
      rescue StandardError => e
        logger&.warn { "content policy: could not clear the flag on #{endpoint&.id}: #{e.class}: #{e.message}" }
        :unknown
      end

      # Clear the strike this action issued, and lift whatever the ladder
      # escalated it to. The warning is cleared by its own id rather than as
      # "the latest", so a member warned again since keeps that newer strike.
      def unwarn(community, record)
        return if record.warning_id.nil? || @warnings_store.nil?

        @warnings_store.deactivate_warning(community: community.slug, id: record.warning_id)
        lift_sanctions(community, record)
      rescue StandardError => e
        logger&.warn { "content policy: could not clear the warning: #{e.class}: #{e.message}" }
      end

      # A mute the strike escalated to outlives the strike itself, so clearing
      # one without the other leaves a member muted for a call that has been
      # reversed. Lifted by the id this action recorded, down the same path the
      # panel's own unmute takes, so only the sanction this action caused goes
      # and one an operator applied by hand is left alone.
      def lift_sanctions(community, record)
        return if record.sanction_id.nil? || @moderation.nil?

        @moderation.unmute(community: community, id: record.sanction_id)
      rescue StandardError => e
        logger&.warn { "content policy: could not lift the sanction: #{e.message}" }
      end

      # The author's own copy, privately. A notify put nothing on the message
      # and told nobody but the operators, so there is nothing to take back.
      def tell_author(community, endpoint, record, statement, restored:, self_deleted: false)
        return false if record.action == Service::NOTIFY
        return false if record.author_native_id.to_s.empty?

        dm_author(community, endpoint, record, statement,
                  restored: restored, self_deleted: self_deleted)
      end

      # The room heard the accusation, so the room hears the reversal: every
      # action but notify posts a notice naming the member and the policy where
      # they were talking, and a DM that landed does nothing to take that back.
      # It was a fallback for a refused DM before, which left the accusation
      # standing as the only public account of it (issue #1909).
      #
      # A restoration is the exception: it is already in the room under the
      # author's name and already carries the apology.
      def announce_reversal(endpoint, record, statement, restored:, self_deleted: false)
        return false if restored || record.action == Service::NOTIFY

        # Under the message itself where it is still standing, which is how the
        # flag that started this was posted. A message the action really did
        # remove is not there to reply to, and asking to reply to one that is
        # gone loses the whole notice rather than just its anchor.
        still_there = !Service::REMOVES.include?(record.action) && !self_deleted
        post_author_notice(endpoint, record, statement,
                           reply_to: (Core::MessageRef.new(endpoint.id, record.native_id) if still_there && endpoint))
      end

      def dm_author(community, endpoint, record, statement, restored: false, self_deleted: false)
        return false if endpoint.nil?

        adapter = adapter_for(endpoint)
        return false if adapter.nil? || !adapter.supports_admin_dm?

        !!adapter.send_admin_dm(
          record.author_native_id,
          author_dm_text(community, statement, restored: restored, self_deleted: self_deleted,
                                                marker: marker_for(endpoint))
        )
      rescue StandardError => e
        logger&.warn { "content policy: could not DM #{record.author_native_id} about a reversal: #{e.message}" }
        false
      end

      # The same sentence in a DM and in the room, differing only in what it
      # opens with: the community's name where there is no room around it, and
      # the author's own name where the mention is doing that work.
      def innocent_text(lead, statement, restored: false, self_deleted: false, marker: "/")
        text = "#{lead} An operator has reviewed the moderation of your message and found you innocent. " \
               "It was reversed, and nothing is held against you."
        text = "#{text} #{restored_sentence(marker, self_deleted: self_deleted)}" if restored
        statement.to_s.strip.empty? ? text : "#{text} The operator said: #{statement}"
      end

      # Somebody who deleted their own message and then finds it back in the
      # room needs to know it is theirs to remove again, since the copy is the
      # bot's post and nothing about it looks like it answers to them.
      def restored_sentence(marker, self_deleted: false)
        opening = if self_deleted
                    "You had deleted that message yourself over the flag, so I have put it back."
                  else
                    "Your message is back in the room."
                  end
        "#{opening} If you would rather it stayed down, reply to it with #{marker}delete " \
          "and I will remove it."
      end

      def author_dm_text(community, statement, restored:, self_deleted:, marker:)
        innocent_text("#{community.name}:", statement, restored: restored,
                                                       self_deleted: self_deleted, marker: marker)
      end

      def post_author_notice(endpoint, record, statement, reply_to: nil)
        return false if endpoint.nil?

        group = @ephemeral.post(endpoints: [endpoint], body: notice_body(endpoint, record, statement),
                                name: NOTICE_NAME, delete_after: NOTICE_TTL, reply_to: reply_to)
        @cleanup&.after(NOTICE_TTL) { group.delete_now } if group.any?
        group.any?
      rescue StandardError => e
        logger&.warn { "content policy: could not post a reversal notice on #{endpoint.id}: #{e.message}" }
        false
      end

      def notice_body(endpoint, record, statement)
        name = author_label(record)
        text = innocent_text(name, statement, marker: marker_for(endpoint))
        span = mention_span(endpoint, record, name)
        Core::RichText.new(text, span ? [span] : [])
      end

      # The command marker that actually works where the reader is: telling an
      # IRC member to type "/delete" would have their own client eat it, which
      # is the same reason /help picks its marker per platform.
      def marker_for(endpoint)
        adapter = endpoint && adapter_for(endpoint)
        capabilities = adapter.respond_to?(:capabilities) ? adapter.capabilities : nil
        Core::CommandPrefix.new.preferred(capabilities: capabilities).to_s
      rescue StandardError
        "/"
      end

      def author_label(record)
        name = record.author_name.to_s.strip
        name.empty? ? "someone" : name
      end

      def mention_span(endpoint, record, name)
        native_id = record.author_native_id.to_s
        return nil if native_id.empty? || endpoint.nil?

        key = :"#{endpoint.adapter_name}_id_for_target"
        Core::Span.new(kind: :mention, begin_index: 0, end_index: name.length, attributes: { key => native_id })
      end

      # An operator calling a match wrong is the only signal this system gets
      # that a description is off, so it is kept as a sample rather than only
      # counted in the audit trail.
      def record_misfire(community, record, operator, statement)
        @misfires&.record(community_id: community.id, action_row: record,
                          statement: statement, reversed_by: operator)
      rescue StandardError => e
        logger&.warn { "content policy: could not log the misfire: #{e.class}: #{e.message}" }
      end

      def record_audit(community, record, operator, statement)
        @audit.record(
          community: community.slug, source: AUDIT_SOURCE, action: AUDIT_ACTION,
          adapter: record.adapter, channel: record.endpoint_id, actor: operator,
          subject: record.author_name, subject_native_id: record.author_native_id,
          target_ref: "#{record.endpoint_id}:#{record.native_id}",
          reason: statement.to_s.strip.empty? ? "an operator found the author innocent" : statement,
          outcome: AUDIT_ACTION, metadata: { policy: record.policy, reversed: record.action, code: record.code }
        )
      rescue StandardError => e
        logger&.warn { "content policy: could not record the reversal: #{e.class}: #{e.message}" }
      end
    end
  end
end
