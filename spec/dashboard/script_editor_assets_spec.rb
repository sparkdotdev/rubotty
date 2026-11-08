# frozen_string_literal: true

require "spec_helper"

# Every dialect an operator can pick is highlighted and everything the runtime
# serves can be completed, both held to the catalog everything else reads. Ruby
# names a CodeMirror mode per dialect and the bundle maps that name to a mode, so a
# dialect added on one side only falls back to Lua highlighting silently.
RSpec.describe "the script editor's assets" do
  def editor_source = File.read(File.expand_path("../../assets/editor/index.js", __dir__))

  # The keys of the bundle's MODES map, read from its source rather than kept
  # as a second list here.
  def known_modes
    editor_source[/const MODES = \{(.*?)\};/m, 1].to_s.scan(/(\w+)\s*[,:]/).flatten.uniq
  end

  it "knows a mode for every dialect that can be picked" do
    named = Rubotty::Scripting::Dialects::ALL.map(&:editor_mode).uniq

    expect(named - known_modes).to be_empty
  end

  it "names a mode for every dialect, rather than leaving one blank" do
    expect(Rubotty::Scripting::Dialects::ALL.map(&:editor_mode)).to all(be_a(String))
  end

  describe "what it will complete" do
    let(:completions) { Rubotty::Scripting::HostFunctions.completions }
    let(:labels) { completions.map { |entry| entry["label"] } }

    it "offers every host function the runtime serves" do
      expected = Rubotty::Scripting::HostFunctions::CATALOG.keys.map { |name| "rubotty.#{name}" }

      expect(expected - labels).to be_empty
    end

    it "offers nothing the catalog does not declare" do
      hosts = labels.grep(/\Arubotty\./).reject { |label| label == "rubotty" }
      declared = Rubotty::Scripting::HostFunctions::CATALOG.keys.map { |name| "rubotty.#{name}" }

      expect(hosts - declared).to be_empty
    end

    it "describes each one, since the list is the only reference in the editor" do
      hosts = completions.select { |entry| entry["label"].start_with?("rubotty.") }

      expect(hosts.map { |entry| entry["detail"] }).to all(be_a(String).and(satisfy { |d| !d.empty? }))
    end

    # The detail is the row itself, so it stays one line and carries the shapes
    # the call takes. Two forms of remember on one row is the point: an operator
    # scanning the list can see that a ttl of "never" means something different
    # from a ttl in seconds without opening anything.
    it "puts every call shape of a function on its row" do
      detail = completions.find { |entry| entry["label"] == "rubotty.remember" }["detail"]

      expect(detail).to start_with("remember{bucket, key, value, ttl} or ")
      expect(detail).to include('remember{bucket, key, value, ttl = "never"}')
      expect(detail.lines.length).to eq(1)
    end

    # The info panel opens beside the highlighted row, which is where the argument
    # types and the worked example fit.
    it "carries the types and a sample for every function, in the info panel" do
      hosts = completions.select { |entry| entry["label"].start_with?("rubotty.") }

      expect(hosts.map { |entry| entry["info"] }).to all(include("eg rubotty."))
    end

    it "names the unit on a duration, in the panel an operator actually reads" do
      info = completions.find { |entry| entry["label"] == "rubotty.schedule" }["info"]

      expect(info).to include("after: number (seconds from now)")
    end

    # The catalog is written with backticks because docs/scripting.md renders the
    # same strings as markdown, and CodeMirror shows these two fields as plain text.
    it "leaves no markdown in what the editor shows as plain text" do
      hosts = completions.select { |entry| entry["label"].start_with?("rubotty.") }

      shown = hosts.flat_map { |entry| [entry["detail"], entry["info"]] }

      expect(shown.select { |text| text.include?("`") }).to be_empty
    end

    # The old surface handed a script its payload as a table called `m`, so autocomplete
    # offering anything under that name would go on teaching a shape that no longer exists.
    it "offers nothing under the old payload name" do
      expect(labels).not_to include("m")
      expect(labels.grep(/\Am\./)).to be_empty
    end

    it "completes what the invocation was handed, the same as any other call" do
      expect(labels).to include("rubotty.text", "rubotty.author", "rubotty.now", "rubotty.invocation_data")
    end

    # An operator who narrowed the catalog should not be offered the rest.
    it "narrows to what a deployment really serves when asked" do
      offered = Rubotty::Scripting::HostFunctions.completions(available: %w[bold classify])
                                                 .map { |entry| entry["label"] }

      expect(offered).to include("rubotty.bold", "rubotty.classify")
      expect(offered).not_to include("rubotty.remember")
    end

    # assets/editor/index.js finds the token to complete with
    # context.matchBefore(/[\w.]+/), so the query fires only when every
    # character in a label is a word character or a literal dot.
    # Anything else (a hyphen, say) would break the trigger silently.
    it "offers nothing the editor's dot trigger cannot match" do
      expect(labels).to all(match(/\A[\w.]+\z/))
    end

    # CodeMirror's default filter keeps an option whenever the typed text is a
    # subsequence of its label, so "rubotty." has to keep every rubotty.*
    # label and drop every other one, or the popup would show the whole
    # catalog instead of narrowing once the dot lands.
    it "narrows to rubotty.* once the dot is typed, the way CodeMirror's own filter would" do
      typed = "rubotty."
      kept = labels.select { |label| label.start_with?(typed) }
      dropped = labels - kept

      expect(kept).not_to be_empty
      expect(dropped.grep(/\Arubotty\./)).to be_empty
    end
  end
end
