# frozen_string_literal: true

require "spec_helper"

# The deployment-configured floor grants owner rights by bare handle, safe only where the
# platform issues and holds the handle for one person. On IRC/XMPP the
# username is a nick picked at connect; on Stoat/Fluxer an unregistered
# handle is free to take, so matching there hands a stranger owner rights deployment-wide.
RSpec.describe "the bare handle floor's platform scope" do
  let(:operators) do
    Rubotty::Security::ProtectedOperators.new(usernames: ["maintainer"], matrix_ids: ["@owner:example.org"])
  end
  let(:viewers) do
    Rubotty::Security::DashboardViewers.new(usernames: ["maintainer"], matrix_ids: ["@owner:example.org"])
  end
  let(:administrators) do
    Rubotty::Security::DashboardAdministrators.new(usernames: ["maintainer"],
                                                   matrix_ids: ["@owner:example.org"])
  end

  %i[telegram discord].each do |adapter|
    it "still recognises the handle on #{adapter}, where the platform issues it" do
      expect(operators.owner?(adapter: adapter, username: "maintainer")).to be(true)
      expect(viewers.viewer?(adapter: adapter, username: "maintainer")).to be(true)
      expect(administrators.administrator?(adapter: adapter, username: "maintainer")).to be(true)
    end
  end

  %i[irc xmpp stoat fluxer].each do |adapter|
    it "never grants owner on #{adapter}, where the handle is not the platform's to vouch for" do
      expect(operators.owner?(adapter: adapter, username: "maintainer")).to be(false)
      expect(operators.operator_for(adapter: adapter, username: "maintainer")).to be_nil
    end

    it "never grants a dashboard viewer on #{adapter}" do
      expect(viewers.viewer?(adapter: adapter, username: "maintainer")).to be(false)
    end

    it "never grants the administrator role on #{adapter}, which would be the whole deployment" do
      expect(administrators.administrator?(adapter: adapter, username: "maintainer")).to be(false)
    end
  end

  it "keeps matching the full MXID on Matrix, which was always id based" do
    expect(operators.owner?(adapter: :matrix, native_id: "@owner:example.org")).to be(true)
    expect(operators.owner?(adapter: :matrix, username: "owner")).to be(false)
  end

  it "does not replace a presented Matrix id with a privileged username" do
    identity = { adapter: :matrix, native_id: "@stranger:example.org", username: "@owner:example.org" }
    expect(operators.owner?(**identity)).to be(false)
    expect(viewers.viewer?(**identity)).to be(false)
    expect(administrators.administrator?(**identity)).to be(false)
    expect(operators.owner?(adapter: :matrix, username: "@owner:example.org")).to be(true)
  end

  # An adapter nobody has thought about yet must not inherit the floor.
  it "answers false for an adapter on neither list" do
    expect(operators.owner?(adapter: :something_new, username: "maintainer")).to be(false)
    expect(viewers.viewer?(adapter: :something_new, username: "maintainer")).to be(false)
    expect(administrators.administrator?(adapter: :something_new, username: "maintainer")).to be(false)
  end
end
