# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Validate the control-plane fixture configuration without connecting to anything"
task :check do
  ruby "-Ilib bin/rubotty check -c spec/fixtures/control_plane/sample.config.yaml"
end

desc "Print the full configuration reference, including adapter contributed keys"
task :schema do
  ruby "-Ilib bin/rubotty schema"
end

namespace :storage do
  # Default URLs for the local databases in docker-compose.storage.yml.
  LOCAL_POSTGRES = "postgres://bridge:bridge@localhost:5432/bridge_test"
  LOCAL_MARIADB = "mysql://bridge:bridge@localhost:3306/bridge_test"
  CONTRACT_SPECS = %w[spec/storage spec/migrations_prod_shape_spec.rb].freeze

  desc "Run the storage contract against real PostgreSQL and MariaDB servers"
  task :contract do
    # The specs skip themselves without these, so a run with neither set is a
    # green suite that proved nothing. Say so rather than let it read as a pass.
    postgres = ENV.fetch("TEST_DATABASE_URL", LOCAL_POSTGRES)
    mariadb = ENV.fetch("TEST_MYSQL_DATABASE_URL", LOCAL_MARIADB)
    puts "Storage contract: PostgreSQL and MariaDB"
    puts "Servers:    docker compose -f docker-compose.storage.yml up -d"
    puts "Drivers:    bundle config set --local with 'postgres mariadb' && bundle install"
    ok = system(
      { "TEST_DATABASE_URL" => postgres, "TEST_MYSQL_DATABASE_URL" => mariadb },
      "bundle", "exec", "rspec", *CONTRACT_SPECS
    )
    abort("The storage contract failed.") unless ok
  end
end

namespace :adapters do
  # Each entry names the env vars the matching spec/live/*_live_spec.rb gates
  # itself on.
  LIVE_REQUIREMENTS = {
    "stoat" => %w[STOAT_LIVE_TOKEN STOAT_LIVE_CHANNEL_ID],
    "fluxer" => %w[FLUXER_LIVE_TOKEN FLUXER_LIVE_CHANNEL_ID],
    "matrix" => %w[MATRIX_LIVE_HOMESERVER MATRIX_LIVE_TOKEN MATRIX_LIVE_ROOM_ID],
    "xmpp" => %w[XMPP_LIVE_JID XMPP_LIVE_PASSWORD XMPP_LIVE_ROOM_JID],
    "irc" => %w[IRC_LIVE_SERVER IRC_LIVE_NICK IRC_LIVE_CHANNEL]
  }.freeze

  desc "Live-validate the newer platform adapters against real gateways (issue #133)"
  task :live do
    # The specs skip themselves without these, so a run with none set is a
    # green suite that proved nothing about a real gateway. Say so rather
    # than let it read as a pass.
    ready, skipped = LIVE_REQUIREMENTS.partition { |_platform, vars| vars.all? { |var| ENV[var] } }
    puts "Ready:   #{ready.map(&:first).join(", ")}" unless ready.empty?
    skipped.each do |platform, vars|
      missing = vars.reject { |var| ENV[var] }
      puts "Skipped: #{platform} (missing #{missing.join(", ")})"
    end
    if ready.empty?
      puts "\nNo platform has its live credentials set: this run proves nothing beyond the fakes " \
           "every other adapter spec already runs against."
    end
    ok = system("bundle", "exec", "rspec", "spec/live")
    abort("Live adapter validation failed.") unless ok
  end
end

task default: :spec
