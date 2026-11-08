# frozen_string_literal: true

module Rubotty
  # Resolves the version this build reports.
  #
  # scripts/resolve-version.sh runs during the railpack build step, resolves
  # the nearest reachable git tag and bakes it into RESOLVED_FILE, since the
  # deploy image carries no .git for this to shell out to at runtime instead.
  # No PR needs to touch this file: FALLBACK only moves when a release is cut.
  module VersionResolution
    RESOLVED_FILE = File.expand_path("resolved_version.txt", __dir__)

    # Honest about being unresolved, so a checkout with no baked file (a gem
    # install, a plain clone, a shallow CI checkout) reports that plainly
    # rather than a specific patch nobody actually released.
    FALLBACK = "0.8.3-unresolved"

    def self.resolve(path = RESOLVED_FILE)
      baked = File.exist?(path) ? File.read(path, encoding: "UTF-8").strip : ""
      baked.empty? ? FALLBACK : baked
    end
  end

  VERSION = VersionResolution.resolve

  # Identity of the software itself, independent of the deployment running it.
  # Hardcoded rather than derived, so a fork rebrands as a deliberate act
  # instead of the banner reporting whatever the build machine was configured as.
  SERVICE_NAME = "rubotty"
end
