# frozen_string_literal: true

require "tzinfo"

module Rubotty
  module ControlPlane
    # Reads a country flag emoji out of a name and guesses the single
    # timezone it most plausibly means, for {TimezoneInference}. A country
    # whose flag cannot honestly imply ONE timezone is left OUT of
    # {SINGLE_ZONE} on purpose, so {.timezone_for} answers nil rather than
    # guessing "most populous zone": the zone feeds a real wall-clock
    # conversion, so a wrong guess is an event at the wrong hour. A country
    # mapped single-zone despite a differing outlying territory (Azores,
    # Canaries) is still fine; a genuinely split country is left out.
    module CountryFlagTimezone
      REGIONAL_INDICATOR_BASE = 0x1F1E6 # the codepoint for 🇦
      FLAG = /[\u{1F1E6}-\u{1F1FF}]{2}/

      # Known multi-zone countries, explicit and deliberately unmapped (see
      # the module doc above). Not consulted directly by
      # {.timezone_for}, which already answers nil for anything outside
      # {SINGLE_ZONE}; this exists so a spec (and a reader) can assert the
      # omission was a choice.
      MULTI_ZONE = %w[US RU CA AU BR MX ID KZ CD CL EC].freeze

      # ISO 3166-1 alpha-2 code => the one IANA zone that flag stands in for.
      SINGLE_ZONE = {
        # Europe
        "PT" => "Europe/Lisbon", "ES" => "Europe/Madrid", "FR" => "Europe/Paris",
        "DE" => "Europe/Berlin", "IT" => "Europe/Rome", "GB" => "Europe/London",
        "IE" => "Europe/Dublin", "NL" => "Europe/Amsterdam", "BE" => "Europe/Brussels",
        "CH" => "Europe/Zurich", "AT" => "Europe/Vienna", "SE" => "Europe/Stockholm",
        "NO" => "Europe/Oslo", "DK" => "Europe/Copenhagen", "FI" => "Europe/Helsinki",
        "PL" => "Europe/Warsaw", "CZ" => "Europe/Prague", "SK" => "Europe/Bratislava",
        "HU" => "Europe/Budapest", "RO" => "Europe/Bucharest", "BG" => "Europe/Sofia",
        "GR" => "Europe/Athens", "HR" => "Europe/Zagreb", "SI" => "Europe/Ljubljana",
        "EE" => "Europe/Tallinn", "LV" => "Europe/Riga", "LT" => "Europe/Vilnius",
        "IS" => "Atlantic/Reykjavik", "LU" => "Europe/Luxembourg", "MT" => "Europe/Malta",
        "CY" => "Asia/Nicosia", "UA" => "Europe/Kyiv", "RS" => "Europe/Belgrade",
        "AL" => "Europe/Tirane", "MK" => "Europe/Skopje", "BA" => "Europe/Sarajevo",
        "ME" => "Europe/Podgorica", "MD" => "Europe/Chisinau", "BY" => "Europe/Minsk",
        "AD" => "Europe/Andorra", "MC" => "Europe/Monaco", "SM" => "Europe/San_Marino",
        "VA" => "Europe/Vatican", "LI" => "Europe/Vaduz",

        # Asia and the Middle East
        "CN" => "Asia/Shanghai", "JP" => "Asia/Tokyo", "KR" => "Asia/Seoul",
        "KP" => "Asia/Pyongyang", "IN" => "Asia/Kolkata", "VN" => "Asia/Ho_Chi_Minh",
        "TH" => "Asia/Bangkok", "PH" => "Asia/Manila", "SG" => "Asia/Singapore",
        "MY" => "Asia/Kuala_Lumpur", "TW" => "Asia/Taipei", "HK" => "Asia/Hong_Kong",
        "IL" => "Asia/Jerusalem", "TR" => "Europe/Istanbul", "SA" => "Asia/Riyadh",
        "AE" => "Asia/Dubai", "QA" => "Asia/Qatar", "PK" => "Asia/Karachi",
        "BD" => "Asia/Dhaka", "LK" => "Asia/Colombo", "NP" => "Asia/Kathmandu",
        "MM" => "Asia/Yangon", "KH" => "Asia/Phnom_Penh", "LA" => "Asia/Vientiane",
        "KW" => "Asia/Kuwait", "BH" => "Asia/Bahrain", "OM" => "Asia/Muscat",
        "JO" => "Asia/Amman", "LB" => "Asia/Beirut", "IQ" => "Asia/Baghdad",
        "IR" => "Asia/Tehran", "AM" => "Asia/Yerevan", "AZ" => "Asia/Baku",
        "GE" => "Asia/Tbilisi", "MN" => "Asia/Ulaanbaatar",

        # Africa
        "EG" => "Africa/Cairo", "ZA" => "Africa/Johannesburg", "NG" => "Africa/Lagos",
        "KE" => "Africa/Nairobi", "MA" => "Africa/Casablanca", "DZ" => "Africa/Algiers",
        "TN" => "Africa/Tunis", "GH" => "Africa/Accra", "ET" => "Africa/Addis_Ababa",
        "TZ" => "Africa/Dar_es_Salaam", "UG" => "Africa/Kampala", "SN" => "Africa/Dakar",
        "ZW" => "Africa/Harare", "ZM" => "Africa/Lusaka", "NA" => "Africa/Windhoek",

        # Oceania
        "NZ" => "Pacific/Auckland", "FJ" => "Pacific/Fiji", "PG" => "Pacific/Port_Moresby",

        # The Americas
        "AR" => "America/Argentina/Buenos_Aires", "CO" => "America/Bogota",
        "PE" => "America/Lima", "VE" => "America/Caracas", "BO" => "America/La_Paz",
        "PY" => "America/Asuncion", "UY" => "America/Montevideo", "GT" => "America/Guatemala",
        "CR" => "America/Costa_Rica", "PA" => "America/Panama", "CU" => "America/Havana",
        "DO" => "America/Santo_Domingo", "JM" => "America/Jamaica", "HN" => "America/Tegucigalpa",
        "NI" => "America/Managua", "SV" => "America/El_Salvador"
      }.freeze

      module_function

      # The ISO 3166-1 alpha-2 code the FIRST flag emoji in +text+ encodes,
      # or nil when it holds none. Pure codepoint arithmetic: a flag is
      # always two consecutive Unicode regional indicator symbols, each one
      # standing in for the Latin letter at the same offset from 'A' as it
      # sits from U+1F1E6, so this needs no lookup table of its own.
      def extract_country_code(text)
        match = FLAG.match(text.to_s)
        return nil unless match

        match[0].codepoints.map { |cp| (cp - REGIONAL_INDICATOR_BASE + "A".ord).chr }.join
      end

      # The single IANA zone +country_code+'s flag stands in for, or nil for
      # a code this module does not carry a single-zone answer for (unmapped,
      # or a deliberate {MULTI_ZONE} entry). Defensive the way every other
      # zone lookup in this codebase is (see Features::TimestampExpansion):
      # validated against TZInfo before it is trusted, so a typo in
      # {SINGLE_ZONE} degrades to "no answer" rather than raising at
      # someone's /event.
      def timezone_for(country_code)
        code = country_code.to_s.strip.upcase
        zone = SINGLE_ZONE[code]
        return nil if zone.nil?

        TZInfo::Timezone.get(zone)
        zone
      rescue TZInfo::InvalidTimezoneIdentifier
        nil
      end

      # The zone the first flag emoji found in +text+ implies, or nil when
      # +text+ carries no flag, or a flag {.timezone_for} has no single-zone
      # answer for. The one call most callers actually want.
      def infer(text)
        code = extract_country_code(text)
        return nil if code.nil?

        timezone_for(code)
      end
    end
  end
end
