# frozen_string_literal: true

module Rubotty
  module Adapters
    module Discord
      # The answer to "which text channels does this guild have?".
      #
      # A guild with no text channels and a guild the bot could not read look the same
      # as a bare array, and the auto-leave path treats those channel ids as the guild's
      # identity: they are how a seeded connection's sentinel is resolved. An unreadable
      # guild handed over as an empty array therefore reads as a stranger and gets left,
      # which is irreversible from here. So the two answers travel separately, from the
      # gateway call all the way to the join guard.
      ChannelListing = Struct.new(:channels, :listed, :reason, keyword_init: true) do
        # The enumeration ran, and these are the channels it found, however few.
        def self.listed(channels)
          new(channels: Array(channels), listed: true, reason: nil)
        end

        # The enumeration did not run, so this guild's channels are unknown.
        def self.unavailable(reason)
          new(channels: [], listed: false, reason: reason.to_s)
        end

        def listed? = listed ? true : false

        def unavailable? = !listed?

        def channel_ids = channels.map { |channel| channel[:id] }

        def channel_names = channels.filter_map { |channel| channel[:name] }
      end
    end
  end
end
