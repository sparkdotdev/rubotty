# frozen_string_literal: true

module Rubotty
  module Features
    # The /cancel-by-reply mechanism PollSurface and EventRsvp both apply to
    # their own card: the poll, schedule or event's own creator may end it
    # early, and so may anybody this room already recognises as an operator,
    # the same check /event's own who_can_create gate uses. The including
    # class must define #issuer_label(context), matching whatever it already
    # stamps created_by with when the item is made, so the comparison here
    # means the same thing at both ends.
    module CardCancellation
      private

      # @param text [String] a reply already known to land on our own card
      # @return [Boolean] whether it asks to cancel the thing it replied to
      def cancel_reply?(context, text)
        body = context.command_prefixes.strip(text) || text
        body.to_s.strip.casecmp("cancel").zero?
      end

      # @param item [#created_by] the poll or event a reply landed on
      def may_cancel?(context, item)
        creator = item.created_by.to_s
        return true if !creator.empty? && creator == issuer_label(context)

        operator?(context)
      end

      def operator?(context)
        directory = context.operators
        author = context.message.author
        return false if directory.nil? || author.nil?

        !directory.resolve(context.message.origin.adapter_name, author.native_id,
                           username: author.username).nil?
      rescue StandardError => e
        logger.warn { "card_cancellation: operator? failed: #{e.class}: #{e.message}" }
        false
      end

      # The name a cancellation notice credits, in the same order #handle_for
      # elsewhere in these two features already prefers a name.
      def cancel_actor_label(context)
        author = context.message.author
        return context.message.origin.adapter_name.to_s if author.nil?

        author.username || author.nickname || author.display_name || author.native_id.to_s
      end
    end
  end
end
