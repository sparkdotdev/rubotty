# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The search backend against the two real servers, since the whole matching
# strategy rests on LIKE and lower() behaving the same on all three and a laptop
# running SQLite cannot show that. Skipped wherever the URLs are unset. The
# shared contract is in spec/support/search_backend_contract.rb.
RSpec.describe "search on postgres", :control_plane, if: ENV["TEST_DATABASE_URL"] do
  include_examples "the search backend contract", :pg, "TEST_DATABASE_URL"
end

RSpec.describe "search on mariadb", :control_plane, if: ENV["TEST_MYSQL_DATABASE_URL"] do
  include_examples "the search backend contract", :mdb, "TEST_MYSQL_DATABASE_URL"
end
