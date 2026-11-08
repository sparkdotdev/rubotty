# frozen_string_literal: true

require "tzinfo"

module Rubotty
  module ControlPlane
    # Which timezone anchors a bare wall-clock start time ("tomorrow 4pm")
    # when /event's own tz= argument is blank. First answer wins: an
    # explicit tz=, a country flag emoji in the guild nickname, one in the
    # global display name, the room's own Bridge#timestamp_timezones first
    # zone, then UTC. A flag whose country has no single answer (unmapped, or
    # deliberately multi-zone) falls through to the next source rather than
    # stopping the chain on a guess.
    module TimezoneInference
      module_function

      # Every real IANA identifier indexed by its own city segment, lowercased
      # and underscore-free, so a person can type "lisbon" or "new york"
      # instead of the formal Area/City form. DST is whatever the resolved
      # zone itself observes; nothing here decides that separately.
      CITY_INDEX = TZInfo::Timezone.all_identifiers.each_with_object({}) do |id, index|
        index[id.split("/").last.tr("_", " ").downcase] = id
      end.freeze

      # Major cities with no IANA segment of their own, so typing the city a
      # person actually lives in still resolves. Not exhaustive: a city
      # already named in the IANA database (Lisbon, Tokyo, London, ...) is
      # found directly by {CITY_INDEX} and never needs an entry here. Add to
      # this as a real gap turns up rather than trying to enumerate every
      # city up front.
      CITY_ALIASES = {
        "miami" => "America/New_York",
        "orlando" => "America/New_York",
        "tampa" => "America/New_York",
        "atlanta" => "America/New_York",
        "boston" => "America/New_York",
        "philadelphia" => "America/New_York",
        "washington" => "America/New_York",
        "washington dc" => "America/New_York",
        "houston" => "America/Chicago",
        "dallas" => "America/Chicago",
        "austin" => "America/Chicago",
        "san antonio" => "America/Chicago",
        "seattle" => "America/Los_Angeles",
        "portland" => "America/Los_Angeles",
        "san diego" => "America/Los_Angeles",
        "las vegas" => "America/Los_Angeles"
      }.freeze

      # @param explicit [String, nil] the tz= a person typed, if any
      # @param nickname [String, nil] the poster's per-space/guild nickname
      # @param display_name [String, nil] the poster's platform display name
      # @param community_default [String, nil] the room or community's own
      #   first configured Bridge#timestamp_timezones zone, already resolved
      #   by the caller (this module stays platform- and control-plane-free)
      # @return [String] a real IANA zone identifier, always: UTC when
      #   nothing else in the chain answers
      def resolve(explicit: nil, nickname: nil, display_name: nil, community_default: nil)
        explicit_zone(explicit) ||
          CountryFlagTimezone.infer(nickname) ||
          CountryFlagTimezone.infer(display_name) ||
          valid_zone(community_default) ||
          "UTC"
      end

      # @api private
      # A person's own tz= is read more loosely than a stored default: the
      # formal Area/City form first, then a bare city name either way it is
      # spelled (an IANA segment directly, or a known alias).
      def explicit_zone(candidate)
        text = candidate.to_s.strip
        return nil if text.empty?

        valid_zone(text) || by_city_name(text)
      end

      # @api private
      def by_city_name(text)
        key = text.downcase.tr("_", " ")
        CITY_INDEX[key] || CITY_ALIASES[key]
      end

      # @api private
      # +candidate+ if it is a non-blank, real IANA identifier, else nil:
      # neither an explicit tz= nor a room default is trusted blind, the
      # same defensive posture {Features::TimestampExpansion} takes on a
      # configured zone.
      def valid_zone(candidate)
        text = candidate.to_s.strip
        return nil if text.empty?

        TZInfo::Timezone.get(text)
        text
      rescue TZInfo::InvalidTimezoneIdentifier
        nil
      end
    end
  end
end
