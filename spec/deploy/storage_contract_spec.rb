# frozen_string_literal: true

require "spec_helper"
require "yamlcamel"
require "rake"
require "stringio"
require "uri"

RSpec.describe "the local storage contract" do
  root = File.expand_path("../..", __dir__)

  let(:compose) { YAMLCamel.load_file(File.join(root, "docker-compose.storage.yml")) }
  let(:rakefile) { File.read(File.join(root, "Rakefile")) }

  it "uses the database names, credentials and ports configured by local Compose" do
    defaults = rakefile.scan(%r{"((?:postgres|mysql)://[^"]+)"}).flatten.map { |url| URI.parse(url) }
    expected = { "postgres" => ["postgres", "POSTGRES", "POSTGRES_DB"], "mariadb" => ["mysql", "MARIADB", "MARIADB_DATABASE"] }
    expect(defaults.map(&:scheme)).to match_array(expected.values.map(&:first))
    expected.each do |service, (scheme, prefix, database)|
      url = defaults.find { |entry| entry.scheme == scheme }
      local = compose.fetch("services").fetch(service)
      env = local.fetch("environment")
      expect([url.user, url.password, url.path.delete_prefix("/")]).to eq(
        env.values_at("#{prefix}_USER", "#{prefix}_PASSWORD", database)
      )
      expect(local.fetch("ports")).to include("#{url.port}:#{url.port}")
    end
  end

  describe "the storage:contract task" do
    let(:task_receiver) { Object.new.extend(Rake::DSL) }
    let(:command) { %w[bundle exec rspec spec/storage spec/migrations_prod_shape_spec.rb] }
    let(:database_urls) do
      {
        "TEST_DATABASE_URL" => "postgres://synthetic_pg_user:synthetic_pg_password@postgres.invalid:5432/contract",
        "TEST_MYSQL_DATABASE_URL" => "mysql://synthetic_mysql_user:synthetic_mysql_password@mariadb.invalid:3306/contract"
      }
    end

    around do |example|
      original_application = Rake.application
      original_urls = %w[TEST_DATABASE_URL TEST_MYSQL_DATABASE_URL].to_h { |key| [key, ENV[key]] }
      original_urls.each_key { |key| ENV[key] = database_urls[key] }
      Rake.application = Rake::Application.new
      # Evaluating against a fresh receiver also isolates the Rakefile's constants.
      task_receiver.instance_eval(rakefile, File.join(root, "Rakefile"))
      example.run
    ensure
      Rake.application = original_application
      original_urls.each { |key, value| ENV[key] = value }
    end

    def capture_contract_output
      original_stdout, original_stderr = $stdout, $stderr
      $stdout, $stderr = StringIO.new, StringIO.new
      yield
      [$stdout.string, $stderr.string]
    ensure
      $stdout, $stderr = original_stdout, original_stderr
    end

    it "reports the backends without logging overridden connection credentials" do
      expect(task_receiver).to receive(:system).with(database_urls, *command).once.and_return(true)

      stdout, stderr = capture_contract_output { Rake::Task["storage:contract"].invoke }

      expect(stderr).to eq("")
      (database_urls.values + %w[synthetic_pg_user synthetic_pg_password synthetic_mysql_user synthetic_mysql_password]).each do |secret|
        expect(stdout + stderr).not_to include(secret)
      end
      expect(stdout).to include("Storage contract: PostgreSQL and MariaDB")
    end

    context "without database URL overrides" do
      let(:database_urls) { {} }

      it "runs the same contracts with the default local database URLs" do
        defaults = {
          "TEST_DATABASE_URL" => "postgres://bridge:bridge@localhost:5432/bridge_test",
          "TEST_MYSQL_DATABASE_URL" => "mysql://bridge:bridge@localhost:3306/bridge_test"
        }
        expect(task_receiver).to receive(:system).with(defaults, *command).once.and_return(true)

        stdout, stderr = capture_contract_output { Rake::Task["storage:contract"].invoke }

        expect(stderr).to eq("")
        defaults.each_value { |url| expect(stdout).not_to include(url) }
        expect(stdout).to include("Storage contract: PostgreSQL and MariaDB")
      end
    end

    [false, nil].each do |result|
      it "fails without logging credentials when the child returns #{result.inspect}" do
        expect(task_receiver).to receive(:system).with(database_urls, *command).once.and_return(result)

        stdout, stderr = capture_contract_output do
          expect { Rake::Task["storage:contract"].invoke }.to raise_error(SystemExit) do |error|
            expect(error.status).to eq(1)
          end
        end

        expect(stderr).to include("The storage contract failed.")
        database_urls.each_value { |url| expect(stdout + stderr).not_to include(url) }
      end
    end
  end

end
