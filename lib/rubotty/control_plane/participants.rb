# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # Who somebody is, as a script may know them. `person:42` names a human
    # linked in the people registry and is stable across platforms and
    # renames; `telegram:12345` names one unlinked platform account, survives
    # a rename but does not follow that person elsewhere since nothing here
    # has been told they are the same. Accounts stay unlinked until the
    # registry says otherwise, since passive observation cannot safely guess
    # it, and {#resolve} refuses to pick between two matching people rather
    # than credit the wrong one silently.
    class Participants
      # A person or an account, as a script sees one.
      Participant = Data.define(:id, :display, :platform)

      # One platform account behind a participant, which is what it takes to
      # ping them or open a chat with them.
      Identity = Data.define(:adapter, :native_id, :username, :display)

      # The prefix that marks an id as naming a linked person rather than one
      # account. No adapter is called this, so an id can be read either way
      # round without ambiguity.
      PERSON = "person"

      # How many candidates a name is matched against before the answer is
      # "too many to be sure". A name matching more than this is ambiguous by
      # any reading, so the query is bounded rather than the community.
      MATCH_LIMIT = 50

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param directory [IdentityDirectory] the passively learned sightings,
      #   reused rather than re-queried here so "who has this community seen"
      #   has one answer and one LIKE clause
      def initialize(models:, directory: nil)
        @models = models
        @directory = directory || IdentityDirectory.new(models: models)
      end

      # The participant behind one platform account, or nil when there is not
      # enough to key on.
      #
      # @param display [String, nil] what the room calls them right now, which
      #   the caller already has and this will not spend a query on
      def describe(community_id:, adapter:, native_id:, display: nil)
        adapter = adapter.to_s
        native_id = presence(native_id)
        return nil if community_id.nil? || adapter.empty? || native_id.nil?

        linked = people_index(community_id)[:by_account][[adapter, native_id]]
        Participant.new(
          id: linked ? "#{PERSON}:#{linked[:person_id]}" : "#{adapter}:#{native_id}",
          display: presence(display) || linked&.fetch(:name, nil) || native_id,
          platform: adapter
        )
      end

      # The one participant a name names, or nil when it names nobody, or more
      # than one. An exact match on a handle or display name settles it
      # outright; only when nothing matches exactly does a substring match
      # count, and even then only if it is the sole one.
      def resolve(community_id:, name:)
        needle = presence(name)&.delete_prefix("@")
        return nil if community_id.nil? || needle.nil?

        candidates, truncated = candidates_for(community_id, needle)
        return nil if truncated || candidates.empty?

        exact = candidates.select { |candidate| candidate[:exact] }
        sole(exact.empty? ? candidates : exact)
      end

      # Every platform account behind a participant id, in this community.
      # Fails closed: an id naming a person in another community, or an
      # account this community has never seen, returns nothing rather than
      # guessing, since the id came from a script that may have made it up or
      # outlived the room it named.
      def identities(community_id:, id:)
        kind, rest = split_id(id)
        return [] if community_id.nil? || rest.nil?

        kind == PERSON ? person_identities(community_id, rest) : account_identity(community_id, kind, rest)
      end

      private

      # The rows a name could mean, each already reduced to the participant it
      # belongs to, so the caller only has to count distinct ids. Fetches one
      # past {MATCH_LIMIT} so a name with more sightings than that can be told
      # apart from one that happens to have exactly the limit, and reports
      # that as truncated rather than silently handing back a partial list.
      #
      # @return [Array(Array<Hash>, Boolean)] the candidates, and whether the
      #   sighting search was truncated
      def candidates_for(community_id, needle)
        lowered = needle.downcase
        index = people_index(community_id)
        sightings = @directory.search(community_id: community_id, query: needle, limit: MATCH_LIMIT + 1)
        truncated = sightings.size > MATCH_LIMIT
        sightings = sightings.first(MATCH_LIMIT) if truncated
        found = sightings.map { |row| from_sighting(row, lowered, index) }
        [found + matching_people(community_id, lowered, index), truncated]
      end

      def from_sighting(row, lowered, index)
        linked = index[:by_account][[row.adapter.to_s, row.native_id.to_s]]
        display = presence(row.display_name) || presence(row.username) || row.native_id.to_s
        {
          id: linked ? "#{PERSON}:#{linked[:person_id]}" : "#{row.adapter}:#{row.native_id}",
          display: linked&.fetch(:name, nil) || display,
          platform: row.adapter.to_s,
          exact: row.username.to_s.downcase == lowered || row.display_name.to_s.downcase == lowered
        }
      end

      # People whose registry NAME matches, which a sighting cannot answer for:
      # the registry is where a human is called what an operator called them,
      # rather than what they called themselves on one platform.
      def matching_people(community_id, lowered, index)
        index[:people].filter_map do |person|
          name = person[:name].to_s.downcase
          next unless name.include?(lowered)

          { id: "#{PERSON}:#{person[:person_id]}", display: person[:name],
            platform: person[:platform].to_s, exact: name == lowered }
        end
      end

      # One participant, or nil when the candidates disagree about who is meant.
      def sole(candidates)
        ids = candidates.map { |candidate| candidate[:id] }.uniq
        return nil unless ids.size == 1

        chosen = candidates.first
        Participant.new(id: chosen[:id], display: chosen[:display], platform: chosen[:platform])
      end

      # This community's linked people, indexed both ways round, in one query
      # each. Read per call rather than cached: a link made in the dashboard
      # has to take effect on the next message, not on the next restart, and
      # this is the registry rather than the sightings table, so it is small.
      def people_index(community_id)
        rows = @models.person.where(community_id: community_id).order(:id).all
        accounts = {}
        people = []
        return { by_account: accounts, people: people } if rows.empty?

        names = rows.to_h { |row| [row.id, row.name.to_s] }
        @models.person_identity.where(person_id: names.keys).order(:id).each do |identity|
          entry = { person_id: identity.person_id, name: names[identity.person_id] }
          accounts[[identity.adapter.to_s, identity.native_id.to_s]] = entry
          people << entry.merge(platform: identity.adapter.to_s)
        end
        # A person with no identity linked yet is still somebody an operator can
        # name, so they belong in the list even though nothing can ping them.
        named = people.map { |person| person[:person_id] }.uniq
        names.each { |id, name| people << { person_id: id, name: name, platform: "" } unless named.include?(id) }
        { by_account: accounts, people: people }
      end

      def person_identities(community_id, person_id)
        id = Integer(person_id, exception: false)
        return [] if id.nil?
        return [] unless @models.person.where(id: id, community_id: community_id).first

        @models.person_identity.where(person_id: id).order(:id).filter_map do |row|
          native_id = presence(row.native_id)
          next if native_id.nil?

          Identity.new(adapter: row.adapter.to_s, native_id: native_id,
                       username: presence(row.username), display: nil)
        end
      end

      # One unlinked account, and only where this community has actually seen
      # it. The sighting is the proof that the id names somebody here rather
      # than somebody a script named.
      def account_identity(community_id, adapter, native_id)
        row = @directory.entry(community_id: community_id, adapter: adapter, native_id: native_id)
        return [] if row.nil?

        [Identity.new(adapter: row.adapter.to_s, native_id: row.native_id.to_s,
                      username: presence(row.username), display: presence(row.display_name))]
      end

      # "person:42" and "telegram:12345" both read as (kind, rest). Split once,
      # so a Matrix native id, which carries a colon of its own, survives.
      def split_id(id)
        kind, rest = id.to_s.split(":", 2)
        [kind.to_s, presence(rest)]
      end

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
