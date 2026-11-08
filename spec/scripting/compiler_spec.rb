# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# Transpiling a dialect down to the Lua that actually runs. The dialect-specific cases run
# only where that transpiler is installed, since two of them want a C or C++ toolchain.
# Everything about how a failure is reported is checked without one.
RSpec.describe Rubotty::Scripting::Compiler do
  subject(:compiler) { described_class.new(timeout: 10, logger: Rubotty::Log.null) }

  def self.installed?(name) = Rubotty::Scripting::Dialects.available?(name)

  describe "Lua" do
    it "passes it through untouched, because there is nothing to compile" do
      expect(compiler.compile("return 1 + 1", language: "lua")).to eq("return 1 + 1")
    end
  end

  describe "a language nobody supports" do
    it "says so rather than trying to run something" do
      expect { compiler.compile("x", language: "python") }
        .to raise_error(Rubotty::Scripting::Error, /not a language rubotty knows/)
    end
  end

  # Teal missing on this deployment usually means one thing, and the message
  # says so instead of reading like a forgotten install step.
  describe "a dialect missing for a known reason" do
    it "appends it to the plain not-installed message" do
      allow(Rubotty::Scripting::Dialects).to receive_messages(installed?: false, unavailable_reason: "upstream's fault, not yours")

      expect { compiler.compile("local n: integer = 1\nreturn n", language: "teal") }
        .to raise_error(described_class::Failed, "Teal needs tl, which is not installed here. upstream's fault, not yours")
    end

    it "stays with the plain message when there is no reason to add" do
      allow(Rubotty::Scripting::Dialects).to receive_messages(installed?: false, unavailable_reason: nil)

      expect { compiler.compile("f = (x) -> x", language: "moonscript") }
        .to raise_error(described_class::Failed, "MoonScript needs moonc, which is not installed here.")
    end
  end

  describe "MoonScript", if: installed?("moonscript") do
    it "compiles to Lua" do
      lua = compiler.compile("f = (x) -> x * 2\nreturn f", language: "moonscript")

      expect(lua).to include("function")
      expect(lua).not_to include("->")
    end

    # The transpiler's own message is the only thing an operator has to go on,
    # so it is passed through rather than replaced with something friendlier.
    it "refuses source that will not parse, and says what the compiler said" do
      expect { compiler.compile("f = (x ->", language: "moonscript") }
        .to raise_error(described_class::Failed, /parse/i)
    end

    # The compile runs in a throwaway directory, and naming it in the error
    # would tell the operator about a path that no longer exists.
    it "keeps the temporary path out of the message" do
      compiler.compile("f = (x ->", language: "moonscript")
    rescue described_class::Failed => e
      expect(e.message).not_to include(Dir.tmpdir)
      expect(e.message).not_to match(/script\.moon/)
    end
  end

  describe "Fennel", if: installed?("fennel") do
    it "compiles a Lisp down to Lua" do
      lua = compiler.compile('(fn [x] (.. "hi " x))', language: "fennel")

      expect(lua).to include("function")
    end

    # Fennel macros run at compile time in the web process, and its own sandbox covers
    # reaching the filesystem but not looping forever, so every compile is bounded whether
    # or not the dialect has macros. What this asserts is that it stops and the operator is
    # told why, whichever bound fires (rlimits or a wall clock deadline on macOS).
    it "stops a macro that never finishes rather than hanging the web process" do
      quick = described_class.new(timeout: 2, logger: Rubotty::Log.null)

      expect { quick.compile("(eval-compiler (while true nil))\n(fn [x] x)", language: "fennel") }
        .to raise_error(described_class::Failed, /did not finish within 2 seconds|too much time or memory/)
    end

    it "cannot reach the filesystem from a macro" do
      expect { compiler.compile('(eval-compiler (os.execute "true"))\n(fn [x] x)', language: "fennel") }
        .to raise_error(described_class::Failed)
    end
  end

  # Teal's whole reason for being here is the type checking, and `tl gen` on its
  # own strips the annotations and exits 0 whether or not they hold. So without
  # a separate checking pass the types were decoration: this is what makes them
  # mean something.
  describe "Teal", if: installed?("teal") do
    it "compiles a well typed script" do
      lua = compiler.compile("local n: integer = 2\nreturn tostring(n)", language: "teal")

      expect(lua).to include("local n = 2")
      expect(lua).not_to include(": integer")
    end

    it "refuses a script whose types do not hold" do
      expect { compiler.compile(%(local n: integer = "words"\nreturn n), language: "teal") }
        .to raise_error(described_class::Failed, /expected integer|got string/)
    end

    # The declarations are generated from the catalog, so a script is checked
    # against what the runtime really answers rather than against nothing.
    it "knows what the message is, and catches a misspelled getter" do
      expect { compiler.compile("return rubotty.txet()", language: "teal") }
        .to raise_error(described_class::Failed, /txet/)
    end

    it "knows the host functions, so calling one is not an unknown variable" do
      lua = compiler.compile("return rubotty.bold(rubotty.text())", language: "teal")

      expect(lua).to include("rubotty.bold")
    end

    it "catches a host function that does not exist" do
      expect { compiler.compile("return rubotty.nope(rubotty.text())", language: "teal") }
        .to raise_error(described_class::Failed, /nope/)
    end

    # An unused variable is a warning, and refusing a save over one would be
    # tiresome for no safety gain.
    it "allows a warning through" do
      expect(compiler.compile("local unused: integer = 1\nreturn \"hi\"", language: "teal"))
        .to include("hi")
    end
  end

  # The web process holds every platform bot token and DATABASE_URL in ENV.
  # The child gets an allow-listed environment instead of a copy of this
  # process's, so it never sees them.
  describe "the child's environment" do
    around do |example|
      original = ENV.fetch("RUBOTTY_TEST_TOKEN", nil)
      ENV["RUBOTTY_TEST_TOKEN"] = "do-not-leak-this-token"
      example.run
    ensure
      original.nil? ? ENV.delete("RUBOTTY_TEST_TOKEN") : ENV["RUBOTTY_TEST_TOKEN"] = original
    end

    # A stand-in for moonc, fennel or tl: a real executable, spawned the same
    # way, that reports what it can see of its own environment.
    def fake_dialect(script)
      Rubotty::Scripting::Dialects::Dialect.new(
        name: "fake", label: "Fake", extension: ".fake", comment: "--",
        binary: script, args: [], output: :stdout, editor_mode: "lua", check_args: nil
      )
    end

    it "does not hand a transpiler subprocess this process's tokens" do
      Dir.mktmpdir("rubotty-compiler-spec") do |dir|
        script = File.join(dir, "echo-env")
        File.write(script, "#!/bin/sh\necho \"TOKEN=$RUBOTTY_TEST_TOKEN\"\necho \"PATH_SET=${PATH:+yes}\"\n")
        File.chmod(0o755, script)
        # mktmpdir gives 0700, so a run as root drops to the script account and
        # then cannot traverse in. A real transpiler sits somewhere world
        # traversable, so stand the fixture up the same way.
        File.chmod(0o755, dir)

        dialect = fake_dialect(script)
        allow(Rubotty::Scripting::Dialects).to receive_messages(find!: dialect, installed?: true)

        result = compiler.compile("ignored", language: "fake")

        expect(result).to include("TOKEN=\n")
        expect(result).to include("PATH_SET=yes")
      end
    end
  end
end
