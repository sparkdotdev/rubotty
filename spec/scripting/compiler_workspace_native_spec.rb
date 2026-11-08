# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"
require "open3"

RSpec.describe "compiler workspace enforcement in the kernel", if: RUBY_PLATFORM.include?("linux") do
  before(:context) do
    @root = Dir.mktmpdir("rubotty-compile-native", ENV.fetch("RUNNER_TEMP", "/tmp"))
    File.chmod(0o755, @root)
    @probe = File.join(@root, "probe")
    prebuilt = ENV["RUBOTTY_COMPILER_PROBE"]
    if prebuilt && !prebuilt.empty?
      # The image harness binds this fixture's source, binary digest and ELF
      # architecture. Production images do not need a C compiler installed.
      File.open(prebuilt, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        raise "the prebuilt compiler probe must be a regular executable" unless file.stat.file? && file.stat.executable?

        IO.copy_stream(file, @probe)
      end
      File.chmod(0o755, @probe)
    else
      source = File.expand_path("../fixtures/scripting/compiler_workspace_probe.c", __dir__)
      output, status = Open3.capture2e("cc", "-Wall", "-Wextra", "-Werror", source, "-o", @probe)
      raise "could not build the finite compiler probe: #{output}" unless status.success?
    end
  end

  after(:context) { FileUtils.remove_entry(@root) if @root }

  around do |example|
    previous = ENV[Rubotty::Scripting::Isolation::SETTING]
    ENV[Rubotty::Scripting::Isolation::SETTING] = "required"
    example.run
  ensure
    previous.nil? ? ENV.delete(Rubotty::Scripting::Isolation::SETTING) : ENV[Rubotty::Scripting::Isolation::SETTING] = previous
  end

  before do
    skip "untrusted compile needs an enforced syscall profile" unless Rubotty::Scripting::Seccomp.available?
    skip "untrusted compile needs Landlock ABI6 and its real workspace probe" unless Rubotty::Scripting::Landlock.compile_available?

    @own = Dir.mktmpdir("own-", @root)
    @other = Dir.mktmpdir("other-", @root)
    @sibling_file = File.join(@other, "one")
    @output_file = File.join(@own, "script.lua")
    File.write(@sibling_file, "x")
    File.write(@output_file, "")
    Rubotty::Scripting::Isolation.grant(@own, @other, @sibling_file, @output_file)
  end

  after do
    [@own, @other].compact.each { |dir| FileUtils.remove_entry(dir) if File.exist?(dir) }
  end

  def run_probe(*args, binary: @probe, file_output: false)
    path = File.join(@own, "script.controlled")
    File.write(path, "x")
    Rubotty::Scripting::Isolation.grant(path)
    dialect = Rubotty::Scripting::Dialects::Dialect.new(binary: binary, args: args,
                                                     output: file_output ? :file : :stdout)
    Rubotty::Scripting::Compiler.new(timeout: 2).send(:capture, dialect, path, @own)
  end

  it "overwrites its declared one-byte output but cannot read or overwrite a same-UID sibling file" do
    _, _, status = run_probe("--write", @output_file, file_output: true)
    expect(status).to be_success
    expect(File.read(@output_file)).to eq("x")
    _, _, read_status = run_probe("--read", @sibling_file)
    _, _, write_status = run_probe("--write", @sibling_file)
    expect(read_status.exitstatus).to eq(77)
    expect(write_status.exitstatus).to eq(77)
    expect(File.read(@sibling_file)).to eq("x")
  end

  it "cannot create scratch files, overwrite its source or remove the declared output" do
    source = File.join(@own, "script.controlled")
    new_file = File.join(@own, "undeclared")
    _, _, create_status = run_probe("--write", new_file, file_output: true)
    _, _, source_status = run_probe("--write", source, file_output: true)
    _, _, remove_status = run_probe("--remove", @output_file, file_output: true)
    _, _, stdout_write_status = run_probe("--write", @output_file)
    expect([create_status, source_status, remove_status, stdout_write_status].map(&:exitstatus)).to eq([77] * 4)
    expect(File.exist?(new_file)).to be(false)
    expect(File.read(source)).to eq("x")
    expect(File.read(@output_file)).to eq("")
  end

  %w[fork memfd].each do |action|
    it "denies #{action} creation without growing the invocation" do
      _, _, status = run_probe("--#{action}")
      expect(status).to be_signaled
      expect(status.termsig).to eq(Rubotty::Scripting::Seccomp::SIGSYS)
    end
  end

  %w[fallocate file-ioctl].each do |action|
    it "denies the #{action} allocation path even on the declared output" do
      _, _, status = run_probe("--#{action}", @output_file, file_output: true)
      expect(status).to be_signaled
      expect(status.termsig).to eq(Rubotty::Scripting::Seccomp::SIGSYS)
      expect(File.size(@output_file)).to eq(0)
    end
  end

  it "caps compiler descriptors at 64 for both soft and hard limits" do
    out, _, status = run_probe("--fd-limit")
    expect(status).to be_success
    expect(out).to eq("64:64")
  end

  %w[chmod chown utime xattr group session namespace].each do |action|
    it "denies post-setup #{action} without mutating the sibling fixture" do
      _, _, status = run_probe("--#{action}", @sibling_file)
      expect(status).to be_signaled
      expect(status.termsig).to eq(Rubotty::Scripting::Seccomp::SIGSYS)
      expect(File.read(@sibling_file)).to eq("x")
    end
  end

  it "keeps shebang exec usable within the read allowlist" do
    script = File.join(@root, "compiler.sh")
    File.write(script, "#!/bin/sh\nprintf '%s' 'return 1'\n")
    File.chmod(0o755, script)
    out, _, status = run_probe(binary: script)
    expect(status).to be_success
    expect(out).to eq("return 1")
  end

  it "keeps self signals usable but denies signals and limit changes to a same-UID peer outside the invocation" do
    ready_read, ready_write = IO.pipe
    peer = fork do
      ready_read.close
      Rubotty::Scripting::Confined.become_the_script_account
      ready_write.write("x")
      ready_write.close
      sleep 5
      exit!(0)
    end
    ready_write.close
    expect(IO.select([ready_read], nil, nil, 2)).not_to be_nil
    expect(ready_read.read(1)).to eq("x")
    ready_read.close
    # Prove the shared-UID DAC permission before applying the invocation policy.
    plain = Rubotty::Scripting::Confined.fork_for_isolation(
      @probe, ["--signal", peer.to_s], {}, { in: File::NULL, out: File::NULL, err: File::NULL }, {}, nil
    )
    expect(Process.waitpid2(plain.pid).last).to be_success
    _, _, self_status = run_probe("--self-signal")
    _, _, peer_status = run_probe("--signal", peer.to_s)
    _, _, limit_status = run_probe("--peer-limit", peer.to_s)
    expect(self_status).to be_success
    expect(peer_status.exitstatus).to eq(77)
    expect(limit_status).to be_signaled
    expect(limit_status.termsig).to eq(Rubotty::Scripting::Seccomp::SIGSYS)
  ensure
    [ready_read, ready_write].compact.each { |io| io.close unless io.closed? }
    if peer
      Process.kill("KILL", peer) rescue Errno::ESRCH
      Process.waitpid(peer) rescue Errno::ECHILD
    end
  end

  it "applies the workspace policy after dropping to the configured scripting account" do
    account = Rubotty::Scripting::Isolation.account
    skip "this privilege gate needs a separate scripting account" if account.nil?

    out, _, status = run_probe("--identity")
    expect(status).to be_success
    expect(out.split(":").map(&:to_i)).to eq([account[:uid], account[:gid], 0])
  end

  { "teal" => "return 1", "fennel" => "(+ 1 1)", "moonscript" => "1 + 1" }.each do |language, source|
    it "still compiles ordinary #{language} source under the required policy" do
      skip "this privilege gate needs a separate scripting account" unless Rubotty::Scripting::Isolation.available?
      skip "#{language} is not installed" unless Rubotty::Scripting::Dialects.available?(language)

      result = Rubotty::Scripting::Compiler.new.compile(source, language: language)
      expect(result.strip).not_to be_empty
    end
  end
end
