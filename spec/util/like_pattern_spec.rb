# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe Rubotty::Util::LikePattern do
  describe ".escape" do
    it "makes a percent literal" do
      expect(described_class.escape("50%")).to eq("50!%")
    end

    it "makes an underscore literal" do
      expect(described_class.escape("a_c")).to eq("a!_c")
    end

    it "makes the escape character itself literal" do
      expect(described_class.escape("wow!")).to eq("wow!!")
    end

    it "leaves an ordinary value alone" do
      expect(described_class.escape("alex")).to eq("alex")
    end

    it "leaves a backslash alone, since it is not the escape character here" do
      expect(described_class.escape("a\\c")).to eq("a\\c")
    end
  end

  it "wraps a contains pattern around the escaped value" do
    expect(described_class.contains("a_c")).to eq("%a!_c%")
  end

  it "anchors a starts_with pattern at the front" do
    expect(described_class.starts_with("a%")).to eq("a!%%")
  end

  # The escaping only means anything if the SQL says which character escapes,
  # so this proves the round trip rather than the string building.
  describe "against a real database" do
    let(:db) do
      Sequel.sqlite.tap do |handle|
        handle.create_table(:names) { String :value }
        handle[:names].multi_insert(
          [{ value: "abc" }, { value: "a_c" }, { value: "a%c" }, { value: "a!c" }, { value: "AXC" }]
        )
      end
    end

    def matching(needle, column: :value)
      db[:names].where(described_class.like(column, described_class.contains(needle))).select_map(:value)
    end

    it "matches an underscore literally instead of any character" do
      expect(matching("a_c")).to eq(["a_c"])
    end

    it "matches a percent literally instead of any run" do
      expect(matching("a%c")).to eq(["a%c"])
    end

    it "matches the escape character literally" do
      expect(matching("a!c")).to eq(["a!c"])
    end

    it "still does an ordinary substring match" do
      expect(matching("b")).to eq(["abc"])
    end

    it "returns nothing for a bare wildcard rather than everything" do
      expect(matching("%")).to eq(["a%c"])
    end

    it "folds case on every backend through like_lower" do
      pattern = described_class.contains("axc")
      values = db[:names].where(described_class.like_lower(:value, pattern)).select_map(:value)

      expect(values).to eq(["AXC"])
    end
  end
end
