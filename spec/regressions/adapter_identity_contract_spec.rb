# frozen_string_literal: true

require "spec_helper"

RSpec.describe "adapter identity and optional capability declarations" do
  [Rubotty::Adapters::Irc::Adapter, Rubotty::Adapters::Xmpp::Adapter].each do |klass|
    it "treats #{klass} nicknames as session identities" do
      expect(klass.identity_durability).to eq(:session)
      expect(klass.allocate.identity_durability).to eq(:session)
    end
  end

  { Rubotty::Adapters::Matrix::Adapter => %i[supports_backfill? supports_reaction_backfill? supports_gap_ownership? supports_leave? supports_space_notice?],
    Rubotty::Adapters::Fluxer::Adapter => %i[supports_leave? supports_space_notice?],
    Rubotty::Adapters::Stoat::Adapter => %i[supports_space_notice?] }.each do |klass, methods|
    methods.each do |method|
      it "advertises #{klass} #{method} consistently on the class and instance" do
        expect(klass.public_send(method)).to be(true)
        expect(klass.allocate.public_send(method)).to be(true)
      end
    end
  end
end
