# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # The passively-learned, per-community identity directory: the substrate
    # `/find` searches and cross-platform @mentions resolve against.
    # {#record} upserts one observed (community, platform, native id) entry,
    # which is what makes the directory build itself by watching the room;
    # {#search} is the substring match /find uses, {#resolve} the exact
    # handle lookup. No cross-platform person-linking happens here: passive
    # observation cannot know two handles are one human, so identities on
    # different platforms stay SEPARATE rows.
    class IdentityDirectory
      DEFAULT_LIMIT = 25

      # The result of resolving a bare fragment. +matches+ is populated only
      # when several observed handles contain the fragment, so callers can
      # ask for a more specific tag without treating an ordinary miss as an
      # error.
      FragmentResolution = Struct.new(:native_id, :matches, keyword_init: true)

      # The durable job kind that sweeps every community's stale entries, run
      # once a day.
      PRUNE_KIND = "identity_directory_prune"
      PRUNE_INTERVAL = 24 * 60 * 60

      # How long an identity may go unseen before the scheduled sweep drops
      # it: ninety days, the same floor {ScriptStats} holds its own
      # passively accumulated rows to. A per-community window is still
      # future work; this fixed one is what ships today.
      RETENTION = 90 * 24 * 60 * 60

      # The durable job kind that sweeps every community's closed name-history
      # rows, run once a day alongside {PRUNE_KIND}.
      NAME_HISTORY_PRUNE_KIND = "observed_identity_names_prune"

      # A closed name-history row (one whose ended_at is set) is kept for a
      # year past the day it closed, then purged. The still-open row for
      # whoever a person currently is is never touched here.
      NAME_HISTORY_RETENTION = 365 * 24 * 60 * 60

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, clock: -> { Time.now })
        @models = models
        @clock = clock
      end

      # Upsert the observed identity for one (community, platform, native id):
      # a first sighting inserts a row, a repeat updates the handle and
      # display when changed and always advances last_seen_at. Nil when
      # there is not enough to key on, since without a native id the entry
      # cannot be deduplicated.
      def record(community_id:, adapter:, native_id:, username: nil, display: nil)
        adapter = adapter.to_s
        native_id = presence(native_id)
        return nil if community_id.nil? || adapter.empty? || native_id.nil?

        handle = normalise_handle(username)
        name = presence(display)
        now = @clock.call

        existing = entry(community_id: community_id, adapter: adapter, native_id: native_id)
        return touch(existing, handle, name, now) if existing

        row = @models.observed_identity.create(
          community_id: community_id, adapter: adapter, native_id: native_id,
          username: handle, display_name: name, first_seen_at: now, last_seen_at: now
        )
        open_name_history(row, now) if identity_history_on?(community_id)
        row
      rescue Sequel::UniqueConstraintViolation
        # A concurrent sighting inserted the same entry first; fall back to it and
        # apply this sighting's update, so a race stays a plain upsert.
        again = entry(community_id: community_id, adapter: adapter, native_id: native_id)
        again && touch(again, handle, name, now)
      end

      # One identity's username/display-name history, oldest first: every
      # observed_identity_names row, only meaningful while identity_history
      # has been on. Empty when it never has been.
      def name_history(community_id:, adapter:, native_id:)
        @models.observed_identity_name
               .where(community_id: community_id, adapter: adapter.to_s, native_id: native_id.to_s)
               .order(:started_at)
               .all
      end

      # Directory entries in a community whose handle OR display name contains
      # +query+ (case-insensitive substring), across platforms, as separate rows.
      # Ordered so results are stable: by platform, then handle, then id.
      #
      # @return [Array<Models::ObservedIdentity>]
      def search(community_id:, query:, limit: DEFAULT_LIMIT)
        needle = presence(query)
        return [] if community_id.nil? || needle.nil?

        dataset = matching(community_id: community_id, query: needle).order(:adapter, :username, :id)
        dataset = dataset.limit(limit) if limit
        dataset.all
      end

      # The dashboard's people page: a community's directory, most recently seen
      # first and capped, optionally narrowed by the same substring match
      # {#search} uses. Never the whole table: a busy community's directory has
      # to stay scrollable rather than rendered whole.
      #
      # @return [Array<Models::ObservedIdentity>]
      def recent(community_id:, query: nil, limit: DEFAULT_LIMIT)
        return [] if community_id.nil?

        needle = presence(query)
        dataset = needle ? matching(community_id: community_id, query: needle)
                         : @models.observed_identity.where(community_id: community_id)
        dataset = dataset.order(Sequel.desc(:last_seen_at), Sequel.desc(:id))
        dataset = dataset.limit(limit) if limit
        dataset.all
      end

      # The native id behind an exact (platform, handle) in a community, or nil. The
      # handle is normalised the same way it is stored (de-sigiled, lowered), so a
      # `@Handle` mention matches a `handle` entry.
      def resolve(community_id:, adapter:, handle:)
        handle = normalise_handle(handle)
        return nil if community_id.nil? || handle.nil?

        row = @models.observed_identity
                     .where(community_id: community_id, adapter: adapter.to_s, username: handle)
                     .order(:id).first
        row&.native_id
      end

      # The native id behind an exact (platform, handle), but ONLY when it is
      # UNAMBIGUOUS: nil when two or more distinct native ids share the same
      # handle in the same community and platform. This is the resolution
      # cross-platform @mentions use, since an ambiguous handle must stay
      # plain text rather than ping a guessed-at person; {#resolve} keeps its
      # first-match behaviour for callers that would rather have a best
      # effort.
      def resolve_unique(community_id:, adapter:, handle:)
        handle = normalise_handle(handle)
        return nil if community_id.nil? || handle.nil?

        ids = @models.observed_identity
                     .where(community_id: community_id, adapter: adapter.to_s, username: handle)
                     .select_map(:native_id)
                     .uniq
        return ids.first if ids.size == 1
        return nil unless ids.empty?

        # A bridged nickname resolves here like any other handle, so a mention
        # addressed to one lands on that person's account on the target.
        nickname_native_id(community_id: community_id, adapter: adapter, handle: handle)
      end

      # Resolve a bare mention fragment on one platform. An exact observed
      # handle keeps its existing precedence, followed by an exact bridged
      # nickname. Only then does a case-insensitive substring lookup run, and
      # it resolves only when one observed identity matches. Several fragment
      # matches stay unresolved and carry their handles for a short reply to
      # the author; an ordinary miss carries none.
      #
      # @return [FragmentResolution]
      def resolve_unique_fragment(community_id:, adapter:, handle:)
        handle = normalise_handle(handle)
        return FragmentResolution.new(native_id: nil, matches: []) if community_id.nil? || handle.nil?

        exact = @models.observed_identity
                       .where(community_id: community_id, adapter: adapter.to_s, username: handle)
                       .select_map(:native_id).compact.uniq
        return FragmentResolution.new(native_id: exact.first, matches: []) if exact.size == 1
        return FragmentResolution.new(native_id: nil, matches: []) unless exact.empty?

        nickname = nickname_native_id(community_id: community_id, adapter: adapter, handle: handle)
        return FragmentResolution.new(native_id: nickname, matches: []) unless nickname.nil?

        matches = matching_handles(community_id: community_id, adapter: adapter, fragment: handle)
        ids = matches.map(&:native_id).uniq
        return FragmentResolution.new(native_id: ids.first, matches: []) if ids.size == 1

        FragmentResolution.new(native_id: nil, matches: ids.size > 1 ? matches : [])
      end

      # The nickname the person behind +native_id+ is bridged as on +adapter+,
      # or nil: the reverse of {#resolve_unique}'s own nickname fallback,
      # once an id has been resolved. Requires the account already linked to
      # a person row (see {BridgedNicknames#person_for}); passive observation
      # alone never creates one, so an unnicknamed account answers nil here.
      def nickname_for(community_id:, adapter:, native_id:)
        nicknames = BridgedNicknames.new(models: @models)
        person = nicknames.person_for_identity(community_id: community_id, adapter: adapter, native_id: native_id)
        return nil if person.nil?

        nicknames.for_person(community_id: community_id, person_id: person.id)[adapter.to_s]
      end

      # One entry by its exact key, or nil. For the recorder's dedupe and tests.
      def entry(community_id:, adapter:, native_id:)
        @models.observed_identity.where(
          community_id: community_id, adapter: adapter.to_s, native_id: native_id.to_s
        ).first
      end

      # The whole directory for a community, oldest first. For the dashboard.
      def entries(community_id:)
        @models.observed_identity.where(community_id: community_id).order(:id).all
      end

      # The shortest handle or display name a substring match on the other still
      # counts as "distinctive", the anti-stalking rule. At length 1 or 2 nearly
      # every short word would collide with SOME handle in a busy community.
      MIN_DISTINCTIVE_LENGTH = 3

      # Whether +keyword+ collides with a known identity in this community,
      # the hard "don't watch a name or handle" constraint on the keyword
      # watcher: a collision counts, case-insensitively, when the keyword
      # equals a handle or display name outright, or either is a substring
      # of the other at least {MIN_DISTINCTIVE_LENGTH} characters long
      # (accepting some collateral, like "chase" or "grace"). Checked both
      # at registration and again at match time, since the population
      # changes, which is why this reads the LIVE directory.
      def handle_collision?(community_id:, keyword:)
        needle = presence(keyword)&.downcase
        return false if community_id.nil? || needle.nil?

        @models.observed_identity
               .where(community_id: community_id)
               .select(:username, :display_name)
               .distinct
               .any? { |row| name_collides?(needle, row.username) || name_collides?(needle, row.display_name) }
      end

      # Retention pruning (privacy): drop entries in a community not seen
      # since +older_than+, returning how many were removed.
      # {#prune_expired} is {PRUNE_KIND}'s handler, the scheduled sweep across
      # every community on {RETENTION}; this lower-level, single-community
      # form stays for a caller that wants its own schedule.
      def prune(community_id:, older_than:)
        return 0 if community_id.nil? || older_than.nil?

        @models.observed_identity
               .where(community_id: community_id)
               .where(Sequel[:last_seen_at] < older_than)
               .delete
      end

      # {PRUNE_KIND}'s handler: every community's entries past {RETENTION}, in
      # one pass, since a durable job carries no community of its own to scope
      # {#prune} to. Run daily by {Core::Runtime}; before that nothing called
      # {#prune} at all and a directory grew unbounded.
      def prune_expired(now: @clock.call)
        cutoff = now - RETENTION
        @models.community.select_map(:id).sum { |id| prune(community_id: id, older_than: cutoff) }
      end

      # {NAME_HISTORY_PRUNE_KIND}'s handler: every closed observed_identity_names
      # row past {NAME_HISTORY_RETENTION}. The still-open row for whoever a
      # person currently is (ended_at nil) is never a candidate here.
      def prune_expired_name_history(now: @clock.call)
        cutoff = now - NAME_HISTORY_RETENTION
        @models.observed_identity_name
               .exclude(ended_at: nil)
               .where(Sequel[:ended_at] < cutoff)
               .delete
      end

      private

      # The unordered dataset behind both #search and #recent: a community's rows
      # whose handle or display name contains +query+, case-insensitively.
      def matching(community_id:, query:)
        # Escaped and lowered, so a searcher typing a percent gets no results
        # rather than the whole directory.
        pattern = Util::LikePattern.contains(query.downcase)
        @models.observed_identity
               .where(community_id: community_id)
               .where(Sequel.|(
                 Util::LikePattern.like_lower(:username, pattern),
                 Util::LikePattern.like_lower(:display_name, pattern)
               ))
      end

      # The observed handles containing +fragment+ on one platform. The
      # complete result is intentional: a second match is enough to refuse a
      # ping, and the acknowledgement names every candidate the author can
      # narrow between.
      def matching_handles(community_id:, adapter:, fragment:)
        pattern = Util::LikePattern.contains(fragment.downcase)
        @models.observed_identity
               .where(community_id: community_id, adapter: adapter.to_s)
               .where(Util::LikePattern.like_lower(:username, pattern))
               .order(:username, :native_id)
               .all
      end

      # Apply a sighting to an existing row: refresh the handle/display when they
      # changed and always advance last_seen_at, which the retention window reads.
      # A real change closes out the open history row and opens a fresh one,
      # instead of overwriting it, when identity_history is on for the community
      # (off leaves observed_identities itself exactly as it always has been).
      def touch(row, handle, name, now)
        changes = { last_seen_at: now }
        changes[:username] = handle if !handle.nil? && handle != row.username
        changes[:display_name] = name if !name.nil? && name != row.display_name
        renamed = changes.key?(:username) || changes.key?(:display_name)

        row.update(changes)

        if renamed && identity_history_on?(row.community_id)
          close_open_name_history(row, now)
          open_name_history(row, now)
        end
        row
      end

      # Opens a new observed_identity_names row reflecting +row+'s CURRENT
      # username/display_name, called right after +row+ is created or updated.
      def open_name_history(row, at)
        @models.observed_identity_name.create(
          community_id: row.community_id, adapter: row.adapter, native_id: row.native_id,
          username: row.username, display_name: row.display_name, started_at: at
        )
      end

      # Closes whichever observed_identity_names row is still open for +row+'s
      # (community, adapter, native_id), if any. A no-op the first time history
      # is kept for an identity, since nothing is open yet to close.
      def close_open_name_history(row, at)
        @models.observed_identity_name
               .where(community_id: row.community_id, adapter: row.adapter, native_id: row.native_id, ended_at: nil)
               .update(ended_at: at)
      end

      # identity_history is a community-wide flag (Features::IdentityHistory),
      # read the same way EventPolicy#room_policy reads a feature outside the
      # pipeline: straight off feature_settings, since IdentityDirectory has no
      # live Snapshot to ask and observed_identities is written for every
      # community whether or not a control plane exists at all.
      def identity_history_on?(community_id)
        row = @models.feature_setting
                     .where(community_id: community_id, feature: Features::IdentityHistory.feature_name, room_id: nil)
                     .first
        return Features::IdentityHistory.default_enabled? if row.nil?

        to_bool(row.enabled)
      end

      # SQLite returns booleans as 0/1 through some Sequel paths, so normalise
      # rather than trusting the raw value (0 is truthy in Ruby).
      def to_bool(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end

      def normalise_handle(value)
        handle = presence(value)
        handle&.sub(/\A@/, "")&.downcase
      end

      # Whether +needle+ (already downcased) collides with +name+, one half of
      # {#handle_collision?}'s check.
      def name_collides?(needle, name)
        handle = presence(name)&.downcase
        return false if handle.nil?
        return true if handle == needle
        return true if handle.length >= MIN_DISTINCTIVE_LENGTH && needle.include?(handle)
        return true if needle.length >= MIN_DISTINCTIVE_LENGTH && handle.include?(needle)

        false
      end

      # The native id on +adapter+ of whoever holds +handle+ as a bridged
      # nickname in this community, or nil. Ambiguity resolves to nil the same way
      # a shared handle does.
      def nickname_native_id(community_id:, adapter:, handle:)
        person_id = BridgedNicknames.new(models: @models)
                                    .person_id_for(community_id: community_id, nickname: handle)
        return nil if person_id.nil?

        ids = @models.person_identity
                     .where(person_id: person_id, adapter: adapter.to_s)
                     .select_map(:native_id).compact.uniq
        ids.size == 1 ? ids.first : nil
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
