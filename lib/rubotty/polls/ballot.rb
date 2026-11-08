# frozen_string_literal: true

module Rubotty
  module Polls
    # The write side of poll_votes, shared by both capture surfaces so the
    # single-select rule lives in one place, and the read back a card renders
    # from, which the identity directory fills the gaps in.
    class Ballot
      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#debug, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
        @identities = ControlPlane::IdentityDirectory.new(models: models)
      end

      # Record +identity+'s vote for one option.
      #
      # @param identity [String] a platform native id, or a handle where the
      #   platform supplies no id
      # @param handle [String, nil] the name the vote is displayed under
      # @return [Boolean] whether anything actually changed
      def record(poll:, option:, identity:, platform:, handle: nil)
        clean = identity.to_s
        return false if clean.empty?

        with_poll_lock(poll) do |current|
          withdraw_others(current, option, clean) unless current.multi_select?
          row = find_row(current, option, clean)
          if row
            row.update(platform: platform.to_s, handle: presence(handle))
            next false
          end

          @models.poll_vote.create(
            poll_id: current.id, option_id: option.id, identity: clean,
            platform: platform.to_s, handle: presence(handle), voted_at: @clock.call
          )
          true
        end
      end

      # Does +identity+ already back this option? A shared button says only
      # which option was pressed, so this is what tells the two apart there.
      #
      # @return [Boolean]
      def holds?(poll:, option:, identity:)
        clean = identity.to_s
        return false if clean.empty?

        !find_row(poll, option, clean).nil?
      end

      # @return [Boolean] whether a row was actually removed
      def clear(poll:, option:, identity:)
        with_poll_lock(poll) do |current|
          @models.poll_vote.where(poll_id: current.id, option_id: option.id, identity: identity.to_s)
                 .delete.positive?
        end
      end

      # Every vote on +poll+ grouped by option id, oldest first within an
      # option, so the three names a card shows are the three who answered first.
      #
      # @param poll [Polls::Poll]
      # @return [Hash{Integer=>Array<Core::VoteRoster::Voter>}]
      def by_option(poll)
        rows = @models.poll_vote.where(poll_id: poll.id).order(:voted_at, :id).all
        names = directory_names(poll, rows)
        rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, out|
          out[row.option_id] << Core::VoteRoster::Voter.new(
            identity: row.identity, platform: row.platform, handle: row.handle,
            name: names[[row.platform, row.identity]]
          )
        end
      rescue StandardError => e
        @logger&.warn { "polls: could not read the votes for poll #{poll.id}: #{e.message}" }
        {}
      end

      private

      # Lock the poll even before this voter has a row. SQLite needs the write
      # transaction up front; SELECT FOR UPDATE provides that gate elsewhere.
      def with_poll_lock(poll)
        options = @models.db.database_type == :sqlite ? { mode: :immediate } : {}
        @models.db.transaction(**options) do
          row = @models.poll.where(id: poll.id).for_update.first
          next false unless row && row.status == Poll::STATUS_OPEN

          yield Poll.new(row)
        end
      end

      # The directory's name for each voter whose platform gave no handle to
      # store, looked up for those rows alone so a room of handles costs nothing.
      #
      # @return [Hash{Array(String,String)=>String}] keyed by platform and identity
      def directory_names(poll, rows)
        nameless = rows.reject { |row| presence(row.handle) }
        return {} if nameless.empty?

        nameless.each_with_object({}) do |row, out|
          key = [row.platform, row.identity]
          next if out.key?(key)

          entry = @identities.entry(community_id: poll.community_id, adapter: row.platform,
                                    native_id: row.identity)
          out[key] = entry && entry[:display_name]
        end
      rescue StandardError => e
        @logger&.warn { "polls: could not read the directory for poll #{poll.id}: #{e.message}" }
        {}
      end

      def withdraw_others(poll, option, identity)
        @models.poll_vote
              .where(poll_id: poll.id, identity: identity)
              .exclude(option_id: option.id)
              .delete
      end

      def find_row(poll, option, identity)
        @models.poll_vote.where(poll_id: poll.id, option_id: option.id, identity: identity).first
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
