# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"
require "rbconfig"

RSpec.describe Rubotty::Scripting::Compiler, "resource bounds" do
  let(:code) { 'STDOUT.write("return 1")' }
  let(:dialect) do
    Rubotty::Scripting::Dialects::Dialect.new(
      name: "controlled", label: "Controlled", extension: ".controlled", comment: "--",
      binary: RbConfig.ruby, args: ["-e", code, "--"], output: :stdout, editor_mode: "lua"
    )
  end
  let(:compiler) { described_class.new(timeout: 1, source_limit: 128, output_limit: 128, diagnostic_limit: 64) }

  around do |example|
    Dir.mktmpdir("rubotty-compiler-resource-spec") do |dir|
      @dir = dir
      @requests = []
      example.run
    end
  end

  before do
    allow(Rubotty::Scripting::Dialects).to receive_messages(find!: dialect, installed?: true)
    allow(Rubotty::Scripting::Confined).to receive(:require!)
    allow(Rubotty::Scripting::Isolation).to receive(:grant)
    # Tiny controlled Ruby processes exercise the compiler supervisor, without
    # executing operator code or requiring account/filter support on the host.
    # Confined's own specs verify the account, filter and environment layers.
    allow(Rubotty::Scripting::Confined).to receive(:start) do |**request|
      @requests << request
      limits = request[:rlimits].reject { |name, _| name == :rlimit_as }
      pid = Process.spawn(request[:env], request[:binary], *request[:args],
                          **request[:redirects], **limits, chdir: request[:chdir],
                          pgroup: request[:process_group], close_others: true, unsetenv_others: true)
      Rubotty::Scripting::Confined::Started.new(pid, nil)
    end
  end

  it "keeps normal compiled output and requests the existing confinement limits plus a file ceiling" do
    expect(compiler.compile("ignored", language: "controlled")).to eq("return 1")
    expect(@requests.first).to include(kind: :compile, process_group: true)
    expect(@requests.first[:redirects][:in]).to eq(File::NULL)
    expect(@requests.first[:env]).to include("TMPDIR" => @requests.first[:chdir],
                                            "TMP" => @requests.first[:chdir], "TEMP" => @requests.first[:chdir],
                                            "PWD" => @requests.first[:chdir])
    expect(@requests.first[:rlimits]).to include(rlimit_as: described_class::MEMORY_BYTES,
                                               rlimit_cpu: 1, rlimit_nofile: 64, rlimit_core: 0)
    expect(@requests.first[:rlimits][:rlimit_fsize]).to eq(128) if Process.const_defined?(:RLIMIT_FSIZE)
  end

  it "rejects oversized source by bytes before starting a compiler" do
    expect { compiler.compile("é" * 65, language: "controlled") }
      .to raise_error(described_class::Failed, /128 byte input limit/)
    expect(@requests).to be_empty
  end

  it "still refuses compilation when a required confinement layer is unavailable" do
    allow(Rubotty::Scripting::Confined).to receive(:require!)
      .and_raise(Rubotty::Scripting::Unavailable, "required layer unavailable")
    expect { compiler.compile("ignored", language: "controlled") }
      .to raise_error(Rubotty::Scripting::Unavailable, /required layer unavailable/)
    expect(@requests).to be_empty
  end

  it "keeps a bounded diagnostic readable even when its bytes are not valid UTF-8" do
    dialect.args = ["-e", 'STDERR.binmode; STDERR.write("invalid: "); STDERR.write([255].pack("C")); exit 1', "--"]
    expect { compiler.compile("ignored", language: "controlled") }
      .to raise_error(described_class::Failed, /invalid:/)
  end

  it "refuses invalid compiled text without raising a string-decoding error in the caller" do
    dialect.args = ["-e", 'STDOUT.binmode; STDOUT.write([255].pack("C"))', "--"]
    expect { compiler.compile("ignored", language: "controlled") }
      .to raise_error(described_class::Failed, /not valid UTF-8/)
  end

  it "applies the same input ceiling to native Lua" do
    allow(Rubotty::Scripting::Dialects).to receive(:find!).and_call_original
    expect(compiler.compile("return 1", language: "lua")).to eq("return 1")
    expect { compiler.compile("x" * 129, language: "lua") }.to raise_error(described_class::Failed, /input limit/)
    expect(@requests).to be_empty
  end

  context "excessive stdout" do
    let(:code) { 'STDOUT.write("x" * 129)' }

    it "refuses output before retaining more than its compiled-byte ceiling" do
      expect { compiler.compile("ignored", language: "controlled") }
        .to raise_error(described_class::Failed, /128 byte output limit/)
    end
  end

  context "excessive stderr" do
    let(:code) { 'STDERR.write("x" * 65); STDOUT.write("return 1")' }

    it "refuses diagnostics before retaining more than their separate byte ceiling" do
      expect { compiler.compile("ignored", language: "controlled") }
        .to raise_error(described_class::Failed, /64 byte diagnostic output limit/)
    end
  end

  it "checks an ordinary compiler output file's size before reading it" do
    File.binwrite(File.join(@dir, "script.lua"), "x" * 129)
    expect { compiler.send(:read_output, @dir) }.to raise_error(described_class::Failed, /128 byte output limit/)
  end

  it "reports an empty generated file as having no runnable output" do
    dialect.output = :file
    dialect.args = ["-e", 'File.write("script.lua", "")', "--"]
    expect { compiler.compile("ignored", language: "controlled") }
      .to raise_error(described_class::Failed, /produced nothing to run/)
  end

  it "bounds the read even if a file grows after its size check" do
    path = File.join(@dir, "script.lua")
    File.binwrite(path, "x" * 129)
    allow(File).to receive(:open).and_wrap_original do |original, *args, &block|
      original.call(*args) do |file|
        allow(file).to receive(:stat).and_return(instance_double(File::Stat, file?: true, size: 1))
        block.call(file)
      end
    end
    expect { compiler.send(:read_output, @dir) }.to raise_error(described_class::Failed, /128 byte output limit/)
  end

  it "rejects symlinks and directories as compiled output" do
    path = File.join(@dir, "script.lua")
    File.symlink(__FILE__, path)
    expect { compiler.send(:read_output, @dir) }.to raise_error(described_class::Failed, /other than a file/)
    File.unlink(path)
    Dir.mkdir(path)
    expect { compiler.send(:read_output, @dir) }.to raise_error(described_class::Failed, /other than a file/)
  end

  it "opens a FIFO nonblocking and rejects it without waiting for a writer" do
    path = File.join(@dir, "script.lua")
    File.mkfifo(path)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { compiler.send(:read_output, @dir) }.to raise_error(described_class::Failed, /other than a file/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
  end

  context "file output" do
    let(:code) { 'File.binwrite("script.lua", "return 1")' }

    before { dialect.output = :file }

    it "precreates the sole declared output before starting a file compiler" do
      dialect.args = ["-e", 'abort unless File.file?("script.lua") && File.zero?("script.lua"); File.write("script.lua", "return 1")', "--"]
      expect(compiler.compile("ignored", language: "controlled")).to eq("return 1")
      expect(@requests.last[:compile_output]).to eq(File.join(@requests.last[:chdir], "script.lua"))
    end

    it "runs a separate type check before reading a normal generated file" do
      dialect.check_args = ["-e", 'File.write("checked", "yes")', "--"]
      dialect.args = ["-e", 'abort unless File.exist?("checked"); File.binwrite("script.lua", "return 1")', "--"]
      expect(compiler.compile("ignored", language: "controlled")).to eq("return 1")
      expect(@requests.size).to eq(2)
    end

    it "uses the file-size rlimit to stop a child growing its generated file past the ceiling" do
      skip "this platform has no file-size rlimit" unless Process.const_defined?(:RLIMIT_FSIZE)

      dialect.args = ["-e", 'begin; File.binwrite("script.lua", "x" * 129); rescue Errno::EFBIG; exit 3; end', "--"]
      size = nil
      allow(compiler).to receive(:capture).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs)
      ensure
        path = File.join(args[2], "script.lua")
        size = File.size(path) if File.exist?(path)
      end
      expect { compiler.compile("ignored", language: "controlled") }.to raise_error(described_class::Failed)
      expect(size).to be <= 128
    end

    it "shares one wall-clock deadline across type checking and generation" do
      compiler = described_class.new(timeout: 0.6, output_limit: 128, diagnostic_limit: 1024)
      dialect.check_args = ["-e", "sleep 0.35", "--"]
      dialect.args = ["-e", 'sleep 0.35; File.write("script.lua", "return 1")', "--"]
      expect { compiler.compile("ignored", language: "controlled") }
        .to raise_error(described_class::Failed, /did not finish within 0.6 seconds/)
      expect(@requests.size).to eq(2)
    end
  end

  it "charges time spent starting the child against the same deadline" do
    fast = described_class.new(timeout: 0.05)
    allow(fast).to receive(:spawn_child).and_wrap_original do |original, *args, **kwargs|
      sleep 0.06
      original.call(*args, **kwargs)
    end
    expect { fast.compile("ignored", language: "controlled") }
      .to raise_error(described_class::Failed, /did not finish within 0.05 seconds/)
  end

  it "signals helpers before reaping the group leader and never signals a reaped numeric identity" do
    steps = []
    status = instance_double(Process::Status)
    allow(compiler).to receive(:exited?).with(4242).and_return(true)
    allow(compiler).to receive(:signal) { |pid| steps << [:signal, pid] }
    allow(Process).to receive(:wait2).with(4242, Process::WNOHANG) do
      steps << :reap
      [4242, status]
    end

    expect(compiler.send(:wait, 4242, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)).to eq(status)
    compiler.send(:kill, 4242, reaped: true)
    expect(steps).to eq([[:signal, -4242], :reap])
  end

  context "closed output pipes" do
    let(:code) { 'STDOUT.reopen(File::NULL, "w"); STDERR.reopen(File::NULL, "w"); sleep 5' }

    it "still enforces the deadline while waiting for the compiler to exit" do
      fast = described_class.new(timeout: 0.1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { fast.compile("ignored", language: "controlled") }
        .to raise_error(described_class::Failed, /did not finish within 0.1 seconds/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    end
  end

  [false, true].each do |successful_leader|
    it "terminates compiler helpers when the leader #{successful_leader ? 'finishes' : 'times out'}" do
      marker = File.join(@dir, "helper-survived")
      helper = "fork { STDOUT.reopen(File::NULL, 'w'); STDERR.reopen(File::NULL, 'w'); " \
               "sleep 0.4; File.write(#{marker.inspect}, 'still running') }; "
      ending = successful_leader ? 'STDOUT.write("return 1")' :
                 'STDOUT.reopen(File::NULL, "w"); STDERR.reopen(File::NULL, "w"); sleep 5'
      dialect.args = ["-e", helper + ending, "--"]
      fast = described_class.new(timeout: successful_leader ? 1 : 0.1)
      if successful_leader
        expect(fast.compile("ignored", language: "controlled")).to eq("return 1")
      else
        expect { fast.compile("ignored", language: "controlled") }.to raise_error(described_class::Failed)
      end
      sleep 0.5
      expect(File.exist?(marker)).to be(false)
    end
  end
end
