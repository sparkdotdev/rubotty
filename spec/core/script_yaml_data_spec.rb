# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The document travels through the router's own handler into real Lua, bound to
# the script row rather than to the community.
RSpec.describe "the data file a script reads", :control_plane do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 7, 29, 12, 0) }
  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  let(:scripts) { Rubotty::ControlPlane::Scripts.new(models: models, logger: Rubotty::Log.null) }

  after { pool.close }

  def save(name, data, owner: community)
    scripts.save(community: owner, name: name, kind: "processor", source: "return nil",
                 trigger_type: "always", yaml_data: data)
  end

  # The registry builder reads word filter settings off the snapshot, so this
  # stands in for that; nothing about the data file touches it.
  def snapshot_community
    Class.new do
      def slug = "sample"

      def feature_config(_channel, _name) = {}

      def feature_enabled?(_channel, _name) = false
    end.new
  end

  # The real builder the runtime wires, so the handler exercised is what ships.
  def registry_for(row)
    context = Struct.new(:channel, :community).new("general", snapshot_community)
    Rubotty::Core::Router.allocate
                         .send(:script_registry_builder, logger: Rubotty::Log.null, scripts: scripts)
                         .call(context, row)
  end

  def run(row, source)
    pool.run(source: source, arg: {}, registry: registry_for(row), timeout: 5)
  end

  it "hands a script the document sitting beside its code" do
    row = save("guard", "reason: not here\nwords:\n  - airdrop\n  - free mint\n")

    answer = run(row, <<~LUA)
      local data = rubotty.yaml_data()
      return { reason = data.reason, first = data.words[1], count = #data.words }
    LUA

    expect(answer).to eq({ "reason" => "not here", "first" => "airdrop", "count" => 2 })
  end

  it "hands over a list as a list, so a data file need not be a mapping" do
    row = save("guard", "- one\n- two\n")

    expect(run(row, "return { first = rubotty.yaml_data()[1] }")).to eq({ "first" => "one" })
  end

  it "answers nil for a script with no data file" do
    row = save("guard", nil)

    expect(run(row, 'return { seen = tostring(rubotty.yaml_data()) }')).to eq({ "seen" => "nil" })
  end

  # What comes back is built fresh from the stored document on every call, and no
  # host function writes one.
  describe "being read only" do
    it "keeps nothing a script writes into the table it was handed" do
      row = save("guard", "words:\n  - airdrop\n")

      answer = run(row, <<~LUA)
        local first = rubotty.yaml_data()
        first.words[1] = "scribbled"
        first.extra = true
        local second = rubotty.yaml_data()
        return { word = second.words[1], extra = tostring(second.extra) }
      LUA

      expect(answer).to eq({ "word" => "airdrop", "extra" => "nil" })
    end

    it "keeps nothing a script writes across two invocations either" do
      row = save("guard", "words:\n  - airdrop\n")
      run(row, 'local d = rubotty.yaml_data() d.words[1] = "scribbled" return nil')

      expect(run(row, "return { word = rubotty.yaml_data().words[1] }"))
        .to eq({ "word" => "airdrop" })
      expect(scripts.yaml_data(scripts.find(community, row.id)))
        .to eq({ "words" => ["airdrop"] })
    end

    # The namespace member is per invocation, so replacing it reaches nothing.
    it "offers no function that writes a data file back" do
      expect(Rubotty::Scripting::HostFunctions::CATALOG.keys.grep(/yaml/)).to eq(["yaml_data"])
    end
  end

  # Scoped to the row, so a rule only ever reads the document beside its own code.
  describe "scoping" do
    let(:other) do
      models.community.create(slug: "elsewhere", name: "Elsewhere", status: "active",
                              created_at: now, updated_at: now)
    end

    it "gives each script in a community its own file" do
      mine = save("mine", "who: mine\n")
      yours = save("yours", "who: yours\n")

      expect(run(mine, "return { who = rubotty.yaml_data().who }")).to eq({ "who" => "mine" })
      expect(run(yours, "return { who = rubotty.yaml_data().who }")).to eq({ "who" => "yours" })
    end

    it "never reads across communities, even for a script of the same name" do
      theirs = save("guard", "who: theirs\n", owner: other)
      mine = save("guard", "who: mine\n")

      expect(run(mine, "return { who = rubotty.yaml_data().who }")).to eq({ "who" => "mine" })
      expect(run(theirs, "return { who = rubotty.yaml_data().who }")).to eq({ "who" => "theirs" })
      # And the store will not hand one community the other's row in the first place.
      expect(scripts.find(other, mine.id)).to be_nil
      expect(scripts.yaml_data(scripts.find(other, mine.id))).to be_nil
    end
  end

  # The wake path is a separate call site from the message path, with no message
  # behind it.
  describe "a woken invocation" do
    let(:reposted) { [] }

    subject(:feature) do
      Rubotty::Features::Scripts.new(
        scripts: scripts, pool: pool, logger: Rubotty::Log.null,
        room_poster: ->(_community, key, text) { reposted << [key, text] },
        registry_for: ->(_context, row) { registry_for(row) },
        clock: -> { now }
      )
    end

    it "reads its data file on a scheduled wake" do
      row = scripts.save(community: community, name: "digest", kind: "processor",
                         source: 'return { reply = rubotty.yaml_data().greeting }',
                         trigger_type: "recurring", trigger_config: { "every" => "day" },
                         yaml_data: "greeting: morning everyone\n")

      feature.wake(community: community, row: row, room_key: "general",
                   kind: Rubotty::Scripting::Context::SCHEDULED)

      expect(reposted).to eq([["general", "morning everyone"]])
    end

    it "reads its data file on a callback wake" do
      row = scripts.save(community: community, name: "answer", kind: "callback",
                         source: 'return { reply = rubotty.yaml_data().greeting }',
                         trigger_type: "always", yaml_data: "greeting: it came back\n")

      feature.wake(community: community, row: row, room_key: "general",
                   kind: Rubotty::Scripting::Context::HTTP_CALLBACK,
                   response: { "ok" => true })

      expect(reposted).to eq([["general", "it came back"]])
    end
  end
end
