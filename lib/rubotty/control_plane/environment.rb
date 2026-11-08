# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Which deployment environment this process is running in, read from the
    # ENVIRONMENT var. Gates whether config/protected_communities.yml is loaded at
    # all, so a local database is never seeded with real production ids.
    #
    # Whitespace is stripped and comparison ignores case. Unset, blank or
    # any value other than PRODUCTION after normalization means development,
    # so protected production communities are not loaded locally.
    module Environment
      PRODUCTION = "PRODUCTION"

      def self.production?(env = ENV)
        env["ENVIRONMENT"].to_s.strip.upcase == PRODUCTION
      end
    end
  end
end
