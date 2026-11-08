# frozen_string_literal: true

require "json"

# Three command features kept their acknowledgement window under a bespoke
# `ack_delete_after` key rather than the shared `ack_ttl_seconds` Core::CommandAck
# owns, so the dashboard could not edit them under the same key as everything else.

# The value moves rather than being dropped, since a scope that configured a
# window should keep it instead of quietly falling back to the default. A "5m"
# spelling is written out as seconds, which is all the shared reader takes, and a
# value nothing could read is dropped: that was already producing the default.
Sequel.migration do
  features = %w[operator_requests identity_history warnings].freeze
  old_key = "ack_delete_after"

  up do
    new_key = Rubotty::Core::CommandAck::TTL_FIELD.to_s

    self[:feature_settings].where(feature: features).select(:id, :config).each do |row|
      config = JSON.parse(row[:config].to_s.empty? ? "{}" : row[:config])
      next unless config.key?(old_key)

      moved = Rubotty::Core::Warnings.duration_seconds(config.delete(old_key))
      config[new_key] = moved unless moved.nil? || config.key?(new_key)
      self[:feature_settings].where(id: row[:id]).update(config: JSON.generate(config), updated_at: Time.now)
    end
  end

  down do
    new_key = Rubotty::Core::CommandAck::TTL_FIELD.to_s

    self[:feature_settings].where(feature: features).select(:id, :config).each do |row|
      config = JSON.parse(row[:config].to_s.empty? ? "{}" : row[:config])
      next unless config.key?(new_key)

      config[old_key] = config.delete(new_key)
      self[:feature_settings].where(id: row[:id]).update(config: JSON.generate(config), updated_at: Time.now)
    end
  end
end
