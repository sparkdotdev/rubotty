# frozen_string_literal: true

require "spec_helper"

# What a room can actually do. platforms() gave a script a list of names and
# nothing else, so every rule that cared hard coded a platform-to-capability
# table that goes stale the moment an adapter learns something new. The fold
# worth pinning: the weakest platform in the room wins, same as truncate.
RSpec.describe Rubotty::Core::Router, "what a room can do" do
  def fold(pairs, platforms = [])
    described_class.allocate.send(:capability_table, pairs, platforms)
  end

  def platform(capabilities, dm: false)
    adapter = Class.new do
      define_method(:supports_admin_dm?) { dm }
    end.new
    [adapter, capabilities]
  end

  let(:full) do
    Rubotty::Adapters::Capabilities.new(edits: true, deletes: true, replies: true,
                                        threads: true, reactions: true)
  end

  let(:bare) { Rubotty::Adapters::Capabilities.new }

  it "says yes when the one platform in the room can do it" do
    answer = fold([platform(full, dm: true)])

    expect(answer.values_at("reactions", "edit", "delete", "reply", "threads", "private_message"))
      .to all(be(true))
  end

  it "says no as soon as one bridged platform cannot" do
    answer = fold([platform(full, dm: true), platform(bare)])

    expect(answer.values_at("reactions", "edit", "delete", "reply", "threads", "private_message"))
      .to all(be(false))
  end

  # A script degrades to the careful branch rather than seeing an exception or a
  # table of nils.
  it "answers everything false for a room with no reachable adapter" do
    answer = fold([])

    expect(answer["reactions"]).to be(false)
    expect(answer["private_message"]).to be(false)
  end

  # The length comes from Markup::LIMITS, keyed by platform name, not from a
  # per-adapter capability: nothing on Capabilities carries this number.
  it "answers the length truncate really cuts at" do
    expect(fold([platform(full)], %w[irc discord])["longest_message"]).to eq(400)
    expect(fold([platform(full)], %w[discord])["longest_message"]).to eq(2000)
  end

  it "names exactly the keys the catalog promises" do
    promised = %w[reactions edit delete reply threads private_message longest_message]

    expect(fold([]).keys).to match_array(promised)
    promised.each do |field|
      expect(Rubotty::Scripting::HostFunctions::CATALOG["room_capabilities"].returns).to include(field)
    end
  end
end
