# frozen_string_literal: true

require "spec_helper"

# The runtime picks one of these two for an adapter's DM route, so an adapter
# calls whichever it got and cannot know which. They have to accept the same
# keywords: the console did not take `subject:` after Telegram began sending
# it, and every operator DM command raised ArgumentError while CI stayed green.
RSpec.describe "the DM lane contract" do
  def keywords(klass)
    klass.instance_method(:handle_dm).parameters
         .select { |kind, _| %i[key keyreq].include?(kind) }
         .map(&:last)
         .sort
  end

  let(:console) { keywords(Rubotty::ControlPlane::OperatorConsole) }
  let(:lane) { keywords(Rubotty::ControlPlane::ControlLane) }

  it "has both lanes accepting the same keywords, since one stands in for the other" do
    expect(console).to eq(lane),
                       "OperatorConsole#handle_dm takes #{console.inspect} and " \
                       "ControlLane#handle_dm takes #{lane.inspect}. An adapter calls whichever " \
                       "the runtime wired, so a keyword only one of them takes raises on the other."
  end

  # Named rather than only compared, so removing one from both at once still
  # fails here and has to be a deliberate change to this list.
  it "accepts the keywords every adapter's DM route sends" do
    expect(console).to include(:adapter, :account, :author, :text, :quoted, :subject)
  end
end
