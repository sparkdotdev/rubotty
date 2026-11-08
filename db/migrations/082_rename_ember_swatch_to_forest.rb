# frozen_string_literal: true

# The swatch named "ember" is a green palette, not the fire tones the name
# suggests, so it is renamed to "forest" in code, in the built stylesheet and
# here, in any dashboard_appearances row a deployment already saved it into.
# The colours are unchanged; only the name moves.
Sequel.migration do
  up do
    self[:dashboard_appearances].where(swatch: "ember").update(swatch: "forest", updated_at: Time.now)
  end

  down do
    self[:dashboard_appearances].where(swatch: "forest").update(swatch: "ember", updated_at: Time.now)
  end
end
