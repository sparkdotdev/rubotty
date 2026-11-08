# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# Operator authored scripts in the database, and the rule that only a
# verified one may run. The property worth pinning hardest is that
# verification cannot survive an edit: everything else here is
# bookkeeping, that one is the difference between a gate and a decoration.
RSpec.describe Rubotty::ControlPlane::Scripts, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:smoke) { nil }

  subject(:scripts) do
    described_class.new(models: models, logger: Rubotty::Log.null, smoke_test: smoke)
  end

  def save(name: "greeter", kind: "processor", source: 'return { action = "allow" }',
           trigger_type: "always", trigger_config: {}, **rest)
    scripts.save(community: community, name: name, kind: kind, source: source,
                 trigger_type: trigger_type, trigger_config: trigger_config, **rest)
  end

  describe "saving" do
    it "stores a script disabled and unverified, however good it looks" do
      row = save

      expect(row.enabled).to be_falsey
      expect(row.verified_digest).to be_nil
      expect(scripts.runnable?(row)).to be(false)
    end

    it "keeps work in progress rather than refusing a broken body" do
      row = save(source: "this is not lua at all")

      expect(row.id).not_to be_nil
      expect(scripts.list(community).map(&:name)).to eq(["greeter"])
    end

    it "updates in place rather than making a second row with the same name" do
      save
      save(source: 'return { action = "reject" }')

      expect(scripts.list(community).length).to eq(1)
      expect(scripts.list(community).first.source).to include("reject")
    end

    it "refuses a name that is empty and a kind that is neither" do
      expect { save(name: "  ") }.to raise_error(described_class::Invalid, /needs a name/)
      expect { save(kind: "watcher") }.to raise_error(described_class::Invalid, /command or a processor/)
    end

    it "refuses a trigger type outside the catalog, which is what keeps it closed" do
      expect { save(trigger_type: "arbitrary_lookback") }
        .to raise_error(Rubotty::Scripting::Failed, /no trigger type/)
    end

    # A script may declare several conditions now, and every one of
    # them is checked here. Checking only the first would let a second condition
    # naming nothing be saved, enabled, and then refuse to load at message time,
    # which is the silent kind of broken.
    it "refuses a second condition outside the catalog too" do
      expect { save(trigger_type: "always", trigger_config: { "triggers" => ["arbitrary_lookback"] }) }
        .to raise_error(Rubotty::Scripting::Failed, /no trigger type/)
    end

    it "refuses more conditions than a script may carry" do
      too_many = { "triggers" => Array.new(Rubotty::Scripting::Triggers::MAX, "contains") }

      expect { save(trigger_config: too_many) }
        .to raise_error(Rubotty::Scripting::Failed, /triggers/)
    end

    it "keeps the extras with the rest of the trigger settings" do
      row = save(trigger_type: "command",
                 trigger_config: { "name" => "deal", "triggers" => ["always"] })

      expect(scripts.trigger_config(row)["triggers"]).to eq(["always"])
    end
  end

  # The YAML data file beside a script, parsed at save so a broken document
  # is refused where somebody can see it, not on the first message it would
  # have run on. The answer is cached, so what matters here is invalidation:
  # a cache a save leaves stale would run a live rule against the old list.
  describe "the parsed data file, kept between invocations" do
    let(:document) { "words:\n  - airdrop\n" }

    it "parses once and hands back the very same document after that" do
      row = save(yaml_data: document)

      expect(scripts.yaml_data(row)).to equal(scripts.yaml_data(row))
    end

    it "parses afresh once the data file is edited" do
      row = save(yaml_data: document)
      before = scripts.yaml_data(row)
      edited = save(yaml_data: "words:\n  - airdrop\n  - free mint\n")

      expect(scripts.yaml_data(edited)).to eq({ "words" => ["airdrop", "free mint"] })
      expect(scripts.yaml_data(edited)).not_to equal(before)
    end

    # The digest folds in the source as well as the data, which is what makes
    # this work without anything having to remember to sweep the cache.
    it "parses afresh once the CODE is edited, even with the data untouched" do
      row = save(yaml_data: document)
      before = scripts.yaml_data(row)
      edited = save(source: 'return { action = "reject" }', yaml_data: document)

      expect(scripts.yaml_data(edited)).not_to equal(before)
    end

    it "is bounded by the bytes it holds rather than by how many documents" do
      stub_const("#{described_class}::MAX_CACHED_YAML_BYTES", 400)
      small = save(name: "one", yaml_data: "words:\n#{"  - short\n" * 20}")
      scripts.yaml_data(small)

      expect(scripts.cached_yaml_bytes).to be <= described_class::MAX_CACHED_YAML_BYTES
      expect(scripts.cached_yaml_bytes).to be > 0
    end

    it "hands back a document too large to keep, without keeping it" do
      stub_const("#{described_class}::MAX_CACHED_YAML_BYTES", 50)
      row = save(yaml_data: "words:\n#{"  - a phrase\n" * 20}")

      expect(scripts.yaml_data(row)).to be_a(Hash)
      expect(scripts.cached_yaml_bytes).to eq(0)
    end
  end

  describe "the data file" do
    it "stores what was typed rather than what the parser made of it" do
      row = save(yaml_data: "# a note\nwords:\n  - airdrop\n")

      expect(row.yaml_data).to include("# a note")
      expect(scripts.yaml_data(row)).to eq({ "words" => ["airdrop"] })
    end

    it "refuses a document that will not parse, and says where" do
      expect { save(yaml_data: "words:\n  - airdrop\n bad indent: yes\n") }
        .to raise_error(described_class::Invalid, /not valid YAML/)
    end

    # The reader builds core schema types and nothing else, so a tag naming a
    # class is read past rather than acted on. There is no permitted-classes
    # list to get wrong, and no document that can reach a constructor.
    it "never lets a document name a Ruby class" do
      row = save(yaml_data: "thing: !ruby/object:File {}\n")

      expect(scripts.yaml_data(row)).to eq({ "thing" => {} })
      expect(scripts.yaml_data(row)["thing"]).to be_an_instance_of(Hash)
    end

    it "refuses a document above the cap" do
      line = "  - a long enough phrase to count\n"
      oversized = "words:\n#{line * ((described_class::MAX_YAML_BYTES / line.bytesize) + 10)}"

      expect(oversized.bytesize).to be > described_class::MAX_YAML_BYTES
      expect { save(yaml_data: oversized) }
        .to raise_error(described_class::Invalid, /under #{described_class.size(described_class::MAX_YAML_BYTES)}/)
    end

    it "refuses source past its own cap, saying how much there is to cut" do
      oversized = "-- a comment line that is long enough to count\n" *
                  ((described_class::MAX_SOURCE_BYTES / 47) + 10)

      expect { save(source: oversized) }
        .to raise_error(described_class::Invalid, /A script has to be under 512 KB/)
    end

    it "refuses a document holding a single bare value, which no script can index" do
      expect { save(yaml_data: "just a sentence\n") }
        .to raise_error(described_class::Invalid, /set of keys or a list/)
    end

    it "takes a list as happily as a mapping" do
      row = save(yaml_data: "- one\n- two\n")

      expect(scripts.yaml_data(row)).to eq(%w[one two])
    end

    it "reads as no data at all when there is none, which is how a script sees nil" do
      expect(scripts.yaml_data(save)).to be_nil
      expect(scripts.yaml_data(save(yaml_data: "   \n"))).to be_nil
    end

    it "never reaches another community's data file" do
      other = models.community.create(slug: "elsewhere", name: "Elsewhere", status: "active",
                                      created_at: Time.now, updated_at: Time.now)
      save(yaml_data: "words:\n  - airdrop\n")

      expect(scripts.list(other)).to be_empty
      expect(scripts.find_by_name(other, "greeter")).to be_nil
    end
  end

  describe "the verified digest" do
    let(:smoke) { instance_double(Rubotty::Scripting::SmokeTest) }

    def passing = Rubotty::Scripting::SmokeTest::Result.new(failures: [], host_calls: 0)

    def failing(message)
      Rubotty::Scripting::SmokeTest::Result.new(
        failures: [Rubotty::Scripting::SmokeTest::Failure.new(probe: "probe 1", message: message)],
        host_calls: 0
      )
    end

    it "marks a script verified when the smoke test is clean" do
      row = save
      allow(smoke).to receive(:run).and_return(passing)

      scripts.verify(community, row.id)

      expect(scripts.verified?(scripts.find(community, row.id))).to be(true)
    end

    # The whole point. A boolean would still be true here.
    it "stops being verified the moment the source is edited" do
      row = save
      allow(smoke).to receive(:run).and_return(passing)
      scripts.verify(community, row.id)
      scripts.enable(community, row.id)

      save(source: 'return { action = "reject", reason = "changed my mind" }')

      edited = scripts.find(community, row.id)
      expect(scripts.verified?(edited)).to be(false)
      expect(edited.enabled).to be_falsey
      expect(scripts.runnable?(edited)).to be(false)
    end

    it "stops being verified when only the trigger config changes" do
      row = save(trigger_type: "contains", trigger_config: { "words" => ["spam"] })
      allow(smoke).to receive(:run).and_return(passing)
      scripts.verify(community, row.id)

      save(trigger_type: "contains", trigger_config: { "words" => %w[spam scam] })

      expect(scripts.verified?(scripts.find(community, row.id))).to be(false)
    end

    # A rule that decides from a list decides differently once the list changes,
    # so the data file has to invalidate the check exactly as the code does.
    # Without this somebody could swap the list under a script already live.
    it "stops being verified when only the data file changes" do
      row = save(yaml_data: "words:\n  - airdrop\n")
      allow(smoke).to receive(:run).and_return(passing)
      scripts.verify(community, row.id)
      scripts.enable(community, row.id)

      save(yaml_data: "words:\n  - airdrop\n  - free mint\n")

      edited = scripts.find(community, row.id)
      expect(scripts.verified?(edited)).to be(false)
      expect(edited.enabled).to be_falsey
    end

    it "checks a script against its real data file rather than against nothing" do
      row = save(yaml_data: "words:\n  - airdrop\n")
      expect(smoke).to receive(:run)
        .with(hash_including(yaml_data: { "words" => ["airdrop"] })).and_return(passing)

      scripts.verify(community, row.id)
    end

    it "records what failed so reopening the editor does not mean re-running it" do
      row = save
      allow(smoke).to receive(:run).and_return(failing("attempt to index a nil value"))

      result = scripts.verify(community, row.id)

      expect(result).not_to be_ok
      expect(scripts.find(community, row.id).verification_notes).to include("attempt to index a nil value")
    end
  end

  describe "enabling" do
    let(:smoke) { instance_double(Rubotty::Scripting::SmokeTest) }

    it "refuses a script that has not passed its smoke test" do
      row = save

      expect { scripts.enable(community, row.id) }
        .to raise_error(described_class::Invalid, /has not passed its smoke test/)
    end

    it "allows one that has, and it then counts as runnable" do
      row = save
      allow(smoke).to receive(:run)
        .and_return(Rubotty::Scripting::SmokeTest::Result.new(failures: [], host_calls: 0))
      scripts.verify(community, row.id)

      enabled = scripts.enable(community, row.id)

      expect(scripts.runnable?(enabled)).to be(true)
      expect(scripts.active(community).map(&:name)).to eq(["greeter"])
    end

    def failed_check(message)
      Rubotty::Scripting::SmokeTest::Result.new(
        failures: [Rubotty::Scripting::SmokeTest::Failure.new(probe: "probe 3", message: message)],
        host_calls: 0
      )
    end

    # The refusal has to say why last time failed, or a probe that merely ran
    # long reads exactly like a script that failed its check.
    it "says a probe timed out when that is why the check failed" do
      row = save
      allow(smoke).to receive(:run)
        .and_return(failed_check("took longer than 2s, which will time out under load"))
      scripts.verify(community, row.id)

      expect { scripts.enable(community, row.id) }
        .to raise_error(described_class::Invalid, /took longer than 2s/)
    end

    it "still names a genuine check failure, not only a timeout" do
      row = save
      allow(smoke).to receive(:run)
        .and_return(failed_check("action was missing, and it has to be allow, reject or rewrite"))
      scripts.verify(community, row.id)

      expect { scripts.enable(community, row.id) }
        .to raise_error(described_class::Invalid, /action was missing/)
    end
  end

  describe "the circuit breaker" do
    let(:smoke) { instance_double(Rubotty::Scripting::SmokeTest) }

    def live_row
      row = save
      allow(smoke).to receive(:run)
        .and_return(Rubotty::Scripting::SmokeTest::Result.new(failures: [], host_calls: 0))
      scripts.verify(community, row.id)
      scripts.enable(community, row.id)
    end

    it "counts failures without switching a script off too early" do
      row = live_row
      2.times { row = scripts.record_failure(row, "timed out") }

      expect(row.consecutive_failures).to eq(2)
      expect(scripts.runnable?(row)).to be(true)
    end

    it "switches it off once the failures keep coming" do
      row = live_row
      5.times { row = scripts.record_failure(row, "timed out") }

      expect(row.disabled_at).not_to be_nil
      expect(row.disabled_reason).to include("5 consecutive failures")
      expect(scripts.runnable?(row)).to be(false)
      expect(scripts.active(community)).to be_empty
    end

    it "forgets the count after a run that worked" do
      row = live_row
      2.times { row = scripts.record_failure(row, "timed out") }

      expect(scripts.record_success(row).consecutive_failures).to eq(0)
    end
  end

  # A run is the handoff: the router gave this script the work. The counting
  # itself is ordinary bookkeeping; what matters is that it costs the hot path
  # nothing per message and that nothing it does can reach the room.
  describe "counting runs" do
    let(:now) { Time.utc(2026, 8, 16, 9, 30) }

    subject(:scripts) do
      described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { @clock_now || now })
    end

    def counted(row, day: nil, source: "message")
      models.script_run.where(script_id: row.id, source: source,
                              day: day || now.strftime("%Y-%m-%d")).first
    end

    it "counts a run once the pending counts are written out" do
      row = save
      3.times { scripts.record_run(row) }
      scripts.flush_runs

      expect(counted(row).runs).to eq(3)
      expect(counted(row).failures).to eq(0)
    end

    # The point of the whole scheme: every message of every room passes through
    # here, and none of them may cost a write.
    it "writes nothing while it is counting" do
      row = save
      5.times { scripts.record_run(row) }

      expect(models.script_run.count).to be_zero
    end

    it "writes itself out once enough runs are pending, so nothing is held forever" do
      row = save
      described_class::RUN_FLUSH_AFTER.times { scripts.record_run(row) }

      expect(counted(row).runs).to eq(described_class::RUN_FLUSH_AFTER)
    end

    it "collapses a whole batch into one row per script per day" do
      row = save
      described_class::RUN_FLUSH_AFTER.times { scripts.record_run(row) }
      scripts.flush_runs

      expect(models.script_run.count).to eq(1)
    end

    it "counts a run that raised as both a run and a failure" do
      row = save
      scripts.record_run(row)
      scripts.record_run(row, failed: true)
      scripts.flush_runs

      expect(counted(row).runs).to eq(2)
      expect(counted(row).failures).to eq(1)
    end

    it "tells a wake apart from traffic, since the clock is not somebody typing" do
      row = save
      scripts.record_run(row)
      2.times { scripts.record_run(row, source: "wake") }
      scripts.flush_runs

      expect(counted(row).runs).to eq(1)
      expect(counted(row, source: "wake").runs).to eq(2)
    end

    it "counts an unknown source as traffic rather than dropping the run" do
      row = save
      scripts.record_run(row, source: "whatever")
      scripts.flush_runs

      expect(counted(row).runs).to eq(1)
    end

    it "counts nothing for a script that is not there" do
      expect(scripts.record_run(nil)).to be(false)
      expect(scripts.flush_runs).to be_zero
    end

    it "opens a new row when the day turns over in UTC" do
      row = save
      scripts.record_run(row)
      scripts.flush_runs
      @clock_now = now + (24 * 60 * 60)
      scripts.record_run(row)
      scripts.flush_runs

      expect(counted(row).runs).to eq(1)
      expect(counted(row, day: "2026-08-17").runs).to eq(1)
    end

    # Every statement the block sent, in order.
    def capture_sql(&block)
      log = StringIO.new
      seeded[0].loggers << Logger.new(log, formatter: ->(_s, _t, _p, msg) { "#{msg}\n" })
      block.call
      log.string.lines.filter_map { |line| line[/\(\d+\.\d+s\)\s*(.*)/, 1] }
    ensure
      seeded[0].loggers.clear
    end

    # Two writers each holding their own batch would otherwise read the same
    # total and write it back, losing one batch entirely.
    it "adds in the database rather than reading a total into Ruby" do
      row = save
      scripts.record_run(row)
      scripts.flush_runs
      statements = capture_sql do
        scripts.record_run(row)
        scripts.flush_runs
      end

      expect(statements.grep(/UPDATE/).join(" ").delete('"`')).to include("runs = (runs + 1)")
    end

    # The add happens in the database, so a total is never read into Ruby and
    # written back.
    it "adds to the stored count rather than to one it read earlier" do
      row = save
      scripts.record_run(row)
      scripts.flush_runs
      models.script_run.where(script_id: row.id).update(runs: 100)
      scripts.record_run(row)
      scripts.flush_runs

      expect(counted(row).runs).to eq(101)
    end

    it "waits for the ceiling in time before a timer flush writes anything" do
      row = save
      scripts.record_run(row)

      expect(scripts.flush_runs_if_due).to be_zero
      expect(scripts.flush_runs_if_due(now: now + described_class::RUN_FLUSH_AFTER_SECONDS)).to eq(1)
    end

    # Nothing a counter does may cost a room its bridging, so a broken write is
    # a warning and a dropped count.
    it "swallows a write that fails rather than raising into the pipeline" do
      row = save
      scripts.record_run(row)
      allow(models).to receive(:script_run).and_raise(Sequel::DatabaseError, "gone")

      expect { scripts.flush_runs }.not_to raise_error
    end

    describe "reading them back" do
      it "reports a day at a time, newest first" do
        row = save
        scripts.record_run(row)
        @clock_now = now + (24 * 60 * 60)
        scripts.record_run(row, source: "wake")

        expect(scripts.runs_for(row).map { |entry| entry[:day] }).to eq(%w[2026-08-17 2026-08-16])
      end

      it "leaves out the days before the window asked for" do
        row = save
        scripts.record_run(row)
        @clock_now = now + (2 * 24 * 60 * 60)
        scripts.record_run(row)

        expect(scripts.runs_for(row, since: "2026-08-17").map { |entry| entry[:day] }).to eq(["2026-08-18"])
      end

      it "adds up every day and every source" do
        row = save
        2.times { scripts.record_run(row) }
        scripts.record_run(row, source: "wake", failed: true)

        expect(scripts.run_totals(row)).to eq({ runs: 3, failures: 1 })
      end

      it "counts nothing for a script that has never run" do
        expect(scripts.run_totals(save)).to eq({ runs: 0, failures: 0 })
      end

      it "reads back what is still pending, so a fresh count is never missing" do
        row = save
        scripts.record_run(row)

        expect(scripts.run_totals(row)[:runs]).to eq(1)
      end

      it "never reaches another script's counts" do
        row = save
        other = save(name: "quieter")
        3.times { scripts.record_run(row) }

        expect(scripts.run_totals(other)).to eq({ runs: 0, failures: 0 })
      end
    end

    describe "retention" do
      it "drops the days past the retention and keeps the rest" do
        row = save
        scripts.record_run(row)
        @clock_now = now + (described_class::RUN_RETENTION_DAYS * 24 * 60 * 60) + (24 * 60 * 60)
        scripts.record_run(row)

        expect(scripts.prune_runs).to eq(1)
        expect(scripts.runs_for(row).map { |entry| entry[:day] }).to eq(["2026-11-15"])
      end

      it "keeps a day still inside the window" do
        row = save
        scripts.record_run(row)
        @clock_now = now + (30 * 24 * 60 * 60)

        expect(scripts.prune_runs).to be_zero
      end
    end
  end

  describe "scoping" do
    it "never reaches another community's script" do
      other = models.community.create(slug: "other", name: "Other", status: "active",
                                      created_at: Time.now, updated_at: Time.now)
      row = save

      expect(scripts.find(other, row.id)).to be_nil
      expect { scripts.enable(other, row.id) }.to raise_error(described_class::Invalid, /no script with id/)
    end
  end
end

# One instance is shared by every room's thread, so two can be inside a flush at
# once, and the count they are both adding to is the same row.
RSpec.describe Rubotty::ControlPlane::Scripts, "under concurrent counting", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:scripts) { described_class.new(models: models, logger: Rubotty::Log.null) }
  let(:row) do
    scripts.save(community: community, name: "greeter", kind: "processor",
                 source: 'return { action = "allow" }', trigger_type: "always")
  end

  it "loses no run when several rooms count the same script at once" do
    counted = row
    threads = 8.times.map do
      Thread.new { 60.times { scripts.record_run(counted) } }
    end
    threads.each(&:join)
    scripts.flush_runs

    expect(scripts.run_totals(counted)[:runs]).to eq(480)
  end

  it "loses no run when a flush runs concurrently with counting, the way the stats thread and message path do" do
    counted = row
    counting = 8.times.map do
      Thread.new { 100.times { scripts.record_run(counted) } }
    end
    flushing = 4.times.map do
      Thread.new { 200.times { scripts.flush_runs } }
    end
    expect { (counting + flushing).each(&:join) }.not_to raise_error
    scripts.flush_runs

    expect(scripts.run_totals(counted)[:runs]).to eq(800)
  end
end
