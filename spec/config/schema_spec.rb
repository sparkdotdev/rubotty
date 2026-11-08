# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Config::Schema do
  describe "empty_means_unset" do
    it "materialises the default when an explicit empty array is given" do
      schema = described_class.define do
        field :intervals, :array, of: :integer, default: [1, 2, 3], empty_means_unset: true
      end

      result = schema.call({ intervals: [] })
      expect(result).to be_valid
      expect(result.value[:intervals]).to eq([1, 2, 3])
    end

    it "materialises the default when an explicit empty string is given" do
      schema = described_class.define do
        field :label, :string, default: "fallback", empty_means_unset: true
      end

      result = schema.call({ label: "" })
      expect(result).to be_valid
      expect(result.value[:label]).to eq("fallback")
    end

    it "materialises the default when an explicit empty hash is given" do
      schema = described_class.define do
        field :routes, :hash, default: { a: 1 }, empty_means_unset: true
      end

      result = schema.call({ routes: {} })
      expect(result).to be_valid
      expect(result.value[:routes]).to eq({ a: 1 })
    end

    it "still reports a required field as missing when its value is empty" do
      schema = described_class.define do
        field :intervals, :array, of: :integer, required: true, empty_means_unset: true
      end

      result = schema.call({ intervals: [] })
      expect(result).not_to be_valid
      expect(result.problems).to include("intervals: is required")
    end

    it "leaves an explicit empty value untouched when the marker is off, the existing behaviour" do
      schema = described_class.define do
        field :intervals, :array, of: :integer, default: [1, 2, 3]
      end

      result = schema.call({ intervals: [] })
      expect(result).to be_valid
      expect(result.value[:intervals]).to eq([])
    end

    it "leaves a present, non-empty value untouched even with the marker on" do
      schema = described_class.define do
        field :intervals, :array, of: :integer, default: [1, 2, 3], empty_means_unset: true
      end

      result = schema.call({ intervals: [9] })
      expect(result).to be_valid
      expect(result.value[:intervals]).to eq([9])
    end

    it "still falls back to the default when the key is entirely absent" do
      schema = described_class.define do
        field :intervals, :array, of: :integer, default: [1, 2, 3], empty_means_unset: true
      end

      result = schema.call({})
      expect(result).to be_valid
      expect(result.value[:intervals]).to eq([1, 2, 3])
    end
  end

  # The form offers a scale and the loader has to hold the same one, or the API
  # and the CLI let through what the control would never have offered.
  describe "range" do
    let(:schema) do
      described_class.define { field :minimum_confidence, :float, range: 0.0..1.0, step: 0.05, default: 0.7 }
    end

    it "takes a value inside the range, including either end" do
      expect(schema.call({ minimum_confidence: 0.8 }).problems).to be_empty
      expect(schema.call({ minimum_confidence: 0.0 }).problems).to be_empty
      expect(schema.call({ minimum_confidence: 1.0 }).problems).to be_empty
    end

    it "refuses one below the range and says the scale" do
      problems = schema.call({ minimum_confidence: -0.2 }).problems

      expect(problems.length).to eq(1)
      expect(problems.first).to include("must be between 0.0 and 1.0")
    end

    it "refuses one above it" do
      expect(schema.call({ minimum_confidence: 47 }).problems.first).to include("must be between 0.0 and 1.0")
    end

    it "leaves the default alone, since nobody supplied a value to check" do
      expect(schema.call({}).problems).to be_empty
      expect(schema.call({}).value[:minimum_confidence]).to eq(0.7)
    end

    it "holds a field with no range to nothing extra" do
      unbounded = described_class.define { field :anything, :float }

      expect(unbounded.call({ anything: -99.5 }).problems).to be_empty
    end

    it "keeps the step on the field, for the control that draws it" do
      expect(schema.fields[:minimum_confidence].step).to eq(0.05)
      expect(schema.fields[:minimum_confidence].range).to eq(0.0..1.0)
    end
  end

  describe "boolean defaults" do
    it "materialises a default: false boolean when the key is absent" do
      schema = described_class.define do
        field :flag, :boolean, default: false
      end

      result = schema.call({})
      expect(result).to be_valid
      expect(result.value[:flag]).to eq(false)
    end
  end
end
