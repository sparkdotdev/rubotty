# frozen_string_literal: true

require "spec_helper"

# Runtime hands Router.new its collaborators and Router hands most straight on
# to #build_features. Both signatures are written out, so one added to only one
# of them raises at construction: :bot_messages did, and every Runtime example
# failed at once rather than one spec naming the seam.
RSpec.describe Rubotty::Core::Router, "the collaborator seam" do
  def keywords(method)
    method.parameters.select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)
  end

  let(:accepted) { keywords(described_class.instance_method(:initialize)) }
  let(:forwarded) { keywords(described_class.instance_method(:build_features)) }

  # Anything #build_features takes and #initialize does not can only ever be
  # nil, since nothing upstream has a way to pass it. The other direction is
  # fine and expected: Router keeps several collaborators for itself.
  it "accepts every collaborator it forwards" do
    orphaned = forwarded - accepted

    expect(orphaned).to be_empty,
                        "Router#build_features takes #{orphaned.inspect}, which Router#initialize does not, " \
                        "so nothing can ever supply them."
  end

  it "still takes the collaborator whose absence broke every Runtime example" do
    expect(accepted).to include(:bot_messages)
    expect(forwarded).to include(:bot_messages)
  end
end
