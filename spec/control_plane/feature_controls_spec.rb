# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::FeatureControls, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }

  subject(:controls) { described_class.new(models: models) }

  def community = controls.community!("sample")

  # The raw row, so a spec asserts on what was written rather than the decorated read.
  def row_for(feature:, room_id:)
    models.feature_setting.where(community_id: community.id, room_id: room_id, feature: feature).first
  end

  def room_id_for(room_key)
    models.room.where(community_id: community.id, room_key: room_key).first.id
  end

  # Every statement the block sent, in order. SQLite drops FOR UPDATE from the
  # SQL it is given, so the assertable part of the lock is that the read happens
  # between BEGIN and COMMIT rather than in front of them.
  def capture_sql(&block)
    log = StringIO.new
    db.loggers << Logger.new(log, formatter: ->(_s, _t, _p, msg) { "#{msg}\n" })
    block.call
    log.string.lines.filter_map { |line| line[/\(\d+\.\d+s\)\s*(.*)/, 1] || line[/\A(BEGIN|COMMIT|ROLLBACK)/, 1] }
  ensure
    db.loggers.clear
  end

  describe "#community!" do
    it "returns the community row for a known slug" do
      expect(controls.community!("sample").slug).to eq("sample")
    end

    it "raises Invalid naming the unknown slug" do
      expect { controls.community!("nope") }
        .to raise_error(described_class::Invalid, /no community with slug "nope"/)
    end
  end

  describe "#enable / #disable at the community scope (room_id NULL)" do
    it "creates the community-default row enabled" do
      controls.enable(community: community, selector: "all", feature: "faq")
      row = row_for(feature: "faq", room_id: nil)
      expect(row).not_to be_nil
      expect(row.room_id).to be_nil
      expect([true, 1]).to include(row.enabled)
    end

    it "disables an existing community-default row without dropping it" do
      controls.enable(community: community, selector: "all", feature: "faq")
      controls.disable(community: community, selector: "all", feature: "faq")
      row = row_for(feature: "faq", room_id: nil)
      expect([false, 0]).to include(row.enabled)
    end
  end

  describe "#reset" do
    it "removes a room's own row, so it falls back to inheriting the community default" do
      controls.enable(community: community, selector: "all", feature: "faq")
      controls.disable(community: community, selector: "general", feature: "faq")
      expect(row_for(feature: "faq", room_id: room_id_for("general"))).not_to be_nil

      removed = controls.reset(community: community, selector: "general", feature: "faq")
      expect(removed).to be(true)
      expect(row_for(feature: "faq", room_id: room_id_for("general"))).to be_nil
      expect(controls.list(community, selector: "general")).to be_empty
    end

    it "returns false for a room with no row for that feature, and leaves nothing behind" do
      removed = controls.reset(community: community, selector: "general", feature: "faq")
      expect(removed).to be(false)
    end

    it "refuses the community-wide (all) scope, which has no broader default to fall back to" do
      controls.enable(community: community, selector: "all", feature: "faq")
      expect { controls.reset(community: community, selector: "all", feature: "faq") }
        .to raise_error(described_class::Invalid, /no broader scope/)
      expect(row_for(feature: "faq", room_id: nil)).not_to be_nil
    end
  end

  describe "#enable at a room scope" do
    it "targets a room by its room_key, writing a single row" do
      rows = controls.enable(community: community, selector: "general", feature: "word_filter")
      expect(rows.map { |r| r[:room_key] }).to eq(["general"])
      expect(row_for(feature: "word_filter", room_id: room_id_for("general"))).not_to be_nil
      # A different room's rows are untouched.
      expect(row_for(feature: "word_filter", room_id: room_id_for("gaming"))).to be_nil
    end

    it "resolves a room by its case-insensitive label too" do
      rows = controls.enable(community: community, selector: "GENERAL", feature: "faq")
      expect(rows.map { |r| r[:room_key] }).to eq(["general"])
    end

    it "resolves an endpoint_key selector to that endpoint's room, for backward compatibility" do
      rows = controls.enable(community: community, selector: "tg-general", feature: "word_filter")
      expect(rows.map { |r| r[:room_key] }).to eq(["general"])
      row = row_for(feature: "word_filter", room_id: room_id_for("general"))
      expect(row).not_to be_nil
      # One row per room, not per endpoint, so the room's other endpoint hits
      # the same row rather than fanning out to a second.
      controls.enable(community: community, selector: "dc-general", feature: "word_filter")
      expect(models.feature_setting.where(community_id: community.id, feature: "word_filter").count).to eq(1)
    end

    it "resolves a route_key selector to that endpoint's room too" do
      route_key = models.channel.where(community_id: community.id, endpoint_key: "tg-general").first.route_key
      rows = controls.enable(community: community, selector: route_key, feature: "faq")
      expect(rows.map { |r| r[:room_key] }).to eq(["general"])
    end
  end

  # 270d4c6 (#794) made route_key non-unique so an IRC hub group can hold
  # several channel rows sharing one, with at most one receives: true.
  # room_via_endpoint (which the CLI's room selector hits directly) has to
  # prefer that row the same way Seed and Snapshot already do.
  describe "resolving a hub group's shared route_key" do
    def hub_room(endpoint_key:, route_key:, receives:)
      connection = models.platform_connection.where(community_id: community.id, adapter: "telegram").first
      room = models.room.create(community_id: community.id, room_key: endpoint_key, label: endpoint_key,
                                display_name: "{}", created_at: now, updated_at: now)
      channel = models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: "irc", account: "irc-hub", route_key: route_key,
        endpoint_key: endpoint_key, label: endpoint_key, receives: receives,
        sends: true, relay: "{}", display_name: "{}", settings: "{}", created_at: now, updated_at: now
      )
      models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: now)
      room
    end

    let(:now) { Time.new(2026, 7, 23, 12, 0, 0) }

    it "targets the receiving channel's room, not whichever loads first" do
      hub_room(endpoint_key: "irc-hub-gaming", route_key: "#sample", receives: false)
      travel = hub_room(endpoint_key: "irc-hub-travel", route_key: "#sample", receives: true)

      rows = controls.enable(community: community, selector: "#sample", feature: "faq")

      expect(rows.map { |r| r[:room_key] }).to eq([travel.room_key])
    end
  end

  # The read and the write have to be one transaction holding the row, or two
  # operators saving at once each write back a value the other never saw.
  describe "#update reads and writes one key under a lock" do
    it "yields the key's current value and stores what the block returns" do
      controls.set(community: community, selector: "all", feature: "faq", key: "entries", value: '["a"]')

      seen = nil
      controls.update(community: community, selector: "all", feature: "faq", key: "entries") do |current|
        seen = current
        JSON.generate(current + ["b"])
      end

      expect(seen).to eq(["a"])
      expect(row_for(feature: "faq", room_id: nil).json_value(:config)).to eq("entries" => %w[a b])
    end

    it "yields nil for a key nothing has written yet, and creates the row" do
      seen = :untouched
      controls.update(community: community, selector: "all", feature: "faq", key: "entries") do |current|
        seen = current
        '["first"]'
      end

      expect(seen).to be_nil
      expect(row_for(feature: "faq", room_id: nil).json_value(:config)).to eq("entries" => ["first"])
    end

    it "leaves the other keys in the blob alone" do
      controls.set(community: community, selector: "all", feature: "faq", key: "mode", value: "native")

      controls.update(community: community, selector: "all", feature: "faq", key: "entries") { '["a"]' }

      expect(row_for(feature: "faq", room_id: nil).json_value(:config))
        .to eq("mode" => "native", "entries" => ["a"])
    end

    it "writes nothing when the block raises" do
      controls.set(community: community, selector: "all", feature: "faq", key: "entries", value: '["a"]')

      expect do
        controls.update(community: community, selector: "all", feature: "faq", key: "entries") do
          raise described_class::Invalid, "no"
        end
      end.to raise_error(described_class::Invalid)

      expect(row_for(feature: "faq", room_id: nil).json_value(:config)).to eq("entries" => ["a"])
    end

    it "reads the row inside the write's own transaction, which is what the lock needs" do
      statements = capture_sql do
        controls.update(community: community, selector: "all", feature: "faq", key: "entries") { '["a"]' }
      end

      opened = statements.index { |sql| sql.start_with?("BEGIN") }
      read = statements.index { |sql| sql.start_with?("SELECT") && sql.include?("feature_settings") }
      closed = statements.index { |sql| sql.start_with?("COMMIT") }
      expect([opened, read, closed]).to all(be_a(Integer))
      expect(opened).to be < read
      expect(read).to be < closed
    end

    it "reads inside the transaction on a plain set too" do
      statements = capture_sql do
        controls.set(community: community, selector: "all", feature: "faq", key: "mode", value: "native")
      end

      opened = statements.index { |sql| sql.start_with?("BEGIN") }
      read = statements.index { |sql| sql.start_with?("SELECT") && sql.include?("feature_settings") }
      expect(opened).to be < read
    end

    it "rejects an empty key" do
      expect { controls.update(community: community, selector: "all", feature: "faq", key: "") { "x" } }
        .to raise_error(described_class::Invalid, /config key/)
    end

    it "rejects an unknown feature before it touches anything" do
      expect { controls.update(community: community, selector: "all", feature: "nope", key: "k") { "x" } }
        .to raise_error(described_class::Invalid, /unknown feature/)
    end
  end

  describe "#set merges into the config blob" do
    it "sets a scalar key without disturbing others" do
      controls.set(community: community, selector: "all", feature: "faq", key: "threshold", value: "3")
      controls.set(community: community, selector: "all", feature: "faq", key: "mode", value: "native")
      config = row_for(feature: "faq", room_id: nil).json_value(:config)
      expect(config).to eq("threshold" => 3, "mode" => "native")
    end

    it "accepts a comma list as an array value (word-filter entries)" do
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "blocked", value: "foo, bar, baz")
      config = row_for(feature: "word_filter", room_id: room_id_for("general")).json_value(:config)
      expect(config).to eq("blocked" => %w[foo bar baz])
    end

    it "accepts an explicit JSON value" do
      controls.set(community: community, selector: "all", feature: "word_filter",
                   key: "entries", value: '["one","two"]')
      config = row_for(feature: "word_filter", room_id: nil).json_value(:config)
      expect(config).to eq("entries" => %w[one two])
    end

    it "does not enable the feature, only stages its config" do
      controls.set(community: community, selector: "all", feature: "faq", key: "mode", value: "native")
      expect([false, 0]).to include(row_for(feature: "faq", room_id: nil).enabled)
    end

    it "merges a later set into an already-enabled row, preserving enablement" do
      controls.enable(community: community, selector: "all", feature: "faq")
      controls.set(community: community, selector: "all", feature: "faq", key: "mode", value: "native")
      row = row_for(feature: "faq", room_id: nil)
      expect([true, 1]).to include(row.enabled)
      expect(row.json_value(:config)).to eq("mode" => "native")
    end

    it "creates a brand-new room row enabled when the community default is already on" do
      controls.enable(community: community, selector: "all", feature: "word_filter")
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "mode", value: "slurs_profanity")
      row = row_for(feature: "word_filter", room_id: room_id_for("general"))
      # A room row takes unconditional priority over the community default the
      # moment it exists, so starting it disabled would turn an already-enabled
      # feature off for this room just because a mode change was staged.
      expect([true, 1]).to include(row.enabled)
      expect(row.json_value(:config)).to eq("mode" => "slurs_profanity")
    end

    it "creates a brand-new room row disabled when the community default is off (or unset)" do
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "mode", value: "slurs")
      row = row_for(feature: "word_filter", room_id: room_id_for("general"))
      expect([false, 0]).to include(row.enabled)
    end

    it "leaves an EXISTING room row's enabled state untouched, whichever way the community default sits" do
      controls.enable(community: community, selector: "general", feature: "word_filter")
      controls.enable(community: community, selector: "all", feature: "word_filter")
      controls.disable(community: community, selector: "all", feature: "word_filter")
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "mode", value: "slurs")
      row = row_for(feature: "word_filter", room_id: room_id_for("general"))
      expect([true, 1]).to include(row.enabled)
    end
  end

  describe "#global_entry / #set_global (the deployment-wide default, community_id AND room_id both nil)" do
    def global_row_for(feature)
      models.feature_setting.where(community_id: nil, room_id: nil, feature: feature).first
    end

    # Migration 081 seeds this one on every deployment, so it is not a clean
    # slate the way another feature's global row still is at this point.
    it "already carries the migration's own seed for moderation" do
      expect(controls.global_entry("moderation")).to eq(
        scope: :global, room_key: nil, feature: "moderation", enabled: true,
        config: { "ack_ttl_seconds" => 30, "acknowledge" => true }
      )
    end

    it "answers nil for a feature nothing has ever set" do
      expect(controls.global_entry("faq")).to be_nil
    end

    it "creates the row enabled on the first write" do
      controls.set_global(feature: "faq", key: "mode", value: "native")
      row = global_row_for("faq")
      expect(row).not_to be_nil
      expect(row.community_id).to be_nil
      expect(row.room_id).to be_nil
      expect([true, 1]).to include(row.enabled)
      expect(row.json_value(:config)).to eq("mode" => "native")
    end

    it "merges a later key into the same row without disturbing the first" do
      controls.set_global(feature: "faq", key: "mode", value: "native")
      controls.set_global(feature: "faq", key: "threshold", value: "3")
      row = global_row_for("faq")
      expect(row.json_value(:config)).to eq("mode" => "native", "threshold" => 3)
    end

    it "leaves an existing row's enabled state alone on a later write" do
      controls.set_global(feature: "faq", key: "mode", value: "native")
      global_row_for("faq").update(enabled: false)
      controls.set_global(feature: "faq", key: "threshold", value: "3")
      expect([false, 0]).to include(global_row_for("faq").enabled)
    end

    it "reports the global scope through #global_entry" do
      controls.set_global(feature: "faq", key: "mode", value: "native")
      entry = controls.global_entry("faq")
      expect(entry[:scope]).to eq(:global)
      expect(entry[:room_key]).to be_nil
      expect(entry[:config]).to eq("mode" => "native")
    end

    it "never touches a community's own rows for the same feature" do
      controls.enable(community: community, selector: "all", feature: "moderation")
      controls.set(community: community, selector: "all", feature: "moderation", key: "ack_ttl_seconds", value: "5")

      controls.set_global(feature: "moderation", key: "ack_ttl_seconds", value: "45")

      expect(row_for(feature: "moderation", room_id: nil).json_value(:config)).to eq("ack_ttl_seconds" => 5)
      expect(global_row_for("moderation").json_value(:config)).to include("ack_ttl_seconds" => 45)
    end

    it "rejects an unknown feature name the same way #set does" do
      expect { controls.set_global(feature: "reactions", key: "x", value: "1") }
        .to raise_error(described_class::Invalid, /unknown feature "reactions"/)
    end

    it "rejects a write against a feature that always runs and has no toggle" do
      expect { controls.set_global(feature: "identify_topic", key: "x", value: "1") }
        .to raise_error(described_class::Invalid, /identify_topic always runs here/)
    end

    it "rejects an empty config key" do
      expect { controls.set_global(feature: "faq", key: "", value: "1") }
        .to raise_error(described_class::Invalid, /config key is required/)
    end
  end

  describe "#coerce_value" do
    it "keeps a bare word as a string" do
      expect(controls.coerce_value("native")).to eq("native")
    end

    it "parses JSON scalars and containers" do
      expect(controls.coerce_value("true")).to be(true)
      expect(controls.coerce_value("false")).to be(false)
      expect(controls.coerce_value("42")).to eq(42)
      expect(controls.coerce_value('{"k":1}')).to eq("k" => 1)
      expect(controls.coerce_value('"a,b"')).to eq("a,b")
    end

    it "splits a comma list into trimmed strings where the schema declares a list" do
      expect(controls.coerce_value("a, b ,c", feature: "word_filter", key: "custom")).to eq(%w[a b c])
    end

    # The bug this rule exists for: topic_routing's subject is prose asking for
    # semicolon separated clauses, and it came back cut at every comma.
    it "leaves a string field alone however many commas it has" do
      prose = "General chat about moving to Portugal, the golden visa, and life here"
      expect(controls.coerce_value(prose, feature: "topic_routing", key: "subject")).to eq(prose)
    end

    # A key the schema does not describe keeps the old convenience: taking it
    # away would silently change values nothing here can reason about.
    it "still splits where nothing names the field it is going into" do
      expect(controls.coerce_value("a, b ,c")).to eq(%w[a b c])
    end

    it "still splits a key the schema does not declare" do
      expect(controls.coerce_value("a, b", feature: "word_filter", key: "nonesuch")).to eq(%w[a b])
    end

    # The accidental way through people found before this was fixed, and it
    # still has to work, since it is what the stored subjects were written with.
    it "still takes an explicit JSON string for a list field" do
      expect(controls.coerce_value('"a, b"', feature: "word_filter", key: "custom")).to eq("a, b")
    end

    it "stores a real Hash as-is, rather than stringifying it first" do
      value = { "question" => "hi", "answer" => "there" }
      expect(controls.coerce_value(value)).to eq(value)
    end

    it "stores a real array of Hashes as-is" do
      value = [{ "question" => "hi", "answer" => "there" }, { "question" => "bye", "answer" => "now" }]
      expect(controls.coerce_value(value)).to eq(value)
    end

    it "stores a real array of strings as-is" do
      expect(controls.coerce_value(%w[foo bar])).to eq(%w[foo bar])
    end

    it "stores a real numeric or boolean as-is" do
      expect(controls.coerce_value(42)).to eq(42)
      expect(controls.coerce_value(true)).to be(true)
      expect(controls.coerce_value(false)).to be(false)
    end
  end

  describe "#set config coercion round trip" do
    def set_and_read(feature:, key:, value:)
      controls.set(community: community, selector: "all", feature: feature, key: key, value: value)
      row_for(feature: feature, room_id: nil).json_value(:config).fetch(key)
    end

    it "round-trips a Hash value" do
      value = { "question" => "hi", "answer" => "there" }
      expect(set_and_read(feature: "faq", key: "entries", value: value)).to eq(value)
    end

    it "round-trips an array of Hashes" do
      value = [{ "question" => "hi", "answer" => "there" }, { "question" => "bye", "answer" => "now" }]
      expect(set_and_read(feature: "faq", key: "entries", value: value)).to eq(value)
    end

    it "round-trips a flat array of strings" do
      expect(set_and_read(feature: "word_filter", key: "custom", value: %w[foo bar])).to eq(%w[foo bar])
    end

    it "round-trips a numeric" do
      expect(set_and_read(feature: "faq", key: "threshold", value: 3)).to eq(3)
    end

    it "round-trips a boolean" do
      expect(set_and_read(feature: "faq", key: "strict", value: true)).to be(true)
    end

    it "round-trips a bare word" do
      expect(set_and_read(feature: "faq", key: "mode", value: "native")).to eq("native")
    end

    it "round-trips a comma-separated string as a list where the schema declares one" do
      expect(set_and_read(feature: "word_filter", key: "custom", value: "foo, bar, baz")).to eq(%w[foo bar baz])
    end

    it "round-trips prose into a string field with its commas intact" do
      prose = "Moving to Portugal, the golden visa, and life here"
      expect(set_and_read(feature: "topic_routing", key: "subject", value: prose)).to eq(prose)
    end

    it "round-trips an explicit JSON string" do
      expect(set_and_read(feature: "word_filter", key: "entries", value: '["one","two"]')).to eq(%w[one two])
    end
  end

  describe "validation" do
    # The form offers 0 to 1 in tenths; nothing runs a feature's config_schema
    # against a stored blob, so without this the API and the CLI would write a
    # confidence the control could never have offered.
    it "refuses a confidence outside the range its schema declares" do
      expect do
        controls.set(community: community, selector: "all", feature: "content_policy",
                     key: "minimum_confidence", value: "-0.2")
      end.to raise_error(described_class::Invalid, /between 0.0 and 1.0/)
    end

    it "refuses one above the range too" do
      expect do
        controls.set(community: community, selector: "all", feature: "content_policy",
                     key: "minimum_confidence", value: "47")
      end.to raise_error(described_class::Invalid, /between 0.0 and 1.0/)
    end

    it "takes a confidence inside it, including either end" do
      expect do
        controls.set(community: community, selector: "all", feature: "content_policy",
                     key: "minimum_confidence", value: "0.8")
        controls.set(community: community, selector: "all", feature: "content_policy",
                     key: "minimum_confidence", value: "0")
        controls.set(community: community, selector: "all", feature: "content_policy",
                     key: "minimum_confidence", value: "1")
      end.not_to raise_error
    end

    # The control offers 0 to 1 in twentieths; a value typed straight at the API
    # or the CLI is put on that same scale rather than stored off it.
    it "rounds a confidence onto the step its schema declares" do
      { "0.77" => 0.75, "0.73" => 0.75, "0.72" => 0.7, "0.63" => 0.65 }.each do |given, wanted|
        controls.set(community: community, selector: "all", feature: "content_policy",
                     key: "minimum_confidence", value: given)
        stored = controls.list(community).find { |row| row[:feature] == "content_policy" }[:config]
        expect(stored["minimum_confidence"]).to eq(wanted)
      end
    end

    it "leaves a value already on the step exactly where it was" do
      controls.set(community: community, selector: "all", feature: "content_policy",
                   key: "minimum_confidence", value: "0.75")
      stored = controls.list(community).find { |row| row[:feature] == "content_policy" }[:config]

      expect(stored["minimum_confidence"]).to eq(0.75)
    end

    it "leaves a number whose schema declared no step alone" do
      controls.set(community: community, selector: "all", feature: "content_policy",
                   key: "removal_notice_ttl_seconds", value: "77")
      stored = controls.list(community).find { |row| row[:feature] == "content_policy" }[:config]

      expect(stored["removal_notice_ttl_seconds"]).to eq(77)
    end

    it "leaves a number whose schema declared no range alone" do
      expect do
        controls.set(community: community, selector: "all", feature: "content_policy",
                     key: "removal_notice_ttl_seconds", value: "9999")
      end.not_to raise_error
    end

    it "rejects an unknown feature name" do
      expect { controls.enable(community: community, selector: "all", feature: "reactions") }
        .to raise_error(described_class::Invalid, /unknown feature "reactions"/)
    end

    it "rejects a room selector that matches nothing" do
      expect { controls.enable(community: community, selector: "zzz", feature: "faq") }
        .to raise_error(described_class::Invalid, /matched "zzz"/)
    end

    it "rejects a write against a feature that always runs and has no toggle" do
      expect { controls.enable(community: community, selector: "all", feature: "identify_topic") }
        .to raise_error(described_class::Invalid, /identify_topic always runs here/)
      expect { controls.disable(community: community, selector: "all", feature: "disabled_command_notice") }
        .to raise_error(described_class::Invalid, /disabled_command_notice always runs here/)
      expect(row_for(feature: "identify_topic", room_id: nil)).to be_nil
    end

    it "rejects an empty config key" do
      expect { controls.set(community: community, selector: "all", feature: "faq", key: "", value: "x") }
        .to raise_error(described_class::Invalid, /config key is required/)
    end
  end

  # safe_horizon_seconds set equal to (or past) relay_claim_ttl means a
  # message at the edge of the window can have its dedup claim expire the
  # same instant the sweep re-reads it, so it goes out a second time.
  describe "backfill horizon validation" do
    let(:margin) { described_class::BACKFILL_HORIZON_MARGIN_SECONDS }

    it "accepts a horizon comfortably under the default relay_claim_ttl, unchanged" do
      controls.set(community: community, selector: "all", feature: "backfill",
                   key: "safe_horizon_seconds", value: "259200")
      config = row_for(feature: "backfill", room_id: nil).json_value(:config)
      expect(config).to eq("safe_horizon_seconds" => 259_200)
    end

    it "accepts a horizon right at the margin boundary" do
      ceiling = Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL - margin
      controls.set(community: community, selector: "all", feature: "backfill",
                   key: "safe_horizon_seconds", value: ceiling.to_s)
      config = row_for(feature: "backfill", room_id: nil).json_value(:config)
      expect(config).to eq("safe_horizon_seconds" => ceiling)
    end

    it "refuses a horizon one second past the margin boundary, proving it is a real margin and not a bare less-than" do
      over = Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL - margin + 1
      expect do
        controls.set(community: community, selector: "all", feature: "backfill",
                     key: "safe_horizon_seconds", value: over.to_s)
      end.to raise_error(described_class::Invalid, /safe_horizon_seconds/)
      expect(row_for(feature: "backfill", room_id: nil)).to be_nil
    end

    it "refuses a horizon exactly equal to relay_claim_ttl, the value #503 shipped with" do
      ttl = Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL
      expect do
        controls.set(community: community, selector: "all", feature: "backfill",
                     key: "safe_horizon_seconds", value: ttl.to_s)
      end.to raise_error(described_class::Invalid, /relay_claim_ttl/)
    end

    it "refuses a horizon above relay_claim_ttl" do
      over = Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL + 100
      expect do
        controls.set(community: community, selector: "all", feature: "backfill",
                     key: "safe_horizon_seconds", value: over.to_s)
      end.to raise_error(described_class::Invalid, /relay_claim_ttl/)
    end

    it "checks against the relay_claim_ttl actually configured, not the class default" do
      shorter = described_class.new(models: models, relay_claim_ttl: 100_000)

      # Valid at 100_000 - margin, rejected at the class default's ceiling.
      shorter.set(community: community, selector: "all", feature: "backfill",
                  key: "safe_horizon_seconds", value: (100_000 - margin).to_s)
      expect(row_for(feature: "backfill", room_id: nil).json_value(:config))
        .to eq("safe_horizon_seconds" => 100_000 - margin)

      expect do
        shorter.set(community: community, selector: "all", feature: "backfill",
                    key: "safe_horizon_seconds", value: (100_000 - margin + 1).to_s)
      end.to raise_error(described_class::Invalid, /relay_claim_ttl/)
    end

    it "refuses a decimal-looking value above relay_claim_ttl instead of letting the Float skip the check" do
      over = Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL + 100
      expect do
        controls.set(community: community, selector: "all", feature: "backfill",
                     key: "safe_horizon_seconds", value: "#{over}.0")
      end.to raise_error(described_class::Invalid, /relay_claim_ttl/)
      expect(row_for(feature: "backfill", room_id: nil)).to be_nil
    end

    it "applies the same rule through #update, not just #set" do
      expect do
        controls.update(community: community, selector: "all", feature: "backfill",
                        key: "safe_horizon_seconds") { Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL.to_s }
      end.to raise_error(described_class::Invalid, /relay_claim_ttl/)
      expect(row_for(feature: "backfill", room_id: nil)).to be_nil
    end

    it "leaves every other feature and key alone" do
      controls.set(community: community, selector: "all", feature: "faq",
                   key: "safe_horizon_seconds", value: Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL.to_s)
      controls.set(community: community, selector: "all", feature: "backfill",
                   key: "lookback_seconds", value: Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL.to_s)

      expect(row_for(feature: "faq", room_id: nil).json_value(:config))
        .to eq("safe_horizon_seconds" => Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL)
      expect(row_for(feature: "backfill", room_id: nil).json_value(:config))
        .to eq("lookback_seconds" => Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL)
    end
  end

  describe "#list" do
    before do
      controls.enable(community: community, selector: "all", feature: "faq")
      controls.enable(community: community, selector: "general", feature: "word_filter")
    end

    it "returns every scope when no selector is given" do
      features = controls.list(community).map { |e| e[:feature] }
      # The seed writes bridge and operator_requests at the community scope.
      expect(features).to include("bridge", "operator_requests", "faq", "word_filter")
    end

    it "returns only the community defaults for the all selector" do
      entries = controls.list(community, selector: "all")
      expect(entries).to all(include(scope: :community, room_key: nil))
      expect(entries.map { |e| e[:feature] }).to include("faq")
      expect(entries.map { |e| e[:feature] }).not_to include("word_filter")
    end

    it "returns only the named room's rows for a room selector" do
      entries = controls.list(community, selector: "general")
      expect(entries.map { |e| e[:feature] }).to eq(["word_filter"])
      expect(entries.first[:room_key]).to eq("general")
    end

    it "returns the same room's rows whichever of its endpoint_keys names the selector" do
      entries = controls.list(community, selector: "dc-general")
      expect(entries.map { |e| e[:feature] }).to eq(["word_filter"])
      expect(entries.first[:room_key]).to eq("general")
    end
  end

  describe "the updated_at bump every write makes (the change marker source)" do
    it "advances feature_settings.updated_at on an enable" do
      frozen = Time.utc(2030, 1, 1, 12, 0, 0)
      stamped = described_class.new(models: models, clock: -> { frozen })
      stamped.enable(community: community, selector: "all", feature: "faq")
      row = row_for(feature: "faq", room_id: nil)
      expect(row.updated_at.to_i).to eq(frozen.to_i)
    end
  end

  describe "live reflection in a reloaded Snapshot (a write through a wired Registry)" do
    subject(:registry) do
      Rubotty::ControlPlane::Registry.build(models: models, accounts: sample_model.accounts)
    end

    it "makes an enabled feature visible to the pipeline's enablement check" do
      wired = described_class.new(models: models, registry: registry)
      snap_before = registry.current
      channel = snap_before.channel_by_endpoint_key("tg-general")
      expect(snap_before.community("sample").feature_enabled?(channel, "word_filter")).to be(false)

      wired.enable(community: wired.community!("sample"), selector: "tg-general", feature: "word_filter")

      # A fresh snapshot, carrying what Pipeline#enabled? consults.
      snap_after = registry.current
      expect(snap_after).not_to be(snap_before)
      channel_after = snap_after.channel_by_endpoint_key("tg-general")
      expect(snap_after.community("sample").feature_enabled?(channel_after, "word_filter")).to be(true)
      # A room-scoped write reaches the room's other endpoint too.
      dc_after = snap_after.channel_by_endpoint_key("dc-general")
      expect(snap_after.community("sample").feature_enabled?(dc_after, "word_filter")).to be(true)
    end

    it "makes a deployment-wide default visible to Snapshot#feature_config_default" do
      wired = described_class.new(models: models, registry: registry)
      # Migration 081 seeds moderation's own row; a feature with no row of its
      # own starts from a clean {}.
      expect(registry.current.feature_config_default("faq")).to eq({})

      wired.set_global(feature: "faq", key: "mode", value: "native")

      expect(registry.current.feature_config_default("faq")).to eq(mode: "native")
    end
  end
end
