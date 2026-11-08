# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "rack/builder"
require "sequel"
require "securerandom"
require "stringio"
require "tmpdir"

# filestorage.ru is what a split deployment actually runs, so this loads and
# runs the real file rather than re-describing what it is supposed to do: a
# regression here means the split entry point is broken, not just the shared
# {Rubotty::FileStorage::App} logic {file_storage/app_spec.rb} already covers.
RSpec.describe "filestorage.ru", :control_plane do
  include Rack::Test::Methods

  ENTRY_POINT = File.expand_path("../../filestorage.ru", __dir__)

  around do |example|
    Dir.mktmpdir("rubotty-filestorage-ru") do |dir|
      @dir = dir
      with_object_store_root do |root|
        @store_root = root
        example.run
      end
    end
  end

  let(:db_path) { File.join(@dir, "control_plane.sqlite3") }

  # A rehosted file the running .ru process did not write, seeded through a
  # second connection to the same sqlite file before the process boots, so
  # the download assertions below prove the entry point reads the real
  # configured database rather than one built from nothing.
  let(:stored) do
    seed_db = Sequel.connect("sqlite://#{db_path}")
    Rubotty::ControlPlane.migrate!(seed_db)
    models = Rubotty::ControlPlane.models(seed_db)
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "sample")
    community = models.community.where(slug: "sample").first
    rehosted_files = Rubotty::ControlPlane::RehostedFiles.new(
      models: models, store: Rubotty::Storage::ObjectStore.new(root: @store_root)
    )
    result = rehosted_files.store_file(
      community_id: community.id, source: StringIO.new(payload), filename: "clip.mp4", content_type: "video/mp4"
    )
    seed_db.disconnect
    result
  end

  let(:payload) { "bytes a split deployment's file-storage process should still be able to serve. " * 200 }

  def write_config
    yaml = <<~YAML
      name: Test Community
      accounts:
        telegram:
          adapter: telegram
          token_env: TG_TOKEN
        discord:
          adapter: discord
          token_env: DC_TOKEN
      storage:
        driver: sqlite
        path: #{db_path}
      behaviour:
        log_level: fatal
      rooms:
        - id: lounge
          endpoints:
            - id: tg-lounge
              adapter: telegram
              account: telegram
              chat_id: "-1008000000001"
            - id: dc-lounge
              adapter: discord
              account: discord
              channel_id: "800000000000000011"
    YAML
    path = File.join(@dir, "bridge.config.yaml")
    File.write(path, yaml)
    path
  end

  # Actually boots the file: same $LOAD_PATH setup, same env-driven config and
  # storage resolution, same `run` line a real `rackup filestorage.ru` executes.
  let(:app) do
    stored # seed before the process opens its own connection to the same file
    with_env("BRIDGE_CONFIG" => write_config, "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token") do
      # Rack::Builder.parse_file returns the built app itself for a .ru path,
      # not a [app, options] pair (that shape is config.ru-less Ruby files).
      Rack::Builder.parse_file(ENTRY_POINT)
    end
  end

  def with_env(vars)
    previous = vars.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  it "serves the healthcheck at /filestorage/healthz, where the mount puts it" do
    get "/filestorage/healthz"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("ok\n")
  end

  it "also serves the healthcheck under the legacy /f mount" do
    get "/f/healthz"

    expect(last_response.status).to eq(200)
  end

  it "streams a rehosted file back at the real /filestorage/:token route" do
    get "/filestorage/#{stored.secret}.mp4"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq(payload)
    expect(last_response.headers["Content-Disposition"]).to include("clip.mp4")
  end

  it "still resolves a bare-secret link under the legacy /f mount" do
    get "/f/#{stored.secret}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq(payload)
  end

  it "404s an unknown token rather than raising, on either mount" do
    get "/filestorage/#{SecureRandom.uuid}.mp4"
    expect(last_response.status).to eq(404)

    get "/f/#{SecureRandom.uuid}"
    expect(last_response.status).to eq(404)
  end

  it "answers nothing at the bare root, since the mount is /filestorage and /f only" do
    get "/healthz"

    expect(last_response.status).to eq(404)
  end
end
