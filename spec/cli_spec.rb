# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Rubotty::CLI, "control-plane commands" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:env) { { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token" } }

  # A minimal but valid config. sqlite is Sequel-backed, so the control plane
  # can be migrated and seeded onto it.
  def write_config(driver:)
    storage = driver == :sqlite ? "  driver: sqlite\n  path: #{@dir}/map.sqlite3\n" : "  driver: memory\n"
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
      #{storage.chomp}
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

  # api_wrapper is the one adapter left with no admin DM implementation, so
  # a config naming only it is what exercises that gap.
  def write_api_wrapper_config
    yaml = <<~YAML
      name: Test Community
      accounts:
        wrapper:
          adapter: api_wrapper
          webhook_url: https://example.invalid/hook
          signing_secret_env: WRAPPER_SECRET
      storage:
        driver: memory
      behaviour:
        log_level: fatal
      rooms:
        - id: lounge
          endpoints:
            - id: wrapper-lounge
              adapter: api_wrapper
              account: wrapper
              channel_id: "lounge"
            - id: wrapper-lounge-overflow
              adapter: api_wrapper
              account: wrapper
              channel_id: "lounge-overflow"
    YAML
    path = File.join(@dir, "bridge.config.yaml")
    File.write(path, yaml)
    path
  end

  def run_cli(*args, env: self.env)
    out = StringIO.new
    err = StringIO.new
    code = described_class.run(args, env: env, out: out, err: err)
    [code, out.string, err.string]
  end

  # Put rows in the two tables that only POINT at bytes, so a transfer has
  # something to warn about. Inserted straight rather than through the services,
  # because what is being tested is the warning's arithmetic and nothing here
  # ever opens an object store.
  def seed_stored_files(src, rehosted: 0, guest_uploads: 0)
    db = Sequel.sqlite(src)
    community_id = db[:communities].first[:id]
    now = Time.now
    rehosted.times do |n|
      db[:rehosted_files].insert(
        community_id: community_id, token_hash: "a#{n}".ljust(64, "a"), object_key: "rehosted/1/aa/bb#{n}",
        filename: "big.zip", content_type: "application/zip", byte_size: 1,
        sealed_bytes: 1, iv: "x", auth_tag: "y", expires_at: now + 3600, created_at: now
      )
    end
    guest_uploads.times do |n|
      db[:guest_uploads].insert(
        community_id: community_id, token_hash: "b#{n}".ljust(64, "b"),
        object_key: "guest-upload/1/cc/dd#{n}", filename: "photo.png", content_type: "image/png",
        byte_size: 1, sealed_bytes: 1, iv: "x", auth_tag: "y", created_at: now
      )
    end
    db.disconnect
  end

  # Reopen the seeded database to inspect it, the CLI having closed its own
  # connection when the command finished.
  def reopen_models(path)
    db = Sequel.connect("sqlite://#{@dir}/map.sqlite3")
    Rubotty::ControlPlane.models(db)
  end

  # No configuration file ships with the repository, and none is required:
  # accounts and topology can live entirely in the control-plane database, so
  # a command with no -c and no $BRIDGE_CONFIG boots on an empty config and
  # says so on stderr, a fact about how the process started, not a refusal.
  describe "with no -c and no $BRIDGE_CONFIG" do
    it "boots on an empty config and says so plainly" do
      code, out, err = run_cli("check", env: { "ALLOW_EPHEMERAL_STORAGE" => "1" })

      expect(code).to eq(0)
      expect(err).to match(/no configuration given/i)
      expect(out).to include("Configuration at (no configuration given) is valid.")
    end

    it "treats a blank $BRIDGE_CONFIG the same as an unset one" do
      code, _out, err = run_cli("check", env: { "BRIDGE_CONFIG" => "", "ALLOW_EPHEMERAL_STORAGE" => "1" })

      expect(code).to eq(0)
      expect(err).to match(/no configuration given/i)
    end
  end

  # Where an operator finds out whether this deployment can confine a script's
  # process, since nothing else says so before a script runs.
  describe "check" do
    around do |example|
      Rubotty::Scripting::Isolation.reset!
      example.run
      Rubotty::Scripting::Isolation.reset!
    end

    def with_isolation(value)
      key = Rubotty::Scripting::Isolation::SETTING
      previous = ENV.fetch(key, nil)
      ENV[key] = value
      yield
    ensure
      ENV[key] = previous
    end

    it "reports scripts as off where they cannot be confined" do
      # Pinned rather than left to the host: a run as root resolves an account
      # and reports the opposite, so this would pass on a laptop and fail in CI.
      allow(Rubotty::Scripting::Isolation).to receive(:account).and_return(nil)
      path = write_config(driver: :memory)
      code, out, = with_isolation("required") { run_cli("check", "-c", path) }

      expect(code).to eq(0)
      expect(out).to match(/Operator scripts are OFF/)
    end

    it "names the account scripts run as where they can be" do
      allow(Rubotty::Scripting::Isolation).to receive(:account).and_return({ uid: 65_534, gid: 65_534 })
      path = write_config(driver: :memory)
      code, out, = run_cli("check", "-c", path)

      expect(code).to eq(0)
      expect(out).to match(/Operator scripts run as uid 65534/)
    end

    # api_wrapper has no way to carry an admin DM at all: a generic REST
    # webhook has no notion of a native DM to open. Matrix, IRC and XMPP used
    # to sit in that same bucket, but every adapter that could carry one is
    # written now, leaving api_wrapper the only impossible case left.
    it "names a configured platform that cannot carry an admin DM at all" do
      path = write_api_wrapper_config
      code, out, = run_cli("check", "-c", path, env: { "WRAPPER_SECRET" => "whsec_x" })

      expect(code).to eq(0)
      expect(out).to include("api_wrapper cannot carry an admin DM at all")
    end

    it "says nothing about a missing admin DM once every configured platform already has one" do
      path = write_config(driver: :memory)
      code, out, = run_cli("check", "-c", path)

      expect(code).to eq(0)
      expect(out).not_to include("admin DM")
    end

    # GUEST_PORTAL_URL is the base every /guest and /upload reply, and every
    # dashboard guest invite, is built on. Left unset it used to build a bare
    # path with no scheme or host instead of a link, silently, with nothing
    # at `check` time to say so.
    it "flags a missing GUEST_PORTAL_URL as a gap to close before deploying" do
      path = write_config(driver: :memory)
      code, out, = run_cli("check", "-c", path)

      expect(code).to eq(0)
      expect(out).to include("GUEST_PORTAL_URL is not set to a full http(s) address")
    end

    it "says nothing about GUEST_PORTAL_URL once it names a real http(s) base" do
      path = write_config(driver: :memory)
      code, out, = run_cli("check", "-c", path, env: env.merge("GUEST_PORTAL_URL" => "https://rubotty.example/guest-chat"))

      expect(code).to eq(0)
      expect(out).not_to include("GUEST_PORTAL_URL")
    end

    # RUBOTTY_FILE_STORAGE_URL is the base every file_rehosting download link
    # is built on, kept apart from GUEST_PORTAL_URL since file storage has no
    # relationship to the guest portal.
    it "flags a missing RUBOTTY_FILE_STORAGE_URL as a gap to close before deploying" do
      path = write_config(driver: :memory)
      code, out, = run_cli("check", "-c", path)

      expect(code).to eq(0)
      expect(out).to include("RUBOTTY_FILE_STORAGE_URL is not set to a full http(s) address")
    end

    it "says nothing about RUBOTTY_FILE_STORAGE_URL once it names a real http(s) base" do
      path = write_config(driver: :memory)
      code, out, = run_cli("check", "-c", path, env: env.merge("RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.example"))

      expect(code).to eq(0)
      expect(out).not_to include("RUBOTTY_FILE_STORAGE_URL")
    end
  end

  # check and topology used to read only the static config, so either reported
  # zero rooms and zero operators against a database that was fully populated.
  # Both now read the live control-plane snapshot when the storage backend has
  # one, so a config with next to nothing left in it still gets an honest report.
  describe "check and topology against a live control-plane snapshot (issue #780)" do
    def write_full_config(sqlite_path)
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
          path: #{sqlite_path}
        behaviour:
          log_level: fatal
        operators:
          - name: ada
            identities:
              telegram: ["111"]
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
      path = File.join(@dir, "full.config.yaml")
      File.write(path, yaml)
      path
    end

    # Not literally the file gone (loader_spec covers that): a config that
    # still exists but carries none of the topology the database already has,
    # which is what `check`/`topology` see on every run after the first once a
    # deployment stops hand editing bridge.config.yaml for its rooms.
    def write_bare_config(sqlite_path)
      yaml = <<~YAML
        storage:
          driver: sqlite
          path: #{sqlite_path}
      YAML
      path = File.join(@dir, "bare.config.yaml")
      File.write(path, yaml)
      path
    end

    def seed_full_config(sqlite_path)
      full_path = write_full_config(sqlite_path)
      code, = run_cli("seed", "-c", full_path)
      expect(code).to eq(0)
    end

    it "check reports the live rooms and operators, not the bare config's empty ones" do
      sqlite_path = "#{@dir}/map.sqlite3"
      seed_full_config(sqlite_path)

      code, out, = run_cli("check", "-c", write_bare_config(sqlite_path))

      expect(code).to eq(0)
      # 3, not 2: the control plane fronts the room with its own synthetic api
      # endpoint, on top of the two the YAML named.
      expect(out).to include("1 room(s), 3 endpoint(s)")
      expect(out).to include("tg-lounge(telegram)")
      expect(out).to include("dc-lounge(discord)")
      expect(out).to include("Moderation commands are enabled for 1 operator(s).")
    end

    # With a control plane the verbs are recognised whatever the directory
    # holds, and an issuer who resolves to no operator is refused as not
    # permitted. Saying the commands are disabled would send the reader looking
    # for a switch that is not the reason.
    it "check says an empty live directory refuses commands rather than disabling them" do
      sqlite_path = "#{@dir}/map.sqlite3"

      code, out, = run_cli("check", "-c", write_bare_config(sqlite_path))

      expect(code).to eq(0)
      expect(out).to include("refused as not permitted")
      expect(out).not_to include("/delete and the other commands are disabled")
    end

    it "topology lists the live rooms and endpoints, not none" do
      sqlite_path = "#{@dir}/map.sqlite3"
      seed_full_config(sqlite_path)

      code, out, = run_cli("topology", "-c", write_bare_config(sqlite_path))

      expect(code).to eq(0)
      expect(out).to include("room lounge")
      expect(out).to include("tg-lounge")
      expect(out).to include("dc-lounge")
    end

    it "falls back to the static config, exactly as before, without a database to read" do
      path = write_config(driver: :memory)
      code, out, = run_cli("check", "-c", path)

      expect(code).to eq(0)
      expect(out).to include("Test Community: 1 room(s), 2 endpoint(s)")
    end
  end

  describe "migrate" do
    it "applies the control-plane migrations onto the message-map database" do
      path = write_config(driver: :sqlite)
      code, out, = run_cli("migrate", "-c", path)
      expect(code).to eq(0)
      expect(out).to match(/migrations applied/i)

      models = reopen_models(path)
      # The schema exists but nothing is seeded by migrate alone.
      expect(models.community.count).to eq(0)
    end

    it "refuses a store that cannot host the control plane" do
      path = write_config(driver: :memory)
      code, _out, err = run_cli("migrate", "-c", path)
      expect(code).to eq(1)
      expect(err).to match(/Sequel-backed store/)
    end
  end

  describe "seed" do
    it "projects the config into the control plane under the config-name slug" do
      path = write_config(driver: :sqlite)
      code, out, = run_cli("seed", "-c", path)
      expect(code).to eq(0)
      expect(out).to match(/community "test-community"/)

      models = reopen_models(path)
      expect(models.community.count).to eq(1)
      expect(models.channel.count).to eq(2)
      expect(models.community.first.slug).to eq("test-community")
    end

    it "honours an explicit --community-slug" do
      path = write_config(driver: :sqlite)
      code, out, = run_cli("seed", "-c", path, "--community-slug", "lounge-hq")
      expect(code).to eq(0)
      expect(out).to match(/community "lounge-hq"/)
      expect(reopen_models(path).community.first.slug).to eq("lounge-hq")
    end

    it "is idempotent when re-run" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      run_cli("seed", "-c", path)
      models = reopen_models(path)
      expect(models.community.count).to eq(1)
      expect(models.channel.count).to eq(2)
    end
  end

  describe "feature" do
    # The interim admin CLI: read and edit feature_settings from the
    # Coolify Terminal. Each example seeds first, so there is a community to edit.
    def seed(path)
      run_cli("seed", "-c", path)
    end

    # Reopen and read the raw feature_settings rows the CLI just committed and
    # closed, the same way the migrate/seed examples reopen to inspect.
    def feature_rows(path, feature:)
      models = reopen_models(path)
      community = models.community.where(slug: "test-community").first
      models.feature_setting.where(community_id: community.id, feature: feature).all
    end

    it "enables a feature at the community scope (room_id NULL)" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, out, = run_cli("feature", "enable", "test-community", "all", "faq", "-c", path)
      expect(code).to eq(0)
      expect(out).to match(/enabled faq for the community default/)
      expect(out).to match(/pick this up live/)

      rows = feature_rows(path, feature: "faq")
      expect(rows.size).to eq(1)
      expect(rows.first.room_id).to be_nil
      expect([true, 1]).to include(rows.first.enabled)
    end

    it "enables a feature on a room, writing a single room-scoped row" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, out, = run_cli("feature", "enable", "test-community", "lounge", "word_filter", "-c", path)
      expect(code).to eq(0)
      expect(out).to match(/room lounge/)

      rows = feature_rows(path, feature: "word_filter")
      expect(rows.size).to eq(1)
      expect(rows.first.room_id).not_to be_nil
    end

    it "enables a feature by an endpoint_key, resolving to that endpoint's room" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, out, = run_cli("feature", "enable", "test-community", "tg-lounge", "word_filter", "-c", path)
      expect(code).to eq(0)
      expect(out).to match(/room lounge/)

      rows = feature_rows(path, feature: "word_filter")
      expect(rows.size).to eq(1)
      expect(rows.first.room_id).not_to be_nil
    end

    it "sets a config value, merging a comma list into the JSON blob" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, out, = run_cli("feature", "set", "test-community", "tg-lounge",
                           "word_filter", "blocked", "foo, bar, baz", "-c", path)
      expect(code).to eq(0)
      expect(out).to match(/word_filter\.blocked = \["foo", "bar", "baz"\]/)

      rows = feature_rows(path, feature: "word_filter")
      config = rows.first.json_value(:config)
      expect(config).to eq("blocked" => %w[foo bar baz])
    end

    it "disables a feature it previously enabled" do
      path = write_config(driver: :sqlite)
      seed(path)
      run_cli("feature", "enable", "test-community", "all", "faq", "-c", path)
      code, = run_cli("feature", "disable", "test-community", "all", "faq", "-c", path)
      expect(code).to eq(0)
      expect([false, 0]).to include(feature_rows(path, feature: "faq").first.enabled)
    end

    it "lists the current settings for the whole community" do
      path = write_config(driver: :sqlite)
      seed(path)
      run_cli("feature", "enable", "test-community", "tg-lounge", "word_filter", "-c", path)
      code, out, = run_cli("feature", "list", "test-community", "-c", path)
      expect(code).to eq(0)
      # The seed writes bridge and operator_requests at the community scope; the
      # CLI added a room-scoped word_filter override (resolved from tg-lounge).
      expect(out).to match(/bridge/)
      expect(out).to match(/word_filter/)
      expect(out).to match(/lounge/)
    end

    it "lists only a named scope when one is given" do
      path = write_config(driver: :sqlite)
      seed(path)
      run_cli("feature", "enable", "test-community", "tg-lounge", "word_filter", "-c", path)
      _code, out, = run_cli("feature", "list", "test-community", "tg-lounge", "-c", path)
      expect(out).to match(/word_filter/)
      expect(out).not_to match(/\bbridge\b/)
    end

    it "rejects an unknown feature name" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, _out, err = run_cli("feature", "enable", "test-community", "all", "reactions", "-c", path)
      expect(code).to eq(1)
      expect(err).to match(/unknown feature "reactions"/)
    end

    it "rejects an unknown community" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, _out, err = run_cli("feature", "enable", "nope", "all", "faq", "-c", path)
      expect(code).to eq(1)
      expect(err).to match(/no community with slug "nope"/)
    end

    it "rejects a room selector that matches nothing" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, _out, err = run_cli("feature", "enable", "test-community", "zzz", "faq", "-c", path)
      expect(code).to eq(1)
      expect(err).to match(/matched "zzz"/)
    end

    it "prints usage and exits non-zero when arguments are missing" do
      path = write_config(driver: :sqlite)
      seed(path)
      code, _out, err = run_cli("feature", "enable", "test-community", "-c", path)
      expect(code).to eq(2)
      expect(err).to match(/usage: rubotty feature enable/)
    end

    it "refuses a store that cannot host the control plane" do
      path = write_config(driver: :memory)
      code, _out, err = run_cli("feature", "list", "test-community", "-c", path)
      expect(code).to eq(1)
      expect(err).to match(/Sequel-backed store/)
    end
  end

  describe "datastore migrate" do
    # The whole-datastore copy tool: each example seeds a sqlite source through
    # the CLI, copies it to a fresh target, and inspects the result. A
    # row-count match says the tables came across; it says nothing about the
    # FILES, whose bytes live on a disk this command cannot reach.
    it "says nothing about stored files when there are none to lose" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"

      _code, out, = run_cli("datastore", "migrate", "--from", "sqlite:#{src}",
                            "--to", "sqlite:#{@dir}/quiet.sqlite3")

      expect(out).to match(/Verification passed/)
      expect(out).not_to match(/object store directory/)
    end

    it "warns that a rehosted file's bytes did not come with it" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      seed_stored_files(src, rehosted: 1)

      _code, out, = run_cli("datastore", "migrate", "--from", "sqlite:#{src}",
                            "--to", "sqlite:#{@dir}/loud.sqlite3")

      expect(out).to match(/1 rehosted file came across as metadata only/)
      expect(out).to match(/RUBOTTY_FILE_STORE/)
      expect(out).to match(/every download link will 404/)
    end

    # A guest upload's bytes went to the same store in migration 045, so the
    # same warning has to cover them. Both tables are counted separately, so an
    # operator can see which links are about to break.
    it "warns about guest uploads too, naming each table's count" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      seed_stored_files(src, rehosted: 1, guest_uploads: 2)

      _code, out, = run_cli("datastore", "migrate", "--from", "sqlite:#{src}",
                            "--to", "sqlite:#{@dir}/both.sqlite3")

      expect(out).to match(/1 rehosted file and 2 guest uploads came across as metadata only/)
    end

    it "warns about guest uploads on their own, with no rehosted file in sight" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      seed_stored_files(src, guest_uploads: 1)

      _code, out, = run_cli("datastore", "migrate", "--from", "sqlite:#{src}",
                            "--to", "sqlite:#{@dir}/guests.sqlite3")

      expect(out).to match(/1 guest upload came across as metadata only/)
      expect(out).not_to match(/rehosted file/)
    end

    it "copies the seeded datastore to a fresh target and verifies row counts" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      dst = "#{@dir}/out.sqlite3"

      code, out, = run_cli("datastore", "migrate", "--from", "sqlite:#{src}", "--to", "sqlite:#{dst}")
      expect(code).to eq(0)
      expect(out).to match(/Verification passed/)
      expect(out).to match(/communities/)

      db = Sequel.connect("sqlite://#{dst}")
      expect(db[:communities].count).to eq(1)
      expect(db[:channels].count).to eq(2)
      db.disconnect
    end

    it "previews with --dry-run and writes nothing to the target" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      dst = "#{@dir}/nope.sqlite3"

      code, out, = run_cli("datastore", "migrate", "--from", "sqlite:#{src}", "--to", "sqlite:#{dst}", "--dry-run")
      expect(code).to eq(0)
      expect(out).to match(/DRY RUN/)
      expect(File.exist?(dst)).to be(false)
    end

    it "prints usage and exits non-zero when --from or --to is missing" do
      code, _out, err = run_cli("datastore", "migrate")
      expect(code).to eq(2)
      expect(err).to match(/usage: rubotty datastore migrate/)
    end

    it "rejects an unknown datastore subcommand" do
      code, _out, err = run_cli("datastore", "wibble")
      expect(code).to eq(2)
      expect(err).to match(/unknown datastore subcommand/)
    end
  end

  describe "datastore export/import" do
    it "exports the configured storage by default and imports it into a fresh target" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      snapshot = "#{@dir}/snapshot.yaml.gz"

      code, out, = run_cli("datastore", "export", "-c", path, "--to", snapshot)
      expect(code).to eq(0)
      expect(out).to match(/Datastore export/)
      expect(File.exist?(snapshot)).to be(true)

      dst = "#{@dir}/restored.sqlite3"
      code, out, = run_cli("datastore", "import", "--from", snapshot, "--to", "sqlite:#{dst}")
      expect(code).to eq(0)
      expect(out).to match(/Datastore import/)

      db = Sequel.connect("sqlite://#{dst}")
      expect(db[:communities].count).to eq(1)
      expect(db[:channels].count).to eq(2)
      db.disconnect
    end

    it "exports an explicit --from spec instead of the configured storage" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      snapshot = "#{@dir}/explicit.yaml.gz"

      code, = run_cli("datastore", "export", "--from", "sqlite:#{src}", "--to", snapshot)
      expect(code).to eq(0)
      expect(File.exist?(snapshot)).to be(true)
    end

    it "warns about a rehosted file's bytes not coming with the snapshot" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      seed_stored_files(src, rehosted: 1)
      snapshot = "#{@dir}/files.yaml.gz"

      _code, out, = run_cli("datastore", "export", "--from", "sqlite:#{src}", "--to", snapshot)
      expect(out).to match(/1 rehosted file came across as metadata only/)
    end

    it "refuses to import into a datastore that already has data" do
      path = write_config(driver: :sqlite)
      run_cli("seed", "-c", path)
      src = "#{@dir}/map.sqlite3"
      snapshot = "#{@dir}/occupied.yaml.gz"
      run_cli("datastore", "export", "--from", "sqlite:#{src}", "--to", snapshot)

      code, _out, err = run_cli("datastore", "import", "--from", snapshot, "--to", "sqlite:#{src}")
      expect(code).to eq(1)
      expect(err).to match(/already has data/)
    end

    it "prints usage and exits non-zero when export is missing --to" do
      code, _out, err = run_cli("datastore", "export")
      expect(code).to eq(2)
      expect(err).to match(/usage: rubotty datastore export/)
    end

    it "prints usage and exits non-zero when import is missing --from" do
      code, _out, err = run_cli("datastore", "import")
      expect(code).to eq(2)
      expect(err).to match(/usage: rubotty datastore import/)
    end
  end

  describe "help lists the new commands" do
    it "mentions migrate and seed" do
      _code, out, = run_cli("--help")
      expect(out).to match(/migrate/)
      expect(out).to match(/seed/)
    end

    it "mentions the datastore command and its subcommands" do
      _code, out, = run_cli("--help")
      expect(out).to match(/datastore/)
      expect(out).to match(/datastore migrate/)
      expect(out).to match(/datastore export/)
      expect(out).to match(/datastore import/)
    end

    it "mentions the feature command and its subcommands" do
      _code, out, = run_cli("--help")
      expect(out).to match(/feature/)
      expect(out).to match(/feature enable/)
      expect(out).to match(/feature set/)
    end
  end
end
