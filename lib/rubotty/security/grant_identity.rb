# frozen_string_literal: true

require "sequel"

module Rubotty
  module Security
    # Resolves a privileged grant once, when it is authorised. A handle is a
    # label and lookup hint; it never remains an authentication credential.
    module GrantIdentity
      class Invalid < Rubotty::Error; end

      MAX_ID = 255
      ACCOUNT_ADAPTERS = %w[telegram discord stoat fluxer api_wrapper].freeze
      MATRIX_ID = /\A@[^:\s]+:[^\s]+\z/
      IRC_ACCOUNT = /\Aaccount:[^:\s]+:[^\s]+\z/
      XMPP_JID = /\A[^@\/\s]+@[^\/\s]+\z/

      def self.native_id(adapter:, native_id: nil, username: nil)
        platform = adapter.to_s
        if platform == "matrix"
          # An MXID is an opaque, case-sensitive identity, including its server
          # name. A native value must never be trimmed or case-folded into one.
          value = native_id.nil? || native_id.to_s.empty? ? username : native_id
          id = value.to_s
          return id if id.bytesize <= MAX_ID && MATRIX_ID.match?(id)

          return nil
        end
        id = presence(native_id)
        return nil if id.nil? || id.length > MAX_ID

        case platform
        when *ACCOUNT_ADAPTERS
          id
        when "irc"
          # The network scope and authenticated account must both be explicit.
          # An ordinary IRC nickname is session-scoped and is never enough.
          id.downcase if IRC_ACCOUNT.match?(id)
        when "xmpp"
          jid = id.delete_prefix("jid:")
          "jid:#{jid.downcase}" if id.start_with?("jid:") && XMPP_JID.match?(jid)
        end
      end

      # Database collations are not proof of identity equality. In particular,
      # an older case-insensitive text column may return another Matrix account
      # for the same WHERE value. Verify exact equality before authorising it.
      def self.exact_rows(dataset, native_id:, column: :native_id)
        dataset.where(column => native_id).all.select { |row| row[column] == native_id }
      end

      # Only an authorised grant or explicit config declaration can interpret a
      # bare JID as an account. Inbound room nicknames never call this method.
      def self.grant_native_id(adapter:, native_id:)
        id = presence(native_id)
        if adapter.to_s == "xmpp" && id && XMPP_JID.match?(id) && !id.start_with?("jid:")
          id = "jid:#{id}"
        end
        self.native_id(adapter: adapter, native_id: id)
      end

      def self.resolve(models:, adapter:, handle:, native_id: nil, community_id: nil)
        explicit = presence(native_id)
        if explicit || adapter == "matrix" || adapter == "irc"
          value = explicit || (handle if adapter == "matrix" || adapter == "irc")
          id = grant_native_id(adapter: adapter, native_id: value)
          return id unless id.nil?

          raise Invalid, "a grant needs a durable native account id; Matrix needs a full MXID and IRC needs a scoped authenticated account."
        end
        unless ACCOUNT_ADAPTERS.include?(adapter)
          raise Invalid, "this platform does not provide a durable account identity for a privileged grant."
        end

        ids = %i[person_identities observed_identities].flat_map do |table|
          scope = models.db[table].where(adapter: adapter)
          scope = scope.where(community_id: community_id) unless community_id.nil?
          scope.where(Sequel.function(:lower, :username) => [handle, "@#{handle}"])
               .select_map(:native_id)
        end.filter_map { |value| self.native_id(adapter: adapter, native_id: value) }.uniq
        return ids.first if ids.size == 1

        reason = ids.empty? ? "has no known native account id" : "matches several native account ids"
        raise Invalid, "#{handle} #{reason}. Use an explicit native_id, or ask the person to request access and approve that request."
      end

      def self.presence(value)
        value = value.to_s.strip
        value unless value.empty?
      end
      private_class_method :presence
    end
  end
end
