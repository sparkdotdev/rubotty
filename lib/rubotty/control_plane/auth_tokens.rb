# frozen_string_literal: true

require "securerandom"
require "digest"
require "sequel"

module Rubotty
  module ControlPlane
    # Mint, list, revoke and redeem the tokens that hand somebody a role.
    # Approval happens at mint time, so redemption needs no second decision:
    # {#mint} returns the raw token ONCE and the row keeps only its SHA-256
    # digest. A token is live while unspent, unrevoked and unexpired, checked IN
    # SQL, and spending it is a conditional UPDATE, so two DMs racing the same
    # token grant exactly one of them. Every failed redemption answers with
    # {REFUSAL} alone, so a guess teaches the guesser nothing about what it hit.
    class AuthTokens
      # Raised for a request that cannot be carried out (nothing granted, a
      # scope the minter does not hold, a lifetime out of range). The message is
      # printed as-is.
      class Invalid < Rubotty::Error; end

      TOKENS_TABLE = :auth_tokens

      ATTEMPTS_TABLE = :auth_token_redemptions

      AUDIT_SOURCE = "auth_tokens"

      # Where an entry about a deployment-wide token is filed, since the audit
      # log is keyed by community and that token belongs to none of them.
      AUDIT_SCOPE = DashboardViewers::AUDIT_SCOPE

      # Bytes of entropy in a raw token, matching {GuestInvites::TOKEN_BYTES}.
      TOKEN_BYTES = 32

      # A day: long enough to hand the token over by whatever means, short
      # enough that one forgotten in a chat log is not a standing invitation.
      DEFAULT_TTL = 86_400

      # A fortnight, the outer bound a minter may choose.
      MAX_TTL = 1_209_600

      # Presentations one identity may make in {ATTEMPT_WINDOW} seconds. Small,
      # because somebody who was handed a token pastes it once.
      ATTEMPT_MAX = 5

      ATTEMPT_WINDOW = 300

      LABEL_MAX = 200

      CREATED_BY_MAX = 200

      # What every refused presentation says. One message for all of them, so a
      # token that never existed, one already spent and one long expired are
      # indistinguishable from the outside.
      REFUSAL = "That token does not work. Check you have all of it, and ask whoever gave it to you for another."

      # What the minter may already do, checked before a row is written so
      # nobody can mint themselves more reach than they hold.
      #
      # @!attribute may_grant_operator
      #   @return [Boolean] whether they hold the operator role itself, not
      #     just read-write access: a developer API key can mint a viewer
      #     token but not an operator one, since that would manufacture a
      #     human role past what the credential holds.
      Minter = Struct.new(:administrator, :community_ids, :may_grant_operator, :label,
                          keyword_init: true) do
        # Strict true, so a stray session value or a string left by a JSON round
        # trip reads as no administrator status at all.
        def administrator? = administrator == true

        # Strict true as well, so a caller that never says reads as no, which is
        # the safe way round for a capability that hands out a role.
        def may_grant_operator? = administrator? || may_grant_operator == true

        def operates?(community_id)
          administrator? || Array(community_ids).map(&:to_i).include?(community_id.to_i)
        end
      end

      # A freshly minted token plus the one-time raw string, which is never
      # recoverable afterwards.
      Issued = Struct.new(:row, :token, keyword_init: true)

      # What a redemption actually handed over, so the reply can say it. Any of
      # them may be absent: a token grants operator, viewer, both, the
      # deployment-wide dimension on its own, or the administrator role.
      #
      # @!attribute problems
      #   @return [Array<String>] the halves that could not be applied. The token
      #     is spent either way, so this is reported rather than swallowed.
      Granted = Struct.new(:operated, :viewed, :deployment_viewer, :administrator, :problems,
                           keyword_init: true) do
        def anything?
          !operated.nil? || !viewed.nil? || deployment_viewer == true || administrator == true
        end
      end

      # The outcome of a redemption, uniform so a caller branches on +status+
      # rather than catching exceptions for control flow.
      #
      # @!attribute status
      #   @return [Symbol] :ok, :invalid or :rate_limited. Every way a token can
      #     fail to work is :invalid, deliberately.
      Result = Struct.new(:status, :row, :granted, keyword_init: true) do
        def ok? = status == :ok
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param operator_flow [OperatorFlow, nil] where an operator grant is
      #   applied. Nil leaves that half of a token unapplied and reported,
      #   same as the other grant destinations below when left nil.
      # @param audit [#record, nil] where an issue and a redemption are recorded
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, operator_flow: nil, community_viewers: nil, dashboard_viewers: nil,
                     dashboard_administrators: nil, audit: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @operator_flow = operator_flow
        @community_viewers = community_viewers
        @dashboard_viewers = dashboard_viewers
        @dashboard_administrators = dashboard_administrators
        @audit = audit || Core::AuditLog::Null.new
        @logger = logger
        @clock = clock
      end

      # @param community_id [Integer, nil] the community the grants land in, or
      #   nil for the deployment-wide viewer
      # @param administrator [Boolean] whether it grants the administrator role,
      #   which covers the whole deployment and so never names a community. Only
      #   an administrator may mint one.
      # @return [Issued] the row and the one-time raw token
      # @raise [Invalid]
      def mint(minter:, community_id: nil, operator: false, viewer: false, administrator: false,
               ttl_seconds: DEFAULT_TTL, label: nil)
        grants_operator = operator == true
        grants_viewer = viewer == true
        grants_administrator = administrator == true
        actor = normalise_actor(minter&.label)
        authorise_mint(minter, community_id, grants_operator, grants_viewer, grants_administrator)
        ttl = normalise_ttl(ttl_seconds)

        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        now = @clock.call
        row = insert_token(
          token: token, community_id: community_id, grants_operator: grants_operator,
          grants_viewer: grants_viewer, grants_administrator: grants_administrator,
          label: label, actor: actor, now: now, ttl: ttl
        )
        record_audit(community_id: community_id, action: "auth_token_issued", actor: actor,
                     subject: grant_words(row), now: now)
        @logger&.info do
          "auth token issued: public_id=#{row[:public_id]} community=#{community_id || "(deployment)"} " \
            "grants=#{grant_words(row)} by=#{actor}"
        end
        Issued.new(row: row, token: token)
      end

      # The tokens for one community, newest first. +community_id: nil+ lists
      # the deployment-wide ones alone; +every: true+ lists the lot, which is
      # what an administrator's view reads.
      def list(community_id: nil, every: false)
        dataset = tokens.reverse(:id)
        dataset = dataset.where(community_id: community_id) unless every
        dataset.all
      rescue ::Sequel::Error => e
        unavailable(e, "list the tokens")
        []
      end

      # One token by its public id, or nil.
      def find(public_id:, community_id: nil, every: false)
        dataset = tokens.where(public_id: public_id.to_s)
        dataset = dataset.where(community_id: community_id) unless every
        dataset.first
      rescue ::Sequel::Error => e
        unavailable(e, "read a token")
        nil
      end

      # Take a token back before it is spent.
      #
      # @return [Result] :removed, :not_found or :spent. A spent token is left
      #   exactly as it was: revoking it would rewrite history without taking
      #   anything back, since the role it granted is already granted.
      def revoke(public_id:, revoked_by:, community_id: nil, every: false)
        actor = normalise_actor(revoked_by)
        row = find(public_id: public_id, community_id: community_id, every: every)
        return Result.new(status: :not_found) if row.nil?
        return Result.new(status: :spent, row: row) unless row[:redeemed_at].nil?

        now = @clock.call
        tokens.where(id: row[:id]).update(revoked_at: now) if row[:revoked_at].nil?
        record_audit(community_id: row[:community_id], action: "auth_token_revoked", actor: actor,
                     subject: grant_words(row), now: now)
        @logger&.info { "auth token revoked: public_id=#{row[:public_id]} by=#{actor}" }
        Result.new(status: :removed, row: tokens.where(id: row[:id]).first)
      rescue ::Sequel::Error => e
        unavailable(e, "revoke a token")
        Result.new(status: :not_found)
      end

      # Spend a presented token and apply what it carries to whoever presented
      # it. Spending happens BEFORE the grants and before any reply, so a token
      # stays spent however the rest of the exchange goes.
      #
      # @return [Result]
      def redeem(token:, adapter:, native_id:, username: nil, display: nil)
        platform = adapter.to_s
        presenter = native_id.to_s
        return Result.new(status: :invalid) if presenter.empty?
        return Result.new(status: :rate_limited) if throttled?(platform, presenter)

        row = live_token(token)
        row = spend(row, platform: platform, presenter: presenter, username: username) unless row.nil?
        record_attempt(platform, presenter, row.nil? ? "refused" : "redeemed")
        return Result.new(status: :invalid) if row.nil?

        granted = apply(row, adapter: platform, native_id: presenter, username: username, display: display)
        record_audit(community_id: row[:community_id], action: "auth_token_redeemed",
                     actor: presence(username) || presenter, subject: grant_words(row), adapter: platform)
        @logger&.info { "auth token redeemed: public_id=#{row[:public_id]} by=#{platform}:#{presenter}" }
        Result.new(status: :ok, row: row, granted: granted)
      end

      # What a token hands over, as words a reply and an audit entry can both
      # use: "operator", "viewer", "operator and viewer", or the wider one.
      def grant_words(row)
        words = []
        if row[:community_id].nil?
          words << "administrator of the deployment" if administrator_token?(row)
          words << "viewer of every community" if truthy?(row[:grants_viewer])
        else
          words << "operator" if truthy?(row[:grants_operator])
          words << "viewer" if truthy?(row[:grants_viewer])
        end
        words.empty? ? "nothing" : words.join(" and ")
      end

      # Whether a token hands over the administrator role. Reads through the
      # same normalisation the other flags do, since SQLite answers 0/1.
      def administrator_token?(row)
        truthy?(row[:grants_administrator])
      end

      # Whether a token is still presentable: unspent, unrevoked, unexpired.
      def live?(row)
        return false if row.nil?
        return false unless row[:redeemed_at].nil? && row[:revoked_at].nil?

        @clock.call < to_time(row[:expires_at])
      end

      # The word a list shows for a token's state.
      def state_of(row)
        return "spent" unless row[:redeemed_at].nil?
        return "revoked" unless row[:revoked_at].nil?

        live?(row) ? "live" : "expired"
      end

      # What this service has recorded, most recent first: +community_id: nil+
      # reads the deployment-wide trail.
      def audit_trail(community_id: nil, limit: 50)
        scope = community_id.nil? ? AUDIT_SCOPE : community_slug(community_id)
        return [] if scope.nil?

        @audit.query(community: scope, source: AUDIT_SOURCE, limit: limit)
      rescue StandardError => e
        @logger&.warn { "auth tokens: could not read the audit trail: #{e.message}" }
        []
      end

      # SHA-256 hex digest of a raw token, or nil for a blank one. What the row
      # stores and what a presentation is matched against.
      def self.hash_token(token)
        string = token.to_s
        return nil if string.empty?

        Digest::SHA256.hexdigest(string)
      end

      private

      # Plain datasets, not model classes, so a process running ahead of this
      # table's migration reads nothing instead of failing to boot.
      def tokens = @models.db[TOKENS_TABLE]

      def attempts = @models.db[ATTEMPTS_TABLE]

      # Refuse a mint the minter's own reach does not cover, before a row exists.
      def authorise_mint(minter, community_id, grants_operator, grants_viewer, grants_administrator)
        unless grants_operator || grants_viewer || grants_administrator
          raise Invalid, "a token has to grant something."
        end

        if community_id.nil?
          if grants_operator
            raise Invalid, "operator is a role in one community, so a token granting it has to name one."
          end

          raise Invalid, deployment_refusal(grants_administrator) unless minter&.administrator?
        elsif grants_administrator
          raise Invalid, "administrator covers the whole deployment, so a token granting it names no community."
        elsif !minter&.operates?(community_id)
          raise Invalid, "you do not operate that community, so there is nothing there for you to hand out."
        end

        return unless grants_operator && !minter.may_grant_operator?

        raise Invalid, "handing out operator needs an operator of that community, or an administrator."
      end

      # Why a deployment-wide mint was refused, in the terms of what it asked
      # for, since the two are wide in different ways.
      def deployment_refusal(grants_administrator)
        return "administering this deployment is an administrator's to hand out." if grants_administrator

        "reading every community is an administrator's to hand out."
      end

      def normalise_ttl(seconds)
        ttl = seconds.to_i
        raise Invalid, "a token needs a positive lifetime." unless ttl.positive?
        raise Invalid, "a token cannot last longer than #{MAX_TTL / 86_400} days." if ttl > MAX_TTL

        ttl
      end

      def normalise_actor(value)
        actor = presence(value)
        raise Invalid, "a token has to say who made it." if actor.nil?

        actor[0, CREATED_BY_MAX]
      end

      def insert_token(token:, community_id:, grants_operator:, grants_viewer:, grants_administrator:,
                       label:, actor:, now:, ttl:)
        values = {
          public_id: SecureRandom.uuid, token_hash: self.class.hash_token(token),
          community_id: community_id, grants_operator: grants_operator, grants_viewer: grants_viewer,
          label: presence(label)&.[](0, LABEL_MAX), created_by: actor,
          created_at: now, expires_at: now + ttl
        }
        # Named only when it is asked for, so a process running ahead of the
        # column's migration still mints the two kinds of token it can record.
        values[:grants_administrator] = true if grants_administrator
        id = tokens.insert(values)
        tokens.where(id: id).first
      rescue ::Sequel::Error => e
        unavailable(e, "mint a token")
        raise Invalid, "handing out a token is not available on this deployment yet."
      end

      # The row a raw token names while it is still live, or nil. Every bound is
      # in the WHERE clause: a naive timestamp read back in another zone would
      # compare wrong, and this is the security gate.
      def live_token(token)
        digest = self.class.hash_token(token)
        return nil if digest.nil?

        now = @clock.call
        tokens.where(token_hash: digest, redeemed_at: nil, revoked_at: nil)
              .where { expires_at > now }
              .first
      rescue ::Sequel::Error => e
        unavailable(e, "resolve a token")
        nil
      end

      # Mark the token spent, and return it only if THIS call is the one that
      # spent it. The redeemed_at guard in the WHERE clause is what makes two
      # simultaneous DMs of the same token grant exactly one of them.
      def spend(row, platform:, presenter:, username:)
        changed = tokens.where(id: row[:id], redeemed_at: nil).update(
          redeemed_at: @clock.call, redeemed_adapter: platform,
          redeemed_native_id: presenter, redeemed_username: presence(username)
        )
        return nil unless changed == 1

        tokens.where(id: row[:id]).first
      rescue ::Sequel::Error => e
        unavailable(e, "spend a token")
        nil
      end

      # Hand over what the token carries. Each half is applied independently and
      # a refusal is reported rather than raised, because the token is already
      # spent by the time this runs and a half-applied grant is worth saying out
      # loud.
      def apply(row, adapter:, native_id:, username:, display:)
        problems = []
        operated = nil
        viewed = nil
        deployment = false
        administrator = false

        if row[:community_id].nil?
          if truthy?(row[:grants_administrator])
            administrator = grant_administrator(adapter, username, native_id, display, row, problems)
          end
          if truthy?(row[:grants_viewer])
            deployment = grant_deployment_viewer(adapter, username, native_id, row, problems)
          end
        else
          if truthy?(row[:grants_operator])
            operated = grant_operator(row, adapter, native_id, username, display, problems)
          end
          if truthy?(row[:grants_viewer])
            viewed = grant_community_viewer(row, adapter, username, native_id, display, problems)
          end
        end
        Granted.new(operated: operated, viewed: viewed, deployment_viewer: deployment,
                    administrator: administrator, problems: problems)
      end

      def grant_operator(row, adapter, native_id, username, display, problems)
        if @operator_flow.nil?
          problems << "operator status could not be granted on this deployment."
          return nil
        end

        @operator_flow.promote(
          community_id: row[:community_id], adapter: adapter, native_id: native_id,
          username: username, display: display, granted_by: granted_by_label(row)
        )
        @models.community[row[:community_id]]
      rescue StandardError => e
        @logger&.warn { "auth tokens: could not grant operator: #{e.class}: #{e.message}" }
        problems << "operator status could not be granted just now."
        nil
      end

      def grant_community_viewer(row, adapter, username, native_id, display, problems)
        return nil if @community_viewers.nil?

        handle = CommunityViewers.handle_for(adapter: adapter, username: username, native_id: native_id)
        if handle.nil?
          problems << "reading it needs a username on this platform, and this account has none."
          return nil
        end

        @community_viewers.grant(community_id: row[:community_id], adapter: adapter, handle: handle,
                                 label: presence(display), native_id: native_id, granted_by: granted_by_label(row))
        @models.community[row[:community_id]]
      rescue CommunityViewers::Invalid
        if @community_viewers.viewer?(community_id: row[:community_id], adapter: adapter,
                                       username: username, native_id: native_id)
          return @models.community[row[:community_id]]
        end

        problems << "reading that community needs a durable native account identity and a fresh grant."
        nil
      rescue StandardError => e
        @logger&.warn { "auth tokens: could not grant a community viewer: #{e.class}: #{e.message}" }
        problems << "reading that community could not be granted just now."
        nil
      end

      # The administrator half binds the presenting native account, with its
      # public handle (or id) retained only as a label.
      def grant_administrator(adapter, username, native_id, display, row, problems)
        return false if @dashboard_administrators.nil?

        handle = CommunityViewers.handle_for(adapter: adapter, username: username, native_id: native_id)
        if handle.nil?
          problems << "administering this deployment needs a username on this platform, " \
                      "and this account has none."
          return false
        end

        @dashboard_administrators.grant(adapter: adapter, handle: handle, label: presence(display),
                                        native_id: native_id, granted_by: granted_by_label(row))
        true
      rescue DashboardAdministrators::Invalid
        return true if @dashboard_administrators.administrator?(adapter: adapter, username: username, native_id: native_id)

        problems << "administering this deployment needs a durable native account identity and a fresh grant."
        false
      rescue StandardError => e
        @logger&.warn { "auth tokens: could not grant the administrator: #{e.class}: #{e.message}" }
        problems << "administering this deployment could not be granted just now."
        false
      end

      def grant_deployment_viewer(adapter, username, native_id, row, problems)
        return false if @dashboard_viewers.nil?

        handle = CommunityViewers.handle_for(adapter: adapter, username: username, native_id: native_id)
        if handle.nil?
          problems << "reading every community needs a username on this platform, and this account has none."
          return false
        end

        @dashboard_viewers.grant(adapter: adapter, handle: handle, native_id: native_id,
                                 granted_by: granted_by_label(row))
        true
      rescue DashboardViewers::Invalid
        return true if @dashboard_viewers.viewer?(adapter: adapter, username: username, native_id: native_id)

        problems << "reading every community needs a durable native account identity and a fresh grant."
        false
      rescue StandardError => e
        @logger&.warn { "auth tokens: could not grant the deployment viewer: #{e.class}: #{e.message}" }
        problems << "reading every community could not be granted just now."
        false
      end

      # Who the grant is recorded as coming from: the token, named by the person
      # who minted it, since that is where the decision was actually taken.
      def granted_by_label(row)
        "token from #{presence(row[:created_by]) || "the dashboard"}"[0, CREATED_BY_MAX]
      end

      # Whether this identity has presented too many tokens lately. Counted over
      # durable rows, so the limit survives a restart and holds across instances.
      def throttled?(adapter, native_id)
        since = @clock.call - ATTEMPT_WINDOW
        attempts.where(adapter: adapter, native_id: native_id)
                .where { attempted_at > since }
                .count >= ATTEMPT_MAX
      rescue ::Sequel::Error => e
        # No table means no limit to enforce, and refusing every redemption over
        # a missing counter would be worse than not counting.
        unavailable(e, "count the recent attempts")
        false
      end

      def record_attempt(adapter, native_id, outcome)
        attempts.insert(adapter: adapter, native_id: native_id, outcome: outcome, attempted_at: @clock.call)
      rescue ::Sequel::Error => e
        unavailable(e, "record an attempt")
        nil
      end

      # Filed under the community for a community-scoped token and under the
      # deployment name for the wider one, matching how the two viewer services
      # already file theirs.
      def record_audit(community_id:, action:, actor:, subject:, adapter: nil, now: @clock.call)
        scope = community_id.nil? ? AUDIT_SCOPE : community_slug(community_id)
        return nil if scope.nil?

        @audit.record(community: scope, source: AUDIT_SOURCE, action: action,
                      adapter: adapter, actor: actor, subject: subject, now: now)
      rescue StandardError => e
        @logger&.warn { "auth tokens: could not record #{action}: #{e.message}" }
        nil
      end

      def community_slug(community_id)
        @models.community[community_id]&.slug
      rescue ::Sequel::Error
        nil
      end

      # The table arrives with its own migration, so a process running ahead of
      # it reads nothing rather than failing. Logged, since on a migrated
      # deployment this can only mean a real database problem.
      def unavailable(error, doing)
        @logger&.warn { "auth tokens: could not #{doing}: #{error.message}" }
      end

      # SQLite hands booleans back as 0/1 through some Sequel paths, so normalise
      # rather than trusting the raw value (0 is truthy in Ruby).
      def truthy?(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end

      # Sequel returns DateTime or Time depending on the backend; normalise so
      # the comparison is backend-independent.
      def to_time(value)
        return value if value.is_a?(Time)

        value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
