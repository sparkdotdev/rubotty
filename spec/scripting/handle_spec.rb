# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The token a script keeps in order to come back to a message it posted. The only use for
# one is across invocations, and the only thing that survives between two invocations is a
# memo, which holds strings, so what matters most is that a handle goes through a memo and
# back out unchanged, and anything else a script hands over names nothing rather than raising.
RSpec.describe Rubotty::Scripting::Handle do
  def ref(endpoint, native) = described_class::Ref.new(endpoint_id: endpoint, native_id: native)

  it "names every copy of one logical message, in order" do
    handle = described_class.of([ref("tg-general", "101"), ref("dc-general", "202")])

    expect(described_class.refs(handle)).to eq([ref("tg-general", "101"), ref("dc-general", "202")])
  end

  # Array() asks a Core::MessageRef for #to_a and gets its two fields back as
  # two entries, which turned one ref into two broken ones.
  it "takes one ref on its own, rather than reading it as a list of its fields" do
    handle = described_class.of(Rubotty::Core::MessageRef.new("tg-general", "101"))

    expect(described_class.refs(handle)).to eq([ref("tg-general", "101")])
  end

  # An endpoint key carries colons and a Matrix event id carries one too, so
  # anything that split a plain string on a separator would take these apart in
  # the wrong place.
  it "survives ids with punctuation in them" do
    handle = described_class.of([ref("ch:telegram:tg:-1001/1", "$abc:matrix.example")])

    expect(described_class.refs(handle))
      .to eq([ref("ch:telegram:tg:-1001/1", "$abc:matrix.example")])
  end

  it "is a string a memo can hold, with nothing in it a memo would mangle" do
    handle = described_class.of([ref("tg-general", "101"), ref("dc-general", "202")])

    expect(handle).to be_a(String)
    expect(handle).to match(/\A[A-Za-z0-9_-]+\z/)
  end

  it "answers with nothing for a post that reached no platform" do
    expect(described_class.of([])).to eq("")
  end

  # A handle arrives from a script, so it may have been typed, truncated or
  # kept from a build that wrote a different version. Every caller has to
  # handle "names nothing" anyway.
  it "reads anything it does not recognise as naming nothing" do
    expect(described_class.refs(nil)).to eq([])
    expect(described_class.refs("")).to eq([])
    expect(described_class.refs("not a handle at all")).to eq([])
    expect(described_class.refs("!!!!")).to eq([])
  end

  it "refuses a token written under a different version" do
    other = Base64.urlsafe_encode64("r99\ntg-general\t101", padding: false)

    expect(described_class.refs(other)).to eq([])
  end

  it "will not name more copies than a room could have" do
    many = Array.new(described_class::MAX_REFS + 10) { |i| ref("ep#{i}", i.to_s) }

    expect(described_class.refs(described_class.of(many)).length).to eq(described_class::MAX_REFS)
  end
end
