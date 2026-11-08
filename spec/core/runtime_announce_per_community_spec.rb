# frozen_string_literal: true

require "spec_helper"

# One startup banner per LIVE community, targeted by precedence, with
# per-community suppression.
RSpec.describe Rubotty::Core::Runtime, "per-community startup announcement (issue #265)", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def build_runtime(store:, logger: Rubotty::Log.null, env: ControlPlaneHelpers::CONFIG_ENV)
    described_class.new(config: config, logger: logger, storage: store, env: env).build
  end

  # A second community with rooms but NONE named "general".
  SAMPLE_TRAVEL_YAML = <<~YAML
    name: sample_travel volunteers
    accounts:
      tg: { adapter: telegram, token_env: TG }
      dc: { adapter: discord, token_env: DC }
    storage:
      driver: memory
    rooms:
      - id: volunteers
        endpoints:
          - { id: sample_travel-tg-volunteers, adapter: telegram, account: tg, chat_id: "-200111" }
          - { id: sample_travel-dc-volunteers, adapter: discord, account: dc, channel_id: "2001110000000000" }
      - id: lounge
        endpoints:
          - { id: sample_travel-tg-lounge, adapter: telegram, account: tg, chat_id: "-200222" }
          - { id: sample_travel-dc-lounge, adapter: discord, account: dc, channel_id: "2002220000000000" }
  YAML

  def seed_community(store, source, slug)
    model = Rubotty::Config::Loader.load_string(source, env: { "TG" => "t", "DC" => "d" })
    Rubotty::ControlPlane::Seed.from_model(model, models: build_models(store.db), slug: slug)
  end

  # Written directly because a config model cannot describe zero rooms.
  def seed_roomless_community(store, slug)
    now = Time.now
    build_models(store.db).community.create(
      slug: slug, name: slug, status: "active",
      bootstrap_source: "test", settings: "{}", created_at: now, updated_at: now
    )
  end

  # Record the room each banner targeted, by endpoint id, without delivering.
  def capture_posts(runtime)
    posted = []
    allow(runtime.ephemeral).to receive(:post) do |endpoints:, **_rest|
      posted << endpoints.map(&:id)
      instance_double(Rubotty::Core::EphemeralMessage::Group, any?: false, delete_now: nil)
    end
    posted
  end

  # The banner is off unless a community asks for it, so every example that
  # expects one turns it on the way an operator would. "all" is the
  # community-wide selector.
  def enable_banner(store, runtime, slugs: nil)
    models = build_models(store.db)
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    models.community.all.each do |row|
      next if slugs && !slugs.include?(row.slug)

      controls.enable(community: row, selector: "all", feature: "startup_banner")
    end
    runtime.registry.reload
  end

  # A deploy that takes several attempts announces itself on every attempt, which
  # is what made this worth a switch rather than a constant.
  describe "the per-community switch" do
    it "posts nothing at all until a community asks for the banner" do
      store = sequel_store
      runtime = build_runtime(store: store)
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(posted).to be_empty
    end

    it "announces only the community that turned it on, not its neighbours" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, SAMPLE_TRAVEL_YAML, "sample_travel-volunteers")
      enable_banner(store, runtime, slugs: %w[sample_travel-volunteers])
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(posted).to contain_exactly(match_array(%w[sample_travel-tg-lounge sample_travel-dc-lounge]))
    end

    # The switch is a real catalog entry, so it reaches the dashboard, the API and
    # the CLI without any of them naming it specially.
    it "is a known feature, off by default" do
      expect(Rubotty::Features::Catalog.known?("startup_banner")).to be(true)
      expect(Rubotty::Features::StartupBanner.default_enabled?).to be(false)
    end

    # It never runs as a pipeline step, so it must stay out of the run order the
    # router is asserted against.
    it "is not a step in the message pipeline" do
      expect(Rubotty::Features::Catalog::PIPELINE_ORDER).not_to include("startup_banner")
    end
  end

  # A control plane that failed to come up lands on the config path, which had no
  # switch to consult and announced regardless. That is how the banner came back
  # in sample after it had been turned off everywhere.
  describe "when there is no control plane" do
    def config_only_runtime(store)
      runtime = build_runtime(store: store)
      runtime.instance_variable_set(:@registry, nil)
      runtime
    end

    it "stays quiet rather than announcing from the fallback path" do
      store = sequel_store
      runtime = config_only_runtime(store)
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(posted).to be_empty
    end

    it "says why, so a silent boot is not a mystery" do
      io = StringIO.new
      store = sequel_store
      runtime = build_runtime(store: store, logger: Rubotty::Log.build(level: "info", io: io))
      runtime.instance_variable_set(:@registry, nil)
      capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(io.string).to include("no control plane, so the startup banner is skipped")
    end
  end

  describe "a config-defined community with a 'general' room (regression)" do
    it "still posts its banner in general, exactly as before" do
      store = sequel_store
      runtime = build_runtime(store: store)
      enable_banner(store, runtime)
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(posted).to contain_exactly(match_array(%w[tg-general dc-general]))
    end
  end

  describe "a dynamically onboarded community with rooms but no 'general'" do
    it "posts its banner in its first room (alphabetical room_key), not nowhere" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, SAMPLE_TRAVEL_YAML, "sample_travel-volunteers")
      runtime.registry.reload
      enable_banner(store, runtime)
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      # sample_travel has no general, so it falls back to lounge, alphabetically first.
      expect(posted).to contain_exactly(
        match_array(%w[tg-general dc-general]),
        match_array(%w[sample_travel-tg-lounge sample_travel-dc-lounge])
      )
    end
  end

  describe "a per-community override in communities.settings" do
    it "honours settings['announce_room'] over both the default room and the fallback" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, SAMPLE_TRAVEL_YAML, "sample_travel-volunteers")
      models = build_models(store.db)
      sample_travel = models.community.where(slug: "sample_travel-volunteers").first
      sample_travel.update(settings: JSON.generate("announce_room" => "volunteers"))
      runtime.registry.reload
      enable_banner(store, runtime)
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(posted).to include(match_array(%w[sample_travel-tg-volunteers sample_travel-dc-volunteers]))
      expect(posted).not_to include(match_array(%w[sample_travel-tg-lounge sample_travel-dc-lounge]))
    end
  end

  # ControlPlane::Seed writes announce.room nested under community.settings,
  # exactly the shape the loader's own announce: block carries. Nothing used
  # to read that nested shape back, only the flat settings['announce_room']
  # key a dashboard override writes, so a seeded announce.room was ignored.
  describe "a room named by the community's own seeded announce.room (issue #780)" do
    it "honours community.settings['announce']['room'], the shape Seed actually writes" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, "#{SAMPLE_TRAVEL_YAML}announce:\n  room: volunteers\n", "sample_travel-volunteers")
      runtime.registry.reload
      enable_banner(store, runtime)
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      expect(posted).to contain_exactly(
        match_array(%w[tg-general dc-general]),
        match_array(%w[sample_travel-tg-volunteers sample_travel-dc-volunteers])
      )
    end
  end

  # config.announce? reflects only the RUNNING process's own static YAML,
  # which a database-only deployment has none of. A live community's banner
  # must not depend on it: each community has its own switch
  # (Features::StartupBanner) and its own room (#announce_room_for).
  describe "when the running process's own config has no announce section at all (issue #780)" do
    it "still posts a live community's banner from its own feature switch, not gated on config.announce?" do
      fileless_config = Rubotty::Config::Loader.load_string(SAMPLE_TRAVEL_YAML, env: { "TG" => "t", "DC" => "d" })
      expect(fileless_config.announce?).to be(false)

      store = sequel_store
      runtime = described_class.new(
        config: fileless_config, logger: Rubotty::Log.null, storage: store, env: { "TG" => "t", "DC" => "d" }
      ).build
      enable_banner(store, runtime)
      posted = capture_posts(runtime)

      runtime.send(:announce_startup)

      # sample_travel has no general, so it falls back to lounge, alphabetically first.
      expect(posted).to contain_exactly(match_array(%w[sample_travel-tg-lounge sample_travel-dc-lounge]))
    end
  end

  describe "a community with no rooms at all" do
    it "is skipped with an INFO log, does not crash, and lets the others post" do
      io = StringIO.new
      store = sequel_store
      runtime = build_runtime(store: store, logger: Rubotty::Log.build(level: "info", io: io))
      seed_roomless_community(store, "fresh-co")
      runtime.registry.reload
      enable_banner(store, runtime)
      posted = capture_posts(runtime)

      expect { runtime.send(:announce_startup) }.not_to raise_error

      # The roomless community produced no banner, but sample still did.
      expect(posted).to contain_exactly(match_array(%w[tg-general dc-general]))
      expect(io.string).to include("community fresh-co: no room yet, skipping the startup banner")
      expect(io.string).to include("INFO")
    end
  end

  describe "independent per-community suppression" do
    it "suppresses only the community whose build already announced, not the others" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, SAMPLE_TRAVEL_YAML, "sample_travel-volunteers")
      runtime.registry.reload

      # The suppressor's version identity is VERSION+commit, so this pre-seeded
      # record has to match that shape or it never counts as the same build.
      Rubotty::Core::Announcement::Suppressor.new(
        storage: store, window: config.announce_suppress_window,
        version: "#{Rubotty::VERSION}+#{Rubotty::Core::BuildInfo.commit}", scope: "sample_travel-volunteers"
      ).claim

      enable_banner(store, runtime)
      posted = capture_posts(runtime)
      runtime.send(:announce_startup)

      expect(posted).to contain_exactly(match_array(%w[tg-general dc-general]))
    end

    it "records suppression per community, so an immediate re-announce silences all of them" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, SAMPLE_TRAVEL_YAML, "sample_travel-volunteers")
      runtime.registry.reload

      enable_banner(store, runtime)
      posted = capture_posts(runtime)
      runtime.send(:announce_startup) # both post and record their own scope
      expect(posted.size).to eq(2)

      posted.clear
      runtime.send(:announce_startup) # same build, within window: both suppressed
      expect(posted).to be_empty
    end
  end

  # The seed copies the whole static announce block into communities.settings
  # at creation time. A community whose own block names delete_after wins over
  # the deployment-wide static value for that community, and only that one.
  describe "a community's own announce block (issue #1649)" do
    SAMPLE_TRAVEL_WITH_ANNOUNCE_YAML = <<~YAML
      name: sample_travel volunteers
      accounts:
        tg: { adapter: telegram, token_env: TG }
        dc: { adapter: discord, token_env: DC }
      storage:
        driver: memory
      announce:
        delete_after: 999
      rooms:
        - id: volunteers
          endpoints:
            - { id: sample_travel-tg-volunteers, adapter: telegram, account: tg, chat_id: "-200111" }
            - { id: sample_travel-dc-volunteers, adapter: discord, account: dc, channel_id: "2001110000000000" }
    YAML

    def capture_posts_with_delay(runtime)
      posted = []
      allow(runtime.ephemeral).to receive(:post) do |endpoints:, delete_after:, **_rest|
        posted << { room: endpoints.map(&:id), delete_after: delete_after }
        instance_double(Rubotty::Core::EphemeralMessage::Group, any?: false, delete_now: nil)
      end
      posted
    end

    it "uses the community's own delete_after, not the deployment-wide default" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, SAMPLE_TRAVEL_WITH_ANNOUNCE_YAML, "sample_travel-volunteers")
      runtime.registry.reload

      enable_banner(store, runtime, slugs: ["sample_travel-volunteers"])
      posted = capture_posts_with_delay(runtime)
      runtime.send(:announce_startup)

      sample_travel_post = posted.find { |entry| entry[:room].include?("sample_travel-tg-volunteers") }
      expect(sample_travel_post[:delete_after]).to eq(999)
      expect(config.announce_delete_after).not_to eq(999)
    end

    it "leaves a community with no announce block of its own on the deployment-wide default" do
      store = sequel_store
      runtime = build_runtime(store: store)
      seed_community(store, SAMPLE_TRAVEL_YAML, "sample_travel-volunteers")
      runtime.registry.reload

      enable_banner(store, runtime, slugs: ["sample_travel-volunteers"])
      posted = capture_posts_with_delay(runtime)
      runtime.send(:announce_startup)

      expect(posted.size).to eq(1)
      expect(posted.first[:delete_after]).to eq(config.announce_delete_after)
    end
  end
end
