# frozen_string_literal: true

module Rubotty
  module Features
    # Declaration only: the paced resync runs as a boot-time sweep in
    # Core::Backfill, so #call never runs. Registering it here gives operators the
    # enable toggle and a schema whose defaults must match Core::Backfill::DEFAULTS.
    class Backfill < Base
      def self.feature_name = "backfill"

      def self.description =
        "Replays what a platform received while the bot was down, on the platforms that can be asked. " \
        "Turning it off means a restart or a deploy silently loses whatever was posted in the meantime."

      # On, because off is unrecoverable and nothing announces the loss. The
      # sweep starts at the last relay from the channel, so a channel just mapped
      # into a room replays nothing.
      def self.default_enabled? = true

      def self.config_schema
        Config::Schema.define do
          # How far back to look for missed activity. Independent of the horizon
          # below: raising this past it widens what a gap report can see but not
          # what actually gets relayed.
          field :lookback_seconds, :integer, default: 259_200,
                                              desc: "how far back to check for missed activity, in seconds"
          # Milliseconds between two sends to ONE destination, counted per
          # destination because that is what a platform rate limits.
          field :interval_ms, :integer, default: 1_000,
                                        desc: "milliseconds between two sends to any one destination. " \
                                              "A message fans out to every platform in the room, so the " \
                                              "sweep waits for the slowest of them"
          # Ceiling on what a destination's own retry_after may slow it to. A
          # platform asking for an hour would otherwise pin a sweep all day.
          field :max_interval_ms, :integer,
                default: Core::RelayOutcomes::Pacer::DEFAULT_MAX_INTERVAL_MS,
                desc: "the slowest a destination may pace itself, in milliseconds. A platform that answers " \
                      "with a retry_after sets the rate for the rest of the sweep, held at this"
          # Never relay anything older than this; must stay under the claim TTL,
          # with margin, or a re-fed message at the edge of the window can lose its
          # dedup claim before the sweep re-reads it. Enforced by
          # ControlPlane::FeatureControls when this is set.
          field :safe_horizon_seconds, :integer, default: 259_200,
                                                  desc: "never relay anything older than this, in seconds. " \
                                                        "Must stay comfortably under behaviour.relay_claim_ttl"
          # Cap on messages relayed per channel; the rest of a long gap is logged unsynced.
          field :max_messages, :integer, default: 1_000
          # Cap on messages fetched per channel; bounds REST cost on a busy one.
          field :max_fetch, :integer, default: 2_000
          # Cap on reactions relayed per channel, paced on the same budget as a message.
          field :max_reactions, :integer, default: 100
          # How big a gap the sweep may relay on its own. Past it the sweep
          # writes a proposal and sends nothing until somebody accepts it.
          field :auto_relay_limit, :integer,
                default: ControlPlane::BackfillProposals::AUTO_RELAY_LIMIT,
                desc: "how many missing messages the sweep may restore without asking. " \
                      "Anything past this waits on the Backfill proposals page; 0 holds every restore"
        end
      end

      # Shown on the dashboard page where an operator sets the limit above.
      def self.retention_notice
        "A gap past auto_relay_limit is written down instead of sent, and what is written down includes a " \
          "#{ControlPlane::BackfillProposals::PREVIEW_LIMIT} character preview of each message, so whoever " \
          "decides can see what would go out. Those previews are the only chat text this feature keeps, they " \
          "sit in backfill_proposal_items, and they are deleted as soon as the proposal stops needing them: " \
          "when it is rejected, when the next sweep replaces it, once an accepted list has actually been " \
          "relayed, and in any case within " \
          "#{ControlPlane::BackfillProposals::DEFAULT_TTL_SECONDS / 3600} hours, when it expires. Raising " \
          "auto_relay_limit keeps less and reviews less; PRIVACY.md sets out the rest."
      end
    end
  end
end
