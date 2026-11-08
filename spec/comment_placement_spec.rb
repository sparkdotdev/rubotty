# frozen_string_literal: true

require "spec_helper"

# A blank line between a doc comment and the definition below it detaches the
# two: the text reads as belonging to whatever came before, documenting
# nothing. A section banner, a magic comment and a tooling directive are the
# only comments allowed to sit above a blank line.
RSpec.describe "doc comment placement in lib" do
  # Both banner styles the codebase uses: a rule on its own, and "--- name ---".
  BANNER = /\A\s*#\s*[-=]{3,}/
  DIRECTIVE = /\A\s*#\s*(frozen_string_literal|encoding|warn_indent|rubocop|:nodoc)/

  def detached_blocks(path)
    lines = File.readlines(path, chomp: true, encoding: "UTF-8")
    lines.each_index.filter_map do |i|
      next unless lines[i].strip.empty?

      previous = lines[i - 1].to_s
      following = lines[i + 1].to_s
      next unless previous.match?(/\A\s*#/) && !previous.match?(BANNER) && !previous.match?(DIRECTIVE)
      next unless following.match?(/\A\s*(def|class\s|module\s)/)

      "#{path}:#{i + 2} #{following.strip}"
    end
  end

  it "attaches every doc comment to the definition it describes" do
    offenders = Dir.glob("lib/**/*.rb").sort.flat_map { |path| detached_blocks(path) }

    expect(offenders).to be_empty, "detached from the definition below:\n#{offenders.join("\n")}"
  end
end
