# frozen_string_literal: true

require "spec_helper"

# The guided form is read off Core::CommandRegistry alone, so these check the
# metadata-to-prompt-to-command-line path rather than any one command's
# behaviour.
RSpec.describe Rubotty::Core::CommandForm do
  def argument(**fields) = Rubotty::Core::CommandRegistry::Argument.new(**fields)

  def command(**fields) = Rubotty::Core::CommandRegistry::Spec.new(**fields)

  let(:spec) do
    command(
      name: "demo", description: "A demo command.",
      arguments: [
        argument(name: "title", type: :string, required: true, keyed: true,
                     description: "what to call it"),
        argument(name: "count", type: :integer, required: false,
                     description: "How many. Optional."),
        argument(name: "loud", type: :boolean, required: false, keyed: true,
                     description: "whether to shout")
      ]
    )
  end

  let(:markers) { Rubotty::Core::CommandPrefix.new(["/", "!"]) }

  describe ".buildable?" do
    it "accepts a command with fields and no reply target" do
      expect(described_class.buildable?(spec)).to be(true)
    end

    it "refuses a command with no fields to ask for" do
      expect(described_class.buildable?(command(name: "bare", description: "x"))).to be(false)
    end

    # A reply target is a gesture, not something a person can type into a
    # prompt, so /warn and /redirect are never offered a form.
    it "refuses a command that needs a reply target" do
      pointed = command(name: "pointed", description: "x", target: :message,
                        arguments: [argument(name: "why", type: :string, required: true, description: "why")])

      expect(described_class.buildable?(pointed)).to be(false)
    end

    it "refuses nothing at all" do
      expect(described_class.buildable?(nil)).to be(false)
    end
  end

  describe ".prompt" do
    it "names the command, the field, its place in the run and the registry's own description" do
      text = described_class.prompt(spec, 0, marker: "/")

      expect(text).to include("/demo (1 of 3)", "title.", "what to call it.")
    end

    it "says a field is optional and how to leave it out" do
      text = described_class.prompt(spec, 1, marker: "/")

      expect(text).to include("(2 of 3, optional)", "/skip to leave it out")
    end

    it "offers no skip on a required field, only a way to stop" do
      text = described_class.prompt(spec, 0, marker: "/")

      expect(text).not_to include("/skip")
      expect(text).to include("/cancel to stop")
    end

    # Nine optional fields must not be nine more questions, so a form that is
    # already a command says it can be run from here.
    it "offers to run what is answered once nothing required is left" do
      expect(described_class.prompt(spec, 1, marker: "/", finishable: true)).to include("/done to run it now")
      expect(described_class.prompt(spec, 1, marker: "/")).not_to include("/done")
    end

    # Discord reserves "/" for its own picker, so the room's other marker is
    # what a person there is told to type.
    it "prints whichever marker the room configures" do
      expect(described_class.prompt(spec, 0, marker: "!")).to include("!cancel")
    end

    # Where a platform has no replies to hang a prompt off, the name is how two
    # people building at once tell whose question is whose.
    it "opens with the invoker's name when asked to" do
      expect(described_class.prompt(spec, 0, marker: "/", addressee: "ada")).to start_with("ada: /demo")
    end
  end

  describe ".complaint" do
    it "passes any non-empty text for a string field" do
      expect(described_class.complaint(spec.arguments[0], "Game night")).to be_nil
    end

    it "refuses an empty answer" do
      expect(described_class.complaint(spec.arguments[0], "   ")).to include("needs a value")
    end

    it "refuses text where a whole number was declared" do
      expect(described_class.complaint(spec.arguments[1], "several")).to include("whole number")
      expect(described_class.complaint(spec.arguments[1], "4")).to be_nil
    end

    it "refuses anything but yes or no where a boolean was declared" do
      expect(described_class.complaint(spec.arguments[2], "maybe")).to include("yes or no")
      expect(described_class.complaint(spec.arguments[2], "Yes")).to be_nil
    end
  end

  describe ".normalise" do
    it "leaves an ordinary value exactly as it was said" do
      expect(described_class.normalise(spec.arguments[0], "  Game night ")).to eq("Game night")
    end

    it "turns every spelling of a boolean into true or false" do
      expect(described_class.normalise(spec.arguments[2], "y")).to eq("true")
      expect(described_class.normalise(spec.arguments[2], "off")).to eq("false")
    end
  end

  describe ".command_line" do
    it "writes the line a person would have typed, keyed fields as key=value" do
      line = described_class.command_line(spec, { "title" => "Game night", "count" => "4" }, marker: "/")

      expect(line).to eq(%(/demo title="Game night" 4))
    end

    it "leaves out a field nobody answered" do
      expect(described_class.command_line(spec, { "title" => "x" }, marker: "/")).to eq("/demo title=x")
    end

    # The writer is the same module that reads the line back, so a value
    # holding a quote of its own survives the round trip.
    it "quotes a value holding a quote so it survives as one field" do
      line = described_class.command_line(spec, { "title" => %(Ada's "night") }, marker: "!")

      expect(Rubotty::Core::KeyedArguments.parse(line.sub("!demo ", ""))).to eq("title" => %(Ada's "night"))
    end
  end

  describe ".control" do
    it "reads the form words through the room's own markers" do
      expect(described_class.control("/skip", markers)).to eq(:skip)
      expect(described_class.control("/done", markers)).to eq(:done)
      expect(described_class.control("!cancel", markers)).to eq(:cancel)
    end

    # A value that happens to be the word is still a value: only the marker
    # makes it a form word.
    it "leaves an unmarked word alone" do
      expect(described_class.control("skip", markers)).to be_nil
      expect(described_class.control("cancel this thing", markers)).to be_nil
    end

    it "reads nothing out of another command" do
      expect(described_class.control("/help", markers)).to be_nil
    end
  end
end
