# frozen_string_literal: true

# Until the identity recorder learned to skip bot authors, a bridge's own
# puppeted copies were observed as people on the platform they landed on, so
# the directory holds rows whose handle is really a rendered sender label
# ("Display Name [handle@platform]", see Core::SenderLabel). Drop those once.
# Keyed on the handle alone, since no platform allows a space in one and the
# directory stores handles stripped and lowercased; a display name is free
# text a member picks and would be far less safe to match on.
module RelayWrittenIdentities
  LABEL = /\A.+\s\[[^\s\[\]]+@[^\s\[\]]+\]\z/ unless const_defined?(:LABEL, false)

  module_function

  def label?(handle) = handle.to_s.match?(LABEL)
end

Sequel.migration do
  up do
    identities = self[:observed_identities]
    stale = identities.select(:id, :username).all
                      .select { |row| RelayWrittenIdentities.label?(row[:username]) }
                      .map { |row| row[:id] }
    identities.where(id: stale).delete unless stale.empty?
  end

  down do
    # Passive observation is the only thing that ever wrote these rows, so
    # nothing here could put them back.
  end
end
