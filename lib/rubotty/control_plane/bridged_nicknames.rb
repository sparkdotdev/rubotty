# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # The name a person is bridged as, per platform. Folded into the
    # person's handles when the Snapshot is built and consulted by
    # {IdentityDirectory#resolve_unique}, so it hangs off a person rather
    # than one account: a handle on one platform resolves to that person's
    # real account on another. First come wins within a community and
    # platform; a second claim on a taken name is refused, since it could
    # not ping either owner. Allowed characters follow from being a display
    # name; refusals target hiding or spoofing, not non-ASCII.
    class BridgedNicknames
      # Raised for a request that cannot be carried out. Carries a message a
      # caller prints as-is.
      class Invalid < Rubotty::Error; end

      # Both bounds count GRAPHEME CLUSTERS, what a reader calls a character: a
      # flag is two regional indicators and still counts as one.
      MIN_LENGTH = 2
      MAX_LENGTH = 64

      # The width of the `nickname` and `nickname_key` columns, in code points. A
      # name well inside MAX_LENGTH can still overrun them by piling marks onto
      # every character, and that is refused here rather than truncated there.
      STORED_LIMIT = 64

      # What no display name may carry, in any script: control and format
      # characters (Cf covers the zero-width joiner and the bidirectional
      # overrides), surrogates, private use, and the five blank fillers Unicode
      # files as ordinary letters or symbols. Barring the joiner bars the emoji
      # built out of it too, which is what buys the guarantee that two nicknames
      # rendering alike are the same name.
      FORBIDDEN = /[\p{Cc}\p{Cf}\p{Co}\p{Cs}\u115F\u1160\u2800\u3164\uFFA0]/

      # The durable job kind that sweeps every community's closed
      # bridged_nickname_history rows, run once a day.
      NAME_HISTORY_PRUNE_KIND = "bridged_nickname_history_prune"

      # A closed history row (one whose ended_at is set) is kept for a year past
      # the day it closed, then purged, the same window
      # {IdentityDirectory::NAME_HISTORY_RETENTION} holds the observed-identity
      # half of name history to. The still-open row for whoever a person's
      # nickname currently is is never touched here.
      NAME_HISTORY_RETENTION = 365 * 24 * 60 * 60

      # The result of a write.
      #
      # @!attribute status
      #   @return [Symbol] :set, :cleared, :taken or :missing
      Result = Struct.new(:status, :nickname, :adapter, :holder, keyword_init: true) do
        def ok? = %i[set cleared].include?(status)
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Set the name +person+ is shown as on +adapter+, replacing their own
      # previous one for that platform.
      #
      # @param set_by [String] "self" or the operator's label, for the audit trail
      # @return [Result] :set, or :taken naming the person who already holds it
      def set(community_id:, person_id:, adapter:, nickname:, set_by: "self")
        adapter = adapter_name!(adapter)
        nickname = nickname!(nickname)
        key = fold(nickname)
        now = @clock.call

        holder = holder_of(community_id: community_id, adapter: adapter, key: key)
        if holder && holder.person_id != person_id
          return Result.new(status: :taken, nickname: nickname, adapter: adapter, holder: holder)
        end
        if shadows_a_handle?(community_id: community_id, adapter: adapter, key: key, person_id: person_id)
          return Result.new(status: :taken, nickname: nickname, adapter: adapter)
        end

        row = own_row(community_id: community_id, person_id: person_id, adapter: adapter)
        renamed = row.nil? || row.nickname != nickname
        if row
          row.update(nickname: nickname, nickname_key: key, set_by: set_by.to_s, updated_at: now)
        else
          row = @models.bridged_nickname.create(
            community_id: community_id, person_id: person_id, adapter: adapter,
            nickname: nickname, nickname_key: key, set_by: set_by.to_s,
            created_at: now, updated_at: now
          )
        end
        if renamed && identity_history_on?(community_id)
          close_open_nickname_history(community_id: community_id, person_id: person_id, adapter: adapter, at: now)
          open_nickname_history(row, now)
        end
        @logger&.info { "bridged nickname set: community=#{community_id} person=#{person_id} on=#{adapter}" }
        Result.new(status: :set, nickname: nickname, adapter: adapter)
      rescue Sequel::UniqueConstraintViolation
        # Another writer claimed it between the check and the write. Report it the
        # same way, so a race reads as an ordinary refusal.
        Result.new(status: :taken, nickname: nickname, adapter: adapter,
                   holder: holder_of(community_id: community_id, adapter: adapter, key: fold(nickname)))
      end

      # Drop a person's nickname on one platform, so they are shown under whatever
      # the sender label would otherwise build.
      #
      # @return [Result] :cleared, or :missing when there was nothing set
      def clear(community_id:, person_id:, adapter:)
        adapter = adapter_name!(adapter)
        row = own_row(community_id: community_id, person_id: person_id, adapter: adapter)
        return Result.new(status: :missing, adapter: adapter) if row.nil?

        nickname = row.nickname
        row.destroy
        if identity_history_on?(community_id)
          close_open_nickname_history(community_id: community_id, person_id: person_id, adapter: adapter,
                                       at: @clock.call)
        end
        @logger&.info { "bridged nickname cleared: community=#{community_id} person=#{person_id} on=#{adapter}" }
        Result.new(status: :cleared, nickname: nickname, adapter: adapter)
      end

      # A person's bridged-nickname history on one platform (or every
      # platform, with adapter: nil), oldest first, only meaningful while
      # identity_history has been on. Empty when it never has been.
      def nickname_history(community_id:, person_id:, adapter: nil)
        dataset = @models.bridged_nickname_history.where(community_id: community_id, person_id: person_id)
        dataset = dataset.where(adapter: adapter_name!(adapter)) if adapter
        dataset.order(:adapter, :started_at).all
      end

      # {NAME_HISTORY_PRUNE_KIND}'s handler: every closed bridged_nickname_history
      # row past {NAME_HISTORY_RETENTION}. The still-open row for whoever a
      # person's nickname currently is (ended_at nil) is never a candidate here.
      def prune_expired_nickname_history(now: @clock.call)
        cutoff = now - NAME_HISTORY_RETENTION
        @models.bridged_nickname_history
               .exclude(ended_at: nil)
               .where(Sequel[:ended_at] < cutoff)
               .delete
      end

      # Every nickname a person holds, as adapter => nickname.
      def for_person(community_id:, person_id:)
        rows(community_id: community_id).select { |row| row.person_id == person_id }
                                        .to_h { |row| [row.adapter, row.nickname] }
      end

      # Every person's nicknames in a community, as person_id => { adapter => nickname }.
      # One query, because the Snapshot builder wants the whole community at once.
      def by_person(community_id:)
        rows(community_id: community_id).each_with_object({}) do |row, out|
          (out[row.person_id] ||= {})[row.adapter] = row.nickname
        end
      end

      # The person a nickname belongs to in a community, whichever platform it was
      # claimed for, or nil. Compared on the folded key, so case, a leading @ and
      # a fullwidth spelling all land on the same holder.
      def person_id_for(community_id:, nickname:)
        key = fold(nickname)
        return nil if community_id.nil? || key.nil?

        ids = rows(community_id: community_id).select { |row| row.nickname_key == key }
                                              .map(&:person_id).uniq
        ids.size == 1 ? ids.first : nil
      end

      # Every row in a community, for the operator view.
      def list(community_id:) = rows(community_id: community_id)

      # The person row behind a platform account, created together with its
      # identity row when this account has never been linked to one.
      #
      # Setting a nickname is the explicit act that earns somebody a person row:
      # the nickname has to belong to the person rather than one platform account, or it
      # could not follow them to the platform it is meant to be shown on.
      def person_for(community_id:, adapter:, native_id:, username: nil, display: nil)
        existing = person_for_identity(community_id: community_id, adapter: adapter, native_id: native_id)
        return existing if existing

        adapter = adapter_name!(adapter)
        native_id = native_id.to_s.strip
        return nil if community_id.nil? || native_id.empty?

        now = @clock.call
        @models.db.transaction do
          person = @models.person.create(
            community_id: community_id, name: label_for(username, display, native_id),
            created_at: now, updated_at: now
          )
          @models.person_identity.create(
            person_id: person.id, community_id: community_id, adapter: adapter, native_id: native_id,
            username: normalise(username), created_at: now
          )
          person
        end
      rescue Sequel::UniqueConstraintViolation
        # Another writer linked this (adapter, native_id) first, between our read
        # and our write; the transaction above rolled back the orphaned person row,
        # so fall back to the one the other writer created, same as #record and #set.
        person_for_identity(community_id: community_id, adapter: adapter, native_id: native_id)
      end

      # The person already linked to a platform account, or nil. Read-only,
      # unlike #person_for: a page that only lists people (the dashboard's
      # people page, listing everyone the identity directory has ever seen)
      # must not mint a person row just by being viewed.
      def person_for_identity(community_id:, adapter:, native_id:)
        adapter = adapter.to_s.strip.downcase
        native_id = native_id.to_s.strip
        return nil if community_id.nil? || adapter.empty? || native_id.empty?

        person_by_identity(community_id, adapter, native_id)
      end

      private

      def person_by_identity(community_id, adapter, native_id)
        @models.person_identity.where(adapter: adapter, native_id: native_id).order(:id).all.each do |identity|
          person = @models.person[identity.person_id]
          return person if person && person.community_id == community_id
        end
        nil
      end

      # What the person row is called in logs and the operator view.
      def label_for(username, display, native_id)
        [presence(username), presence(display), native_id].compact.first.to_s[0, 200]
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def rows(community_id:)
        @models.bridged_nickname.where(community_id: community_id).order(:adapter, :nickname_key).all
      end

      def own_row(community_id:, person_id:, adapter:)
        @models.bridged_nickname.where(
          community_id: community_id, person_id: person_id, adapter: adapter
        ).first
      end

      # Whether somebody else on that platform already answers to this name for
      # real: a nickname is indexed alongside real handles, so allowing one to
      # collide would quietly redirect that person's pings. Handles arrive from
      # the platforms lowercased and de-sigiled, which is what #fold leaves an
      # ASCII name as, so the two forms meet.
      def shadows_a_handle?(community_id:, adapter:, key:, person_id:)
        observed = @models.observed_identity
                          .where(community_id: community_id, adapter: adapter, username: key)
                          .all
        return true if observed.any? { |identity| !observed_by?(identity, person_id) }

        @models.person_identity.where(adapter: adapter, username: key).all.any? do |identity|
          next false if identity.person_id == person_id

          person = @models.person[identity.person_id]
          person && person.community_id == community_id
        end
      end

      # Whether an observed_identity row is +person_id+'s own linked account:
      # observed_identity carries no person_id itself, so it is resolved through
      # the person_identity row behind the same (adapter, native_id).
      def observed_by?(identity, person_id)
        @models.person_identity
               .where(adapter: identity.adapter, native_id: identity.native_id, person_id: person_id)
               .count.positive?
      end

      def holder_of(community_id:, adapter:, key:)
        @models.bridged_nickname.where(
          community_id: community_id, adapter: adapter, nickname_key: key
        ).first
      end

      def open_nickname_history(row, at)
        @models.bridged_nickname_history.create(
          community_id: row.community_id, person_id: row.person_id, adapter: row.adapter,
          nickname: row.nickname, started_at: at
        )
      end

      def close_open_nickname_history(community_id:, person_id:, adapter:, at:)
        @models.bridged_nickname_history
               .where(community_id: community_id, person_id: person_id, adapter: adapter, ended_at: nil)
               .update(ended_at: at)
      end

      # identity_history is a community-wide flag (Features::IdentityHistory),
      # read straight off feature_settings the same way IdentityDirectory does:
      # see its own identity_history_on? for why.
      def identity_history_on?(community_id)
        row = @models.feature_setting
                     .where(community_id: community_id, feature: Features::IdentityHistory.feature_name, room_id: nil)
                     .first
        return Features::IdentityHistory.default_enabled? if row.nil?

        to_bool(row.enabled)
      end

      def to_bool(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end

      # Lowercase, de-sigiled, blank as nil. The form a platform handle is stored
      # and looked up in.
      def normalise(value)
        key = value.to_s.strip.downcase.delete_prefix("@")
        key.empty? ? nil : key
      end

      # The form the unique index compares on, and where impersonation is caught:
      # compatibility normalised so a fullwidth or decorated spelling folds onto
      # the plain one, case folded, whitespace collapsed, sigil dropped. Accents
      # survive the fold, so a name written with a tilde and one written without
      # stay two names belonging to two people.
      def fold(value)
        text = value.to_s
        return nil unless text.valid_encoding?

        key = tidy(text.unicode_normalize(:nfkc)).delete_prefix("@").strip.downcase(:fold)
        key.empty? ? nil : key
      end

      # Precomposed, with leading and trailing whitespace gone and internal runs
      # down to one space, so one typed name has one stored spelling.
      def tidy(text)
        text.unicode_normalize(:nfc).gsub(/\p{Space}+/, " ").strip
      end

      def adapter_name!(adapter)
        name = adapter.to_s.strip.downcase
        raise Invalid, "name the platform the nickname is for." if name.empty?

        name
      end

      # Tidy a submitted display name or refuse it, saying which part was wrong.
      def nickname!(value)
        text = value.to_s
        raise Invalid, "a nickname has to be readable text." unless text.valid_encoding?

        name = tidy(text).delete_prefix("@").strip
        raise Invalid, "a nickname needs at least one visible character." if fold(name).nil?
        if name.match?(FORBIDDEN)
          raise Invalid, "a nickname cannot contain control, zero-width or invisible characters."
        end
        raise Invalid, "a nickname cannot contain @, which is how a mention names a platform." if name.include?("@")

        length!(name)
        name
      end

      # The two ceilings: what a reader would count, then what the column holds.
      def length!(name)
        length = name.grapheme_clusters.length
        if length < MIN_LENGTH || length > MAX_LENGTH
          raise Invalid, "a nickname is between #{MIN_LENGTH} and #{MAX_LENGTH} characters."
        end
        return unless name.length > STORED_LIMIT || fold(name).length > STORED_LIMIT

        raise Invalid, "that nickname is built from too many pieces to store. Try a plainer one."
      end
    end
  end
end
