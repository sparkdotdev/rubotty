# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

RSpec.describe Rubotty::Scripting::Landlock, "compiler workspaces" do
  around do |example|
    described_class.reset!
    Dir.mktmpdir("rubotty-workspace-policy") do |dir|
      @dir = dir
      @own = File.join(dir, "own")
      @sibling = File.join(dir, "sibling")
      Dir.mkdir(@own)
      Dir.mkdir(@sibling)
      @output = File.join(@own, "script.lua")
      File.write(@output, "")
      example.run
    end
  ensure
    described_class.reset!
  end

  it "grants writes only to the declared precreated output and the null device" do
    rules = described_class.compile_rules(workspace: @own, binary: RbConfig.ruby, output: @output, version: 6)
    writable = rules.select { |_, rights| rights.anybits?(described_class::WRITE_FILE) }.map(&:first)
    expect(writable).to contain_exactly(File.realpath(@output), File.realpath(File::NULL))
    workspace = rules.assoc(File.realpath(@own)).last
    expect(workspace).to eq(described_class::READ_FILE | described_class::READ_DIR)
    expect(rules.map(&:first)).not_to include("/", ENV["HOME"], File.realpath(Dir.tmpdir), File.realpath(@sibling))
    sibling_readable = rules.any? do |path, rights|
      described_class.beneath?(File.realpath(@sibling), path) && rights.anybits?(described_class::READ_FILE)
    end
    expect(sibling_readable).to be(false)
  end

  it "gives stdout compilers no writable regular file and rejects linked or unrelated output files" do
    rules = described_class.compile_rules(workspace: @own, version: 6)
    writable = rules.select { |_, rights| rights.anybits?(described_class::WRITE_FILE) }.map(&:first)
    expect(writable).to eq([File.realpath(File::NULL)])
    other = File.join(@sibling, "script.lua")
    File.write(other, "x")
    expect { described_class.compile_rules(workspace: @own, output: other, version: 6) }
      .to raise_error(Rubotty::Scripting::Unavailable, /precreated regular/)
    File.unlink(@output)
    File.symlink(other, @output)
    expect { described_class.compile_rules(workspace: @own, output: @output, version: 6) }
      .to raise_error(Rubotty::Scripting::Unavailable, /precreated regular/)
    File.unlink(@output)
    File.link(other, @output)
    expect { described_class.compile_rules(workspace: @own, output: @output, version: 6) }
      .to raise_error(Rubotty::Scripting::Unavailable, /precreated regular/)
  end

  it "canonicalizes scratch aliases and refuses ambient or read-root overlap" do
    alias_path = File.join(@dir, "alias")
    File.symlink(@own, alias_path)
    expect(described_class.compile_rules(workspace: alias_path, version: 6).last.first).to eq(File.realpath(@own))
    [Dir.tmpdir, "/usr", ENV["HOME"]].compact.each do |path|
      expect { described_class.compile_rules(workspace: path, version: 6) }
        .to raise_error(Rubotty::Scripting::Unavailable, /overlaps/)
    end
  end

  it "requires ABI6 signal isolation as well as the ABI3 filesystem rights" do
    expect { described_class.compile_rules(workspace: @own, version: 3) }
      .to raise_error(Rubotty::Scripting::Unavailable, /ABI 6/)
    allow(described_class).to receive(:compile_available?).and_return(false)
    expect { described_class.require_compile!({ "RUBOTTY_SCRIPT_ISOLATION" => "required" }) }
      .to raise_error(Rubotty::Scripting::Unavailable, /Landlock ABI 6/)
    expect { described_class.require_compile!({ "RUBOTTY_SCRIPT_ISOLATION" => "optional" }) }.not_to raise_error
  end

  it "does not treat an absent syscall filter as safe untrusted compilation" do
    allow(described_class).to receive(:compile_available?).and_return(true)
    allow(Rubotty::Scripting::Seccomp).to receive(:available?).and_return(false)
    expect { described_class.require_compile!({ "RUBOTTY_SCRIPT_ISOLATION" => "required" }) }
      .to raise_error(Rubotty::Scripting::Unavailable, /syscall isolation/)
  end

  it "passes the scoped signal bit to the full ruleset structure" do
    allow(described_class).to receive_messages(handled_fs: 7, handled_net: 3)
    allow(Rubotty::Scripting::Libc).to receive(:pointer).and_return(:pointer)
    expect(Rubotty::Scripting::Libc).to receive(:syscall)
      .with(described_class::CREATE_RULESET, :pointer, 24, 0).and_return(7)
    expect(described_class.create_ruleset(6, scoped: described_class::SCOPE_SIGNAL)).to eq(7)
  end

  it "routes a protected compiler through its own policy even if the runtime profile is unavailable" do
    confined = Rubotty::Scripting::Confined
    allow(described_class).to receive_messages(require_compile!: nil, compile_available?: true, available?: false)
    allow(Rubotty::Scripting::Seccomp).to receive(:available?).and_return(false)
    allow(Rubotty::Scripting::Limits).to receive(:available?).and_return(true)
    expect(confined).to receive(:fork_and_exec).with(hash_including(
      compile_workspace: File.realpath(@own), compile_output: @output,
      restrict: false, profile: nil, process_group: true
    )).and_return(confined::Started.new(4242, nil))
    confined.start(kind: :compile, binary: "controlled", chdir: @own, process_group: true, compile_output: @output)
  end

  it "keeps native Lua available without starting or requiring a compiler sandbox" do
    expect(Rubotty::Scripting::Confined).not_to receive(:require!)
    expect(Rubotty::Scripting::Compiler.new.compile("return 1", language: "lua")).to eq("return 1")
  end
end
