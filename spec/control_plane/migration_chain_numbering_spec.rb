# frozen_string_literal: true

require "spec_helper"
require "sequel"

Sequel.extension :migration

# Two branches that each add a migration pick the same number without producing
# a merge conflict, and Sequel refuses a chain whose versions collide or skip,
# which reaches us as every database-seeding spec failing at once.
RSpec.describe "the control-plane migration chain numbering" do
  migration_file = Sequel::Migrator::MIGRATION_FILE_PATTERN

  let(:migrations_dir) { Rubotty::ControlPlane::Migrator::MIGRATIONS_DIR }

  # Migration filenames grouped by the version each claims, matched the way
  # Sequel matches them so the spec sees exactly the files the migrator sees.
  let(:files_by_version) do
    Dir.children(migrations_dir)
       .grep(migration_file)
       .sort
       .group_by { |name| migration_file.match(name)[1].to_i }
  end

  it "gives every migration a version of its own" do
    collisions = files_by_version.select { |_version, files| files.length > 1 }
    listed = collisions.map { |version, files| "#{version}: #{files.join(', ')}" }

    expect(collisions).to be_empty,
                          "more than one migration claims a version, which Sequel refuses to run:\n  " +
                          listed.join("\n  ")
  end

  it "numbers the chain from 1 to the head without skipping" do
    versions = files_by_version.keys.sort
    missing = (1..versions.max).to_a - versions

    expect(missing).to be_empty,
                       "the chain has no migration for #{missing.join(', ')}, and Sequel refuses to run " \
                       "a chain with a hole in it"
  end
end
