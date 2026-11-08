# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::ThreadRef do
  it "stringifies the native id at the boundary, like every other native id" do
    expect(described_class.new(native_id: 142_483).native_id).to eq("142483")
  end

  it "carries a name when the source platform gives one" do
    ref = described_class.new(native_id: "9", name: "release chat")
    expect(ref).to be_named
    expect(ref.name).to eq("release chat")
    expect(ref.to_s).to eq("release chat")
  end

  it "is unnamed when no name is known, falling back to the id for display" do
    ref = described_class.new(native_id: "9")
    expect(ref).not_to be_named
    expect(ref.name).to be_nil
    expect(ref.to_s).to eq("9")
  end

  it "treats an empty name as no name" do
    expect(described_class.new(native_id: "9", name: "")).not_to be_named
  end

  it "carries the handle of whoever started the thread, where the platform says" do
    ref = described_class.new(native_id: "9", name: "bar", creator: "owner_handle")
    expect(ref).to be_created_by
    expect(ref.creator).to eq("owner_handle")
  end

  it "carries the starter's stable identity when an adapter provides it" do
    ref = described_class.new(native_id: "9", creator_native_id: "4242")

    expect(ref.creator_native_id).to eq("4242")
  end

  it "knows no starter on a platform that never says, and treats an empty one the same" do
    expect(described_class.new(native_id: "9")).not_to be_created_by
    expect(described_class.new(native_id: "9", creator: "")).not_to be_created_by
  end

  it "compares by id, name and both starter identifiers" do
    a = described_class.new(native_id: "9", name: "bar")
    expect(a).to eq(described_class.new(native_id: "9", name: "bar"))
    expect(a).not_to eq(described_class.new(native_id: "9", name: "baz"))
    expect(a).not_to eq(described_class.new(native_id: "8", name: "bar"))
    expect(a).not_to eq(described_class.new(native_id: "9", name: "bar", creator: "ada"))
    expect(a).not_to eq(described_class.new(native_id: "9", name: "bar", creator_native_id: "4242"))
  end
end
