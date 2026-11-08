# frozen_string_literal: true

RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:release_defaults]

    owners = Rubotty::Security::ProtectedOperators.new(
      usernames: %w[maintainer owner_handle sample_owner], matrix_ids: ["@owner:matrix.example.org"]
    )
    allow(Rubotty::Security::ProtectedOperators).to receive(:default).and_return(owners)
    communities = Rubotty::ControlPlane::ProtectedCommunities.new(
      patterns: ["SAMPLE", "Example Gaming Community", "Example Travel", "SECOND"]
    )
    allow(Rubotty::ControlPlane::ProtectedCommunities).to receive(:default).and_return(communities)
  end
end
