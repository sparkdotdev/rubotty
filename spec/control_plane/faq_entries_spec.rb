# frozen_string_literal: true

require "spec_helper"

# A thin composition over FeatureControls, shared by the dashboard's FAQ route
# and the admin API. Removal is addressed by id, never by index.
RSpec.describe Rubotty::ControlPlane::FaqEntries, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  subject(:faq) { described_class.new(feature_controls: controls) }

  def config_for(room_id: nil)
    models.feature_setting.where(community_id: community.id, room_id: room_id, feature: "faq")
          .first&.json_value(:config)
  end

  describe "#list" do
    it "returns an empty array for a scope with no faq row yet" do
      expect(faq.list(community: community, selector: "all")).to eq([])
    end

    it "returns the stored entries for the community scope" do
      faq.add(community: community, selector: "all", trigger: "rules", response: "Be kind.",
              trigger_type: "command")
      expect(faq.list(community: community, selector: "all").length).to eq(1)
    end

    it "returns an empty array when the row's entries key is not an array" do
      controls.set(community: community, selector: "all", feature: "faq", key: "entries", value: "native")
      expect(faq.list(community: community, selector: "all")).to eq([])
    end
  end

  describe "#add" do
    it "stores a command entry with its trigger under the command key" do
      entry = faq.add(community: community, selector: "all", trigger: "rules", response: "Be kind.",
                       trigger_type: "command")
      expect(entry).to include("response" => "Be kind.", "command" => "rules")
      expect(entry).not_to have_key("keyword")
    end

    it "stores a keyword entry with its trigger under the keyword key" do
      entry = faq.add(community: community, selector: "all", trigger: "hours", response: "9 to 5",
                       trigger_type: "keyword")
      expect(entry).to include("response" => "9 to 5", "keyword" => "hours")
      expect(entry).not_to have_key("command")
    end

    it "treats any trigger_type other than command as a keyword" do
      entry = faq.add(community: community, selector: "all", trigger: "hours", response: "9 to 5",
                       trigger_type: nil)
      expect(entry).to have_key("keyword")
    end

    it "stamps the new entry with a fresh, stable id" do
      entry = faq.add(community: community, selector: "all", trigger: "rules", response: "Be kind.",
                       trigger_type: "command")
      expect(entry["id"]).to be_a(String)
      expect(entry["id"]).not_to be_empty
    end

    it "gives two entries different ids" do
      first = faq.add(community: community, selector: "all", trigger: "a", response: "A", trigger_type: "command")
      second = faq.add(community: community, selector: "all", trigger: "b", response: "B", trigger_type: "command")
      expect(first["id"]).not_to eq(second["id"])
    end

    it "appends to whatever is already there rather than replacing it" do
      faq.add(community: community, selector: "all", trigger: "a", response: "A", trigger_type: "command")
      faq.add(community: community, selector: "all", trigger: "b", response: "B", trigger_type: "command")
      expect(faq.list(community: community, selector: "all").length).to eq(2)
    end

    it "raises Invalid naming the requirement when the trigger is blank" do
      expect do
        faq.add(community: community, selector: "all", trigger: "  ", response: "Be kind.", trigger_type: "command")
      end.to raise_error(described_class::Invalid, "An FAQ entry needs both a trigger and a response.")
    end

    it "raises Invalid naming the requirement when the response is blank" do
      expect do
        faq.add(community: community, selector: "all", trigger: "rules", response: nil, trigger_type: "command")
      end.to raise_error(described_class::Invalid, "An FAQ entry needs both a trigger and a response.")
    end

    it "writes nothing when validation fails" do
      expect do
        faq.add(community: community, selector: "all", trigger: nil, response: nil, trigger_type: "command")
      end.to raise_error(described_class::Invalid)
      expect(config_for).to be_nil
    end
  end

  describe "#remove" do
    it "removes the entry whose id matches, leaving the rest" do
      kept = faq.add(community: community, selector: "all", trigger: "a", response: "A", trigger_type: "command")
      removed = faq.add(community: community, selector: "all", trigger: "b", response: "B", trigger_type: "command")

      result = faq.remove(community: community, selector: "all", id: removed["id"])
      expect(result.map { |e| e["id"] }).to eq([kept["id"]])
      expect(faq.list(community: community, selector: "all").map { |e| e["id"] }).to eq([kept["id"]])
    end

    it "accepts a non-string id (a Symbol, matched by to_s)" do
      entry = faq.add(community: community, selector: "all", trigger: "a", response: "A", trigger_type: "command")
      result = faq.remove(community: community, selector: "all", id: entry["id"].to_sym)
      expect(result).to eq([])
    end

    it "raises Invalid, verbatim, when no entry's id matches" do
      faq.add(community: community, selector: "all", trigger: "a", response: "A", trigger_type: "command")
      expect { faq.remove(community: community, selector: "all", id: "not-a-real-id") }
        .to raise_error(described_class::Invalid, "No such FAQ entry to remove.")
    end

    it "raises Invalid for a scope with no entries at all" do
      expect { faq.remove(community: community, selector: "all", id: "anything") }
        .to raise_error(described_class::Invalid, "No such FAQ entry to remove.")
    end

    # An accepted gap: a legacy entry carries no "id", so nothing a caller
    # passes can match it and this method can never remove it.
    it "never matches a legacy entry that has no id key" do
      controls.set(community: community, selector: "all", feature: "faq", key: "entries",
                   value: '[{"response":"Be kind.","command":"rules"}]')
      expect { faq.remove(community: community, selector: "all", id: "deadbeef") }
        .to raise_error(described_class::Invalid, "No such FAQ entry to remove.")
      expect(faq.list(community: community, selector: "all").length).to eq(1)
    end

    it "operates on the scope it is given, not some other room's entries" do
      entry = faq.add(community: community, selector: "general", trigger: "a", response: "A",
                       trigger_type: "command")
      expect { faq.remove(community: community, selector: "all", id: entry["id"]) }
        .to raise_error(described_class::Invalid)
      expect(faq.list(community: community, selector: "general").length).to eq(1)
    end
  end
end
