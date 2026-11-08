# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The account a script's process runs as, which is the layer outside sandbox.lua. The
# interesting states are ones this machine is not in, since a developer's machine is not
# root and a root deployment is not a developer's machine, so Process.euid and the passwd
# lookup are both stood in for.
RSpec.describe Rubotty::Scripting::Isolation do
  around do |example|
    # Startup exercises the other layers while account/profile methods are
    # stubbed. Do not let those synthetic capability results reach kernel gates.
    layers = [described_class, Rubotty::Scripting::Limits,
              Rubotty::Scripting::Seccomp, Rubotty::Scripting::Landlock]
    layers.each(&:reset!)
    example.run
  ensure
    layers.each(&:reset!)
  end

  def with_setting(value)
    previous = ENV.fetch(described_class::SETTING, nil)
    ENV[described_class::SETTING] = value
    yield
  ensure
    ENV[described_class::SETTING] = previous
  end

  def unprivileged(uid, gid = uid) = described_class::Account.new(uid, gid)

  describe "a deployment that cannot hand out an account" do
    before { allow(Process).to receive(:euid).and_return(501) }

    it "resolves none" do
      expect(described_class.account).to be_nil
      expect(described_class.spawn_options).to eq({})
    end

    it "refuses to run a script rather than running it in this process's own account" do
      with_setting("required") do
        expect { described_class.require! }
          .to raise_error(Rubotty::Scripting::Unavailable, /cannot be confined here/)
      end
    end

    it "says why, so the refusal is actionable" do
      expect(described_class.reason).to match(/does not run as root/)
    end

    it "runs anyway once an operator has said out loud that they accept it" do
      with_setting("optional") { expect { described_class.require! }.not_to raise_error }
    end

    # The pool asks its children, so this is what turns the whole feature off
    # rather than failing one rule at a time.
    it "reports the runtime child unavailable while it is refusing" do
      child = Rubotty::Scripting::Child.new(binary: "/usr/bin/lua", logger: Rubotty::Log.null)

      with_setting("required") { expect(child.available?).to be(false) }
      with_setting("optional") { expect(child.available?).to be(true) }
    end
  end

  describe "a root deployment" do
    before do
      allow(Process).to receive(:euid).and_return(0)
      allow(Etc).to receive(:getpwnam).with("rubotty-script").and_raise(ArgumentError)
      allow(Etc).to receive(:getpwnam).with("nobody").and_return(unprivileged(65_534))
    end

    it "hands a child the unprivileged account the image carries" do
      expect(described_class.account).to eq({ uid: 65_534, gid: 65_534 })
      expect(described_class.spawn_options).to eq({ uid: 65_534, gid: 65_534 })
    end

    it "prefers an account made for the job over the shared one" do
      allow(Etc).to receive(:getpwnam).with("rubotty-script").and_return(unprivileged(1101, 1102))

      expect(described_class.account).to eq({ uid: 1101, gid: 1102 })
    end

    it "takes a numbered account at face value, since an image may carry no passwd entry" do
      with_setting("required") do
        ENV["RUBOTTY_SCRIPT_USER"] = "1234"
        expect(described_class.account).to eq({ uid: 1234, gid: 1234 })
      ensure
        ENV.delete("RUBOTTY_SCRIPT_USER")
      end
    end

    # Falling back to some other account would run scripts somewhere the
    # operator never asked for, which is worse than saying nothing works.
    it "turns scripts off when the account an operator named is not there" do
      allow(Etc).to receive(:getpwnam).with("scripts").and_raise(ArgumentError)
      ENV["RUBOTTY_SCRIPT_USER"] = "scripts"

      expect(described_class.account).to be_nil
      expect(described_class.reason).to match(/looked for scripts/)
    ensure
      ENV.delete("RUBOTTY_SCRIPT_USER")
    end

    # Handing out root would be this process's own account under another name,
    # which is the thing being moved away from.
    it "refuses to treat root as an account to confine anything in" do
      ENV["RUBOTTY_SCRIPT_USER"] = "0"
      expect(described_class.account).to be_nil
    ensure
      ENV.delete("RUBOTTY_SCRIPT_USER")
    end
  end

  # A confined child that cannot read sandbox.lua exits before it writes a
  # frame, which from a chat room looks like nothing at all.
  describe "checking the script account can reach a file" do
    it "says yes when there is no account, since nothing has moved" do
      allow(Process).to receive(:euid).and_return(501)

      expect(described_class.reachable?("/root/nothing-here")).to be(true)
    end

    context "with an account" do
      # Under /tmp rather than Dir.tmpdir, because a Mac's per-user temporary
      # directory is 0700 and every path under it is unreachable by anyone
      # else, which is the very thing being measured.
      around do |example|
        Dir.mktmpdir("rubotty-reach", "/tmp") do |dir|
          @dir = dir
          example.run
        end
      end

      before { allow(described_class).to receive(:account).and_return({ uid: 65_534, gid: 65_534 }) }

      it "says yes for a world readable file under a traversable directory" do
        path = File.join(@dir, "sandbox.lua")
        File.write(path, "return 1")
        File.chmod(0o755, @dir)
        File.chmod(0o644, path)

        expect(described_class.reachable?(path)).to be(true)
      end

      it "says no when the directory above it shuts everybody else out" do
        path = File.join(@dir, "sandbox.lua")
        File.write(path, "return 1")
        File.chmod(0o644, path)
        File.chmod(0o750, @dir)

        expect(described_class.reachable?(path)).to be(false)
      end

      it "says no when the file itself is unreadable" do
        path = File.join(@dir, "sandbox.lua")
        File.write(path, "return 1")
        File.chmod(0o755, @dir)
        File.chmod(0o640, path)

        expect(described_class.reachable?(path)).to be(false)
      end

      it "says no for a file that is not there" do
        expect(described_class.reachable?(File.join(@dir, "gone.lua"))).to be(false)
      end
    end
  end

  # The transpiler owns its compile directory now, so what it leaves behind is
  # attacker controlled and this process reads it as root.
  describe "reading a transpiler's output back" do
    it "refuses a symlink left where the output belongs" do
      Dir.mktmpdir("rubotty-symlink") do |dir|
        File.write(File.join(dir, "secret"), "every token")
        File.symlink(File.join(dir, "secret"), File.join(dir, "script.lua"))
        compiler = Rubotty::Scripting::Compiler.new(logger: Rubotty::Log.null)

        expect { compiler.send(:read_output, dir) }
          .to raise_error(Rubotty::Scripting::Compiler::Failed, /other than a file/)
      end
    end

    it "reads an ordinary file the transpiler wrote" do
      Dir.mktmpdir("rubotty-symlink") do |dir|
        File.write(File.join(dir, "script.lua"), "return 1")
        compiler = Rubotty::Scripting::Compiler.new(logger: Rubotty::Log.null)

        expect(compiler.send(:read_output, dir)).to eq("return 1")
      end
    end
  end

  describe "handing a compile directory over" do
    it "does nothing when there is no account to hand it to" do
      allow(Process).to receive(:euid).and_return(501)

      expect { described_class.grant("/nonexistent") }.not_to raise_error
    end

    it "refuses loudly when the handover fails, rather than leaving a child locked out" do
      allow(described_class).to receive(:account).and_return({ uid: 65_534, gid: 65_534 })
      allow(File).to receive(:chown).and_raise(Errno::EPERM)

      expect { described_class.grant("/tmp") }
        .to raise_error(Rubotty::Scripting::Unavailable, /working directory/)
    end
  end

  # Both entry points, because the runtime child fires on every rule while the
  # compiler fires once at save time, and only one of them was ever the one
  # anybody noticed.
  describe "the two places a script's process is started" do
    let(:account) { { uid: 4321, gid: 8765 } }

    before do
      allow(described_class).to receive(:account).and_return(account)
      allow(described_class).to receive(:grant)
      # Pinned to the fork this takes on its own account, which is what a host
      # with no filter to install still does once there is a real account to
      # become: a spawn only ever calls setgid and setuid, so an account never
      # reaches Process.spawn directly any more.
      allow(Rubotty::Scripting::Seccomp).to receive_messages(runtime_profile: nil, compile_profile: nil)
      allow(Rubotty::Scripting::Landlock).to receive(:available?).and_return(false)
      allow(Rubotty::Scripting::Landlock).to receive(:compile_available?).and_return(false)
    end

    it "starts the pooled runtime child in the script account" do
      child = Rubotty::Scripting::Child.new(binary: "/usr/bin/lua", logger: Rubotty::Log.null)
      expect(Process).not_to receive(:spawn)
      expect(Rubotty::Scripting::Confined).to receive(:fork_for_isolation).and_raise(Errno::EPERM)

      expect { child.run(source: "return 1") }.to raise_error(Errno::EPERM)
    end

    it "starts a save-time transpiler in the script account" do
      allow(Rubotty::Scripting::Dialects).to receive(:installed?).and_return(true)
      transpiler = Rubotty::Scripting::Compiler.new(logger: Rubotty::Log.null)
      expect(Process).not_to receive(:spawn)
      expect(Rubotty::Scripting::Confined).to receive(:fork_for_isolation).and_raise(Errno::EPERM)

      expect { transpiler.compile("(print 1)", language: "fennel") }.to raise_error(Errno::EPERM)
    end
  end
end
