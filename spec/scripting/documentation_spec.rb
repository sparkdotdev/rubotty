# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# This private reference is deliberately absent from source catalogues. Only a
# missing entry is optional; unreadable or malformed input, including dangling
# links and directories, still reaches the failing conformance path.
scripting_reference_path = File.expand_path("../../docs/scripting.md", __dir__)
scripting_reference_present = begin
  File.lstat(scripting_reference_path)
  true
rescue Errno::ENOENT
  false
end

# docs/scripting.md against the code it describes. A doc that quietly falls behind the
# catalog is worse than no doc: it sends somebody to write a rule around a function that
# is not there. Everything here is read out of the constants rather than restated, so
# forgetting to update the doc when adding a host function or trigger fails the build.
RSpec.describe "the scripting reference" do
  # UTF-8 explicitly: the reference carries accented text (the section on
  # folding is about Portuguese), and File.read would otherwise tag it with
  # Encoding.default_external, which is US-ASCII wherever no UTF-8 locale is
  # set. Every match below would then raise rather than fail.
  DOC = File.read(scripting_reference_path, encoding: "UTF-8")

  it "documents every host function in the catalog" do
    undocumented = Rubotty::Scripting::HostFunctions::CATALOG.keys.reject do |name|
      # A function taking a table is written name{...}, so both call shapes
      # count as documented.
      DOC.match?(/`#{Regexp.escape(name)}[({]/) || DOC.match?(/\| `#{Regexp.escape(name)}`/)
    end

    expect(undocumented).to be_empty, "docs/scripting.md never mentions: #{undocumented.join(", ")}"
  end

  it "documents no function the catalog does not offer" do
    # Names the doc presents as rubotty.<name>, which is the shape an operator
    # copies. Anything here that the catalog lacks is a promise nothing keeps.
    promised = DOC.scan(/`rubotty\.(\w+)/).flatten.uniq

    expect(promised - Rubotty::Scripting::HostFunctions::CATALOG.keys).to be_empty
  end

  # The payload used to arrive as the chunk's vararg and every example called it `m`.
  # Nothing is handed one now, so a reference still showing `local m = ...` or `m.text`
  # would send somebody to write a rule against a shape that fails at the save gate.
  it "teaches no field on the table a script used to be handed" do
    expect(DOC).not_to include("local m = ...")
    expect(DOC.scan(/\bm\.[a-z_]+/)).to be_empty
  end

  it "documents every trigger, and no trigger that does not exist" do
    # Scoped to the trigger table itself, which is the one whose rows end in a
    # "Fires when" sentence, so the denied-modules table below is not read as a
    # list of triggers.
    table = DOC[/\| Trigger \| Config \| Fires when \|.*?\n\n/m].to_s
    listed = table.scan(/^\| `(\w+)` \|/).flatten.uniq
    real = Rubotty::Scripting::Triggers.type_names

    expect(real - listed).to be_empty, "triggers missing from the doc: #{(real - listed).join(", ")}"
    expect(listed - real).to be_empty, "doc names triggers that do not exist: #{(listed - real).join(", ")}"
  end

  it "documents every dialect the registry knows" do
    Rubotty::Scripting::Dialects::ALL.each do |dialect|
      expect(DOC).to include("`#{dialect.extension}`"), "#{dialect.name} is not in the languages table"
    end
  end

  # The allow lists are the security story, so a doc that overstates them is the
  # kind of wrong that gets somebody hurt.
  it "lists exactly the globals the sandbox grants" do
    Rubotty::Scripting::Sandbox::GLOBALS.each do |name|
      expect(DOC).to include(name), "the globals list omits #{name}"
    end
  end

  it "lists exactly the library functions the sandbox grants" do
    Rubotty::Scripting::Sandbox::MODULES.each do |mod, members|
      members.each do |member|
        expect(DOC).to match(/`#{member}`/), "#{mod}.#{member} is offered but not documented"
      end
    end
  end

  # Reads the row values off Markup::LIMITS rather than trusting the table.
  it "gives the longest-message table the values Markup::LIMITS really holds" do
    markup = Rubotty::Scripting::Markup
    names = { "irc" => "IRC" }
    markup::LIMITS.each do |platform, limit|
      label = names.fetch(platform, platform.capitalize)
      expect(DOC).to match(/\| #{label} \| #{limit} characters \|/)
    end
    expect(DOC).to include("#{markup::DEFAULT_LIMIT} characters")
  end

  # A size the way somebody would say it, so raising a constant from kilobytes
  # to megabytes does not need this assertion rewritten. The endpoint cap went
  # to 1 MiB and this read "1024 KB" against a table that correctly said 1 MB,
  # which is the mismatch worth not repeating.
  def in_bytes(count)
    count >= 1024 * 1024 ? "#{count / (1024 * 1024)} MB" : "#{count / 1024} KB"
  end

  # Every row of the limits table names its unit, because a bare number in a
  # table of durations is one somebody writes in milliseconds. Asserting on the
  # unit as well as the value is what holds that.
  it "states the real limits, in the units they are counted in" do
    memory = Rubotty::Scripting::Memory
    expect(DOC).to include("#{memory::MAX_KEYS} keys")
    expect(DOC).to include("#{memory::MAX_KEY_LENGTH} characters")
    expect(DOC).to include(in_bytes(memory::MAX_VALUE_BYTES))
    expect(DOC).to include("#{memory::DEFAULT_TTL / 86_400} day by default")
    expect(DOC).to include("#{memory::MAX_TTL / 86_400} days maximum")
    expect(DOC).to include("#{Rubotty::Scripting::Registry::DEFAULT_MAX_CALLS} calls")
    # The two ceilings are different numbers doing different jobs, so both are in the table.
    # A reader who only knows the big one writes a rule that notifies in a loop and is
    # surprised by the small one.
    expect(DOC).to include("#{Rubotty::Scripting::Registry::DEFAULT_MAX_BROADCASTS} calls")
    expect(DOC).to include("#{Rubotty::Scripting::Triggers::MAX} conditions")
    expect(DOC).to include("#{Rubotty::Scripting::Child::DEFAULT_TIMEOUT} seconds")
    expect(DOC).to include(in_bytes(Rubotty::Scripting::Endpoints::MAX_BYTES))
  end

  # The reference tables are written by `rake docs:scripting` out of the
  # catalog. Nothing stops somebody editing them in place, so this is what
  # catches it: the file has to be what the catalog renders today.
  it "carries the reference the catalog renders, rather than an older one" do
    expect(Rubotty::Scripting::HostFunctions.rewrite(DOC)).to eq(DOC),
                                                             "docs/scripting.md is behind the catalog. " \
                                                             "Run `bundle exec rake docs:scripting`."
  end

  # Each of these is a field a script reads off a returned table, so a missing
  # one is a shape somebody has to discover by trial and error.
  it "documents the fields on what the host functions hand back" do
    %w[title starts_at starts_in rsvp_count].each { |f| expect(DOC).to include(f) }
    %w[status ok body data format].each { |f| expect(DOC).to include("`#{f}`") }
    %w[from to category part_of_speech].each { |f| expect(DOC).to include(f) }
  end
end if scripting_reference_present

# What the catalog has to say about every function, held to it so the reference cannot go
# back to what it used to be: one string shaped "signature -> what it answers", with no
# argument type, no unit for a number, and no real call shown, so an operator writing a
# first rule guessed. All three surfaces render from this catalog.
RSpec.describe Rubotty::Scripting::HostFunctions::CATALOG do
  def forms = described_class.values.flat_map(&:forms)

  it "gives every function at least one call shape" do
    shapeless = described_class.select { |_name, entry| entry.forms.empty? }

    expect(shapeless.keys).to be_empty
  end

  it "says what every function is for, and what it answers" do
    silent = described_class.reject do |_name, entry|
      entry.summary.to_s.match?(/\S/) && entry.returns.to_s.match?(/\S/)
    end

    expect(silent.keys).to be_empty
  end

  # The sample is the thing an operator copies, so it has to be a call to the
  # function it sits under, spelled the way that function is really called.
  it "gives every call shape a sample invocation of that very function" do
    wrong = described_class.reject do |name, entry|
      entry.forms.all? { |form| form.sample.start_with?("rubotty.#{name}(", "rubotty.#{name}{") }
    end

    expect(wrong.keys).to be_empty, "these samples do not call what they document: #{wrong.keys.join(", ")}"
  end

  it "types every argument of every call shape" do
    untyped = forms.flat_map(&:args).reject { |argument| argument.type.to_s.match?(/\S/) }

    expect(untyped.map(&:name)).to be_empty
  end

  it "names every argument, so a table form can be written out" do
    nameless = forms.flat_map(&:args).reject { |argument| argument.name.to_s.match?(/\S/) }

    expect(nameless).to be_empty
  end

  # The reason this structure exists. A duration with no unit on it is one
  # somebody writes in milliseconds, and a step with no unit is one somebody
  # reads as a target rather than an increment.
  it "names the unit on every number that is counted in something" do
    counted = { %w[remember ttl] => "seconds", %w[schedule after] => "seconds",
                %w[schedule at] => "seconds", %w[increment_stat step] => "count",
                %w[record_stat value] => "count" }

    counted.each do |(name, argument), unit|
      found = described_class.fetch(name).arguments.find { |a| a.name == argument }

      expect(found&.unit.to_s).to include(unit), "#{name}'s #{argument} never says it is counted in #{unit}"
    end
  end

  # remember writes to one of two stores and the ttl is what picks which, so
  # both shapes are listed. One signature per function would have to pick one of
  # them and hide the other, which is what the old catalog did.
  it "keeps every shape of the functions that take more than one" do
    shapes = described_class.transform_values { |entry| entry.signatures.length }

    expect(shapes.values_at("remember", "alert")).to all(eq(2))
  end

  # The two shapes of remember differ in what the ttl says, so the reference has
  # to show a kept write as well as one that expires. A reader who only ever
  # sees the first writes a total that quietly disappears in a month.
  it "shows both a ttl in seconds and a kept write" do
    samples = described_class.fetch("remember").samples

    expect(samples).to include(a_string_matching(/ttl = \d/))
    expect(samples).to include(a_string_matching(/ttl = "never"/))
  end

  # Written name{...} because they take one table, and an operator who writes
  # them with brackets and commas gets a Lua error rather than an explanation.
  it "writes the table taking functions with braces" do
    braced = described_class.select { |_name, entry| entry.forms.any?(&:braces) }

    expect(braced.keys).to include("schedule", "async_http", "record_stat")
  end
end

# The compiler runs `tl check` and refuses the save on a non-zero exit, and Teal refuses a
# call it has never heard of, so a field a trigger hands over with no getter declared for
# it makes a correct script unsaveable in Teal, which is exactly what happened to
# contains_rate's minutes.
RSpec.describe "the Teal declaration" do
  it "declares a getter for every field a trigger hands over" do
    declared = Rubotty::Scripting::TealDefinitions.declared
    handed = Rubotty::Scripting::Triggers::TYPES.flat_map(&:hands_over).uniq

    missing = handed - declared

    expect(missing).to be_empty,
                       "a Teal script reading these would be refused at save: #{missing.inspect}"
  end

  # The other half of the same promise: every one of those is a real catalog
  # entry, so what Teal will accept and what the runtime answers are one list.
  it "makes every one of them a getter the runtime really serves" do
    handed = Rubotty::Scripting::Triggers::TYPES.flat_map(&:hands_over).uniq

    expect(handed - Rubotty::Scripting::HostFunctions.getter_names).to be_empty
  end
end

# Teal is offered as a first class dialect, and tl check refuses an undeclared
# call, so a host function missing from the declaration is one no Teal script
# may use.
RSpec.describe "the Teal rubotty record" do
  it "declares every host function the catalog offers" do
    missing = Rubotty::Scripting::HostFunctions::CATALOG.keys -
              Rubotty::Scripting::TealDefinitions.declared

    expect(missing).to be_empty, "no Teal script could call these: #{missing.inspect}"
  end
end
