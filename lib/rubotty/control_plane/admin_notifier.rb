# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # Tells somebody about something time-sensitive, by DM, on whichever platform
    # can actually reach them. {#notify!} reaches the deployment's administrator,
    # the owner-level operator floor {Security::ProtectedOperators} declares;
    # {#notify_operators!} reaches one community's operators, the granted rows
    # and that same floor alike. Finding them to DM is best effort: a bot can
    # only reliably message someone who has spoken to it before, so an
    # administrator who has never messaged the bot on a platform is not
    # reachable there yet.
    class AdminNotifier
      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared
      #   adapter map, for actually sending the DM
      # @param protected_operators [Security::ProtectedOperators] whose handles
      #   count as "the administrator"
      # @param logger [#info, #warn, nil]
      # @param registry [#current, nil] the live snapshot, for resolving a
      #   community's nominated alert room; nil leaves every alert a DM
      def initialize(models:, adapters:, protected_operators: Security::ProtectedOperators.default,
                     logger: nil, registry: nil)
        @models = models
        @adapters = adapters
        @protected_operators = protected_operators
        @logger = logger
        @registry = registry
        @audience = OperatorAudience.new(models: models, protected_operators: protected_operators)
        @reachability = OperatorReachability.new(models: models, adapters: adapters, logger: logger,
                                                 protected_operators: protected_operators)
      end

      # DM +text+ to the administrator on every reachable platform. Best
      # effort throughout: a failure on one platform never stops another from
      # being tried, and nothing here raises out.
      #
      # @return [Integer] how many platforms it actually reached
      def notify!(text)
        return 0 if text.to_s.strip.empty?

        candidates.count { |candidate| deliver(candidate, text) }
      end

      # What one operator alert actually did. A count of DMs sent cannot tell
      # an audience of nobody apart from an audience that all refused, and a
      # caller deciding whether a human heard about something needs to know
      # the difference. +audience+ is how many targets were tried at all.
      Delivery = Struct.new(:audience, :reached, :refused, :unreachable, keyword_init: true) do
        def self.none = new(audience: 0, reached: 0, refused: 0, unreachable: 0)

        # Nobody heard about it, whatever the reason.
        def none? = reached.to_i.zero?

        # There was nobody to tell in the first place.
        def nobody_to_tell? = audience.to_i.zero?
      end

      # DMs +text+ to every operator of ONE community, on every platform they're
      # reachable on, best effort in exactly the same way {#notify!} is.
      # Reachability depends on each operator's adapter and connection. Adapters
      # with direct-message support can deliver; unavailable or refused targets
      # are recorded without preventing delivery to the remaining operators.
      #
      # @param community_id [Integer]
      # @return [Delivery]
      def notify_operators!(community_id:, text:)
        return Delivery.none if community_id.nil? || text.to_s.strip.empty?

        room = notify_room(community_id, text)
        return room unless room.nil?

        targets = operator_candidates(community_id)
        # One refused DM must never cost the operators who ARE reachable
        # theirs, so each delivery is its own attempt and its own outcome.
        outcomes = targets.map { |candidate| delivery_of(candidate, text, community_id: community_id) }
        Delivery.new(audience: targets.length, reached: outcomes.count(:sent),
                     refused: outcomes.count(:refused), unreachable: outcomes.count(:unreachable))
      rescue StandardError => e
        @logger&.warn { "admin notifier: could not reach the operators of #{community_id}: #{e.message}" }
        Delivery.none
      end

      # One community's nominated alert room, or nil where it has none. The
      # setting sits on the moderation feature at community scope, one field for
      # "tell my operators here" rather than one per feature, since every alert
      # already comes through this one call.
      ALERT_ROOM_FIELD = :operator_alert_room
      ALERT_ROOM_FEATURE = "moderation"

      # Post one copy into the nominated room instead of a DM each. Nil means
      # "not this way", which is every reason there is: no room named, no
      # snapshot to resolve it against, a room key that no longer names
      # anything, or a post that reached none of its endpoints. Each falls back
      # to the DM fan-out, because an alert nobody hears is the failure the
      # alert_undelivered audit row exists to record.
      def notify_room(community_id, text)
        community = @registry&.current&.community_by_id(community_id)
        return nil if community.nil?

        endpoints = alert_room_endpoints(community)
        return nil if endpoints.empty?

        sent = endpoints.count { |endpoint| post_alert(endpoint, text) }
        return nil if sent.zero?

        Delivery.new(audience: endpoints.length, reached: sent, refused: 0,
                     unreachable: endpoints.length - sent)
      rescue StandardError => e
        @logger&.warn { "admin notifier: could not post to the alert room of #{community_id}: #{e.message}" }
        nil
      end

      # Every (adapter, account, native id) the operators of one community are
      # reachable at, deduplicated: the granted rows first, then the deployment-configured
      # floor {Security::ProtectedOperators} declares, which holds no operator
      # row anywhere by design and so was left out of every alert until now.
      # The operators screen lists both, so an audience of only the first is
      # smaller than that screen says it is, and a deployment whose operators
      # are all baked in heard nothing at all. Public so a second DM audience
      # ({Core::Runtime#post_operator_dm_for_community}) resolves the same set.
      def operator_candidates(community_id)
        accounts = {}
        seen = {}
        audience_rows(community_id).each do |row, identity_id|
          native_id = row.native_id.to_s
          adapter = row.adapter.to_s
          key = [adapter, native_id]
          next if native_id.empty? || seen.key?(key)

          accounts[adapter] = account_for_community(community_id, adapter) unless accounts.key?(adapter)
          account = accounts[adapter]
          next unless account

          seen[key] = { adapter: adapter, account: account, native_id: native_id, identity_id: identity_id }
        end
        seen.values
      end

      private

      # Every directory row the audience covers, paired with the
      # person_identity id a refusal is recorded against so it lands on the
      # account it was aimed at rather than only in a log line. A sighting owns
      # no such row, so it pairs with nil and is remembered nowhere.
      def audience_rows(community_id)
        @audience.identity_rows(community_id).map { |row| [row, row.id] } +
          @audience.sighting_rows(community_id).map { |row| [row, nil] }
      end

      # One DM, and the one place a delivery failure stops. Says which of
      # three things happened rather than yes or no: a platform this
      # deployment cannot DM on at all and a recipient the platform refused
      # are different problems, and neither one is a delivery. Every outcome
      # that is not a delivery says so here, because an adapter knows only the
      # account it was refused at, never the community whose alert it was.
      def delivery_of(candidate, text, community_id: nil)
        adapter = @adapters[[candidate[:adapter].to_sym, candidate[:account]]]
        return missed(candidate, :unreachable, "no loaded connection for that account", community_id) if adapter.nil?
        unless adapter.supports_admin_dm?
          return missed(candidate, :unreachable, "the platform has no DM", community_id)
        end

        if adapter.send_admin_dm(candidate[:native_id], text)
          @reachability.delivered(candidate[:identity_id])
          return :sent
        end

        missed(candidate, :refused, "the platform refused it", community_id)
      rescue StandardError => e
        missed(candidate, :refused, "#{e.class}: #{e.message}", community_id)
      end

      # A candidate the alert did not get to, named where an operator can see
      # which one and why. Warn rather than info: nobody looks for this until
      # an alert has already gone missing. A refusal is the recipient's own
      # account saying no, so it is remembered as well as logged; the other
      # outcome is the deployment's own shape and says nothing about them.
      def missed(candidate, outcome, reason, community_id = nil)
        where = community_id.nil? ? "" : " for community #{community_id}"
        @logger&.warn { "admin notifier: no DM to #{candidate[:adapter]}:#{candidate[:native_id]}#{where}, #{reason}" }
        @reachability.refused(candidate[:identity_id], reason) if outcome == :refused
        outcome
      end

      # {#notify!}'s own yes or no, over the same single delivery.
      def deliver(candidate, text) = delivery_of(candidate, text) == :sent

      # The sending endpoints of the room this community nominated, or an empty
      # list where it named none or the key no longer resolves.
      def alert_room_endpoints(community)
        config = community.feature_config(nil, ALERT_ROOM_FEATURE)
        return [] unless config.is_a?(Hash)

        raw = config.key?(ALERT_ROOM_FIELD) ? config[ALERT_ROOM_FIELD] : config[ALERT_ROOM_FIELD.to_s]
        key = raw.to_s.strip
        return [] if key.empty?

        room = community.rooms.find { |candidate| candidate.id == key }
        if room.nil?
          @logger&.warn { "admin notifier: #{community.slug} names alert room #{key.inspect}, which no longer exists" }
          return []
        end

        room.endpoints.select(&:sends?)
      end

      # One alert into one endpoint. An alert carries message text, a name and
      # sometimes a permalink, so this is exactly what the DM kept narrow: the
      # room has to be operator only, which rubotty cannot verify and the
      # dashboard panel says plainly is being trusted.
      def post_alert(endpoint, text)
        adapter = @adapters[[endpoint.adapter_name, endpoint.account]]
        return false if adapter.nil?

        # ref is nil because nothing has been sent yet: it is the id of an
        # existing message, and this is the one being composed.
        message = Core::Message.new(kind: :chat, ref: nil, origin: endpoint,
                                    body: Core::RichText.plain(text))
        !adapter.deliver(message, endpoint).nil?
      rescue StandardError => e
        @logger&.warn { "admin notifier: alert room #{endpoint.id} refused the post: #{e.class}: #{e.message}" }
        false
      end

      def account_for_community(community_id, adapter)
        @models.platform_connection.where(community_id: community_id, adapter: adapter).first&.account
      end

      # One candidate per adapter: the most recently seen sighting of a
      # protected handle, anywhere. A deployment running several accounts on the
      # same adapter may pick the wrong one; this notifier is a convenience.
      def candidates
        return [] if @protected_operators.empty?

        seen = {}
        @models.observed_identity.order(Sequel.desc(:last_seen_at)).each do |row|
          next if seen.key?(row.adapter)
          next unless @protected_operators.owner?(adapter: row.adapter, username: row.username,
                                                   native_id: row.native_id)

          account = account_for(row)
          seen[row.adapter] = { adapter: row.adapter, account: account, native_id: row.native_id } if account
        end
        seen.values
      end

      # observed_identities carries no account column, so the account is resolved
      # from the sighting's own community's platform_connections instead.
      def account_for(row)
        @models.platform_connection.where(community_id: row.community_id, adapter: row.adapter).first&.account
      end
    end
  end
end
