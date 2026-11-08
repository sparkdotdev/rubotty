# frozen_string_literal: true

require "spec_helper"

# Discord rejects the WHOLE application command registration when any single
# command or option description exceeds its length cap, so one long description
# costs every slash command on the platform.
RSpec.describe Rubotty::Core::CommandRegistry do
  let(:limit) { described_class::DESCRIPTION_LIMIT }

  it "gives every command a description within the platform limit" do
    described_class.all.each do |spec|
      length = spec.description.to_s.length
      expect(length).to be_between(1, limit),
                        "command /#{spec.name} description is #{length} characters, " \
                        "which must be between 1 and #{limit}"
    end
  end

  it "gives every argument a description within the platform limit" do
    described_class.all.each do |spec|
      spec.arguments.each do |argument|
        length = argument.description.to_s.length
        expect(length).to be_between(1, limit),
                          "option #{argument.name} of /#{spec.name} has a description of " \
                          "#{length} characters, which must be between 1 and #{limit}. " \
                          "Discord rejects the entire command registration over this limit."
      end
    end
  end
end
