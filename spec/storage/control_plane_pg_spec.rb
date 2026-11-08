# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The control-plane migrations against a real PostgreSQL, so CI's storage job
# exercises the pg path production runs. Skipped wherever TEST_DATABASE_URL is
# unset. The shared contract lives in spec/support/sequel_backend_contract.rb and
# runs against MariaDB too (control_plane_mdb_spec.rb).
RSpec.describe "control-plane migrations on postgres", if: ENV["TEST_DATABASE_URL"] do
  include_examples "the control-plane migration contract", :pg, "TEST_DATABASE_URL"
end
