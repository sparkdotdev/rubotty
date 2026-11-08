# frozen_string_literal: true

require "yamlcamel"

module Rubotty
  module ControlPlane
    # Connection half of config/protected_communities.yml, the source of
    # truth for the protected communities' identity and the title patterns
    # {ProtectedCommunities} matches on. Reads `communities:` and reconciles
    # into the DB on every boot, creating a missing community and upserting
    # each connection, so DB drift from the YAML self-heals on restart.
    # Deliberately minimal, creating only a community and its connections,
    # never rooms or channels: identity and liveness are locked down in
    # PlatformConnections#update_identity and the start/stop guard instead.
    class ProtectedCommunityConnections
      DEFAULT_PATH = File.expand_path("../../../config/protected_communities.yml", __dir__)

      def self.reconcile!(models:, path: ENV.fetch("RUBOTTY_PROTECTED_COMMUNITIES_FILE", DEFAULT_PATH), logger: nil, clock: -> { Time.now })
        new(models: models, path: path, logger: logger, clock: clock).run
      end

      def initialize(models:, path: ENV.fetch("RUBOTTY_PROTECTED_COMMUNITIES_FILE", DEFAULT_PATH), logger: nil, clock: -> { Time.now })
        @models = models
        @path = path
        @logger = logger
        @clock = clock
      end

      def run
        entries.each { |entry| reconcile_entry(entry) }
      end

      private

      def entries
        return [] unless @path && File.file?(@path)

        parsed = YAMLCamel.load(File.read(@path, encoding: "UTF-8"))
        Array(parsed && parsed["communities"])
      rescue StandardError => e
        @logger&.warn { "protected community connections: could not read #{@path}: #{e.message}" }
        []
      end

      def reconcile_entry(entry)
        slug = entry["slug"].to_s
        return if slug.empty?

        now = @clock.call
        community = upsert_community(slug, entry["name"].to_s, now)
        Array(entry["connections"]).each { |conn| upsert_connection(community, conn, now) }
      rescue StandardError => e
        @logger&.warn { "protected community connections: could not reconcile #{entry["slug"].inspect}: #{e.message}" }
      end

      def upsert_community(slug, name, now)
        existing = @models.community.where(slug: slug).first
        return existing if existing

        @logger&.info { "protected community connections: creating #{slug.inspect}" }
        @models.community.create(
          slug: slug, name: name.empty? ? slug : name, status: "active", settings: "{}",
          bootstrap_source: "config/protected_communities.yml", created_at: now, updated_at: now
        )
      end

      def upsert_connection(community, conn, now)
        adapter = conn["adapter"].to_s
        account = conn["account"].to_s
        external_id = conn["external_id"].to_s
        return if adapter.empty? || account.empty? || external_id.empty?

        existing = @models.platform_connection
                          .where(adapter: adapter, account: account, external_id: external_id).first
        if existing
          existing.update(community_id: community.id, label: conn["label"], updated_at: now)
        else
          @logger&.info do
            "protected community connections: connecting #{adapter}/#{account}/#{external_id} to #{community.slug}"
          end
          @models.platform_connection.create(
            community_id: community.id, adapter: adapter, account: account, external_id: external_id,
            label: conn["label"], created_at: now, updated_at: now
          )
        end
      end
    end
  end
end
