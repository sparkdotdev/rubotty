# frozen_string_literal: true

require "spec_helper"

# The wording every outbound decorates rather than spelling out itself.
RSpec.describe Rubotty::Core::Message do
  include Builders

  let(:origin) { endpoint("tg-general") }

  describe "#forwarded_notice" do
    it "names who the message was forwarded from" do
      msg = message(origin, text: "hi", forwarded_from: author(display_name: "Grace"))

      expect(msg.forwarded_notice).to eq("forwarded from Grace")
    end

    it "is nil when the message was not forwarded, the default" do
      expect(message(origin, text: "hi").forwarded_notice).to be_nil
    end
  end
end
