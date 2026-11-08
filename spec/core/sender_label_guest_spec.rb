# frozen_string_literal: true

require "spec_helper"

# A guest is relayed under an unmistakable "Nickname@guest-user" identity, so
# members always know they are talking to a temporary outside guest.
RSpec.describe Rubotty::Core::SenderLabel do
  let(:identity) { { escape: ->(t) { t }, bold: ->(t) { "*#{t}*" } } }

  describe ".guest" do
    subject(:label) { described_class.guest(nickname: "Visiting Reviewer") }

    it "is flagged as a guest" do
      expect(label.guest?).to be(true)
    end

    it "renders the nickname bold with the fixed guest domain" do
      expect(label.render(**identity)).to eq("*Visiting Reviewer*@guest-user")
    end

    it "renders the same identity as plain text out of band" do
      expect(label.to_s).to eq("Visiting Reviewer@guest-user")
    end

    it "never takes the display-name-in-brackets form, whatever the fields hold" do
      forced = described_class.new(username: "nick", display_name: "A Human Name",
                                   platform: "discord", guest: true)
      expect(forced.render(**identity)).to eq("*nick*@guest-user")
    end

    it "distinguishes a guest label from a non-guest one with the same fields" do
      plain = described_class.new(username: "Sam", platform: described_class::GUEST_DOMAIN)
      guest = described_class.new(username: "Sam", platform: described_class::GUEST_DOMAIN, guest: true)
      expect(guest).not_to eq(plain)
    end
  end
end
