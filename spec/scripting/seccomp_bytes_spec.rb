# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The filter, compared against the bytes it used to assemble. spec/scripting/seccomp_spec.rb
# runs the program through a BPF machine and says what it means; this one is narrower and
# blunter: the same instructions in the same order, to the byte, so a rewrite of the layer
# that installs the filter can be held to leaving the filter alone.
RSpec.describe Rubotty::Scripting::Seccomp do
  SECCOMP_PROGRAM_FIXTURE = File.expand_path("seccomp_programs.txt", __dir__)

  # The descriptor the gated profiles in the fixture were assembled against.
  RECORDED_EXEC_FD = 9

  # Each fixture line as architecture, profile and the expected hex.
  def self.recorded
    lines = File.readlines(SECCOMP_PROGRAM_FIXTURE, chomp: true)
    lines.reject { |line| line.start_with?("#") || line.strip.empty? }.map do |line|
      architecture, profile, hex = line.split
      [architecture, profile.to_sym, hex]
    end
  end

  recorded.each do |architecture, profile, hex|
    it "assembles the #{profile} filter for #{architecture} to the same bytes it always did" do
      allow(described_class).to receive(:architecture).and_return(architecture)
      program = described_class.program(profile, exec_fd: RECORDED_EXEC_FD)

      expect(program.to_s.unpack1("H*")).to eq(hex)
    end
  end

  # A profile or an architecture with no line in the fixture would pass the loop
  # above by not being in it, so the coverage is asserted rather than assumed.
  it "records every architecture and profile there is" do
    expected = described_class::SYSCALLS.keys.product(described_class::PROFILES.keys)
    covered = self.class.recorded.map { |architecture, profile, _| [architecture, profile] }

    expect(covered).to match_array(expected)
  end
end
