# frozen_string_literal: true

require "spec_helper"

# A declaration nothing reaches reads as a seam somebody is meant to use. Both
# of these were left behind by a refactor, and each named a rule that was really
# enforced elsewhere.
RSpec.describe "declarations nothing reaches" do
  it "leaves no unused symbolize helper on utility commands" do
    expect(Rubotty::Features::UtilityCommands.private_method_defined?(:symbolize)).to be(false)
  end

  # An empty directory is what Directory.new gives, so a constant standing for
  # one was never the thing #empty? or the router tested against.
  it "leaves no placeholder constant on the operator directory" do
    expect(Rubotty::Core::Moderation::Directory.constants).not_to include(:EMPTY)
  end

  it "still answers empty? for a directory built with no operators" do
    expect(Rubotty::Core::Moderation::Directory.new.empty?).to be(true)
  end
end
