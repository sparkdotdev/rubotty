# frozen_string_literal: true

require "spec_helper"

# The floor in .ruby-version is a project policy, so code written to work below
# it is dead: the branch never runs, and it keeps a reader guessing about which
# interpreters are really supported.
RSpec.describe "the Ruby floor" do
  let(:floor) { Gem::Version.new(File.read(File.expand_path("../../.ruby-version", __dir__)).strip) }

  it "is 4.0 or newer, which is what the README promises" do
    expect(floor).to be >= Gem::Version.new("4.0")
  end

  it "is what this process is running" do
    expect(Gem::Version.new(RUBY_VERSION).segments.first(2))
      .to eq(floor.segments.first(2))
  end

  # Thread::Queue#pop gained its timeout in Ruby 3.2, well under the floor, so
  # the IRC client's waits need no fallback for an interpreter without it.
  it "gives Thread::Queue#pop a timeout, so no caller needs a polling fallback" do
    queue = Thread::Queue.new

    expect(queue.pop(timeout: 0.01)).to be_nil
  end

  it "leaves no pre-floor fallback behind in the IRC client" do
    source = File.read(File.expand_path("../../lib/rubotty/adapters/irc/client.rb", __dir__))

    expect(source).not_to match(/Ruby\s*<?\s*3\.2|older interpreters/)
  end
end
