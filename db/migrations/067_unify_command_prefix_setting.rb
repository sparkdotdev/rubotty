# frozen_string_literal: true

require "json"

# Folds the seven per-feature `prefixes`/`prefix` copies into one "commands"
# feature_settings row per (community, room) scope, matching what
# Core::CommandPrefix::CONFIG_FEATURE reads. A scope with more than one legacy
# value picks the first found below; an untouched default is dropped, not kept.
Sequel.migration do
  up do
    legacy_features = %w[utility_commands faq keyword_watch operator_requests nickname redirection warnings]
    default_prefixes = ["/", "!"].freeze

    rows = self[:feature_settings].where(feature: legacy_features)
                                  .select(:id, :community_id, :room_id, :feature, :config).all

    rows.group_by { |row| [row[:community_id], row[:room_id]] }.each do |(community_id, room_id), group|
      ordered = legacy_features.filter_map { |name| group.find { |row| row[:feature] == name } }
      migrated = nil

      ordered.each do |row|
        config = JSON.parse(row[:config].to_s.empty? ? "{}" : row[:config])
        prefixes = config["prefixes"]
        prefix = config["prefix"]
        next if prefixes.nil? && (prefix.nil? || prefix.to_s.empty?)
        next if (prefixes.nil? || prefixes == default_prefixes) && (prefix.nil? || prefix.to_s.empty?)

        migrated = {}
        migrated["prefixes"] = prefixes unless prefixes.nil?
        migrated["prefix"] = prefix unless prefix.nil? || prefix.to_s.empty?
        break
      end

      next if migrated.nil?

      existing = self[:feature_settings]
                 .where(community_id: community_id, room_id: room_id, feature: "commands").first
      now = Time.now
      if existing
        current = JSON.parse(existing[:config].to_s.empty? ? "{}" : existing[:config])
        self[:feature_settings].where(id: existing[:id])
                               .update(config: JSON.generate(migrated.merge(current)), updated_at: now)
      else
        self[:feature_settings].insert(
          community_id: community_id, room_id: room_id, feature: "commands",
          enabled: true, config: JSON.generate(migrated), created_at: now, updated_at: now
        )
      end
    end

    self[:feature_settings].where(feature: legacy_features).each do |row|
      config = JSON.parse(row[:config].to_s.empty? ? "{}" : row[:config])
      next unless config.key?("prefixes") || config.key?("prefix")

      config.delete("prefixes")
      config.delete("prefix")
      self[:feature_settings].where(id: row[:id]).update(config: JSON.generate(config), updated_at: Time.now)
    end
  end

  down do
    # Not reversed: the seven-copy shape this replaces is the bug, and nothing
    # in the retired fields is worth resurrecting on a rollback.
  end
end
