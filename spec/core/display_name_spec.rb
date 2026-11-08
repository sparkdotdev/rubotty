# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::DisplayName do
  def render(template, fallback: nil, **author_fields)
    described_class.new(template: template, fallback: fallback)
                   .render(Rubotty::Core::Author.new(**author_fields))
  end

  it "expands the fields a sender has" do
    expect(render("{first_name} ({username})", first_name: "Ada", username: "ada")).to eq("Ada (ada)")
  end

  # Coercing a missing Telegram username to "" before the template is applied
  # renders a user without one as "Ada ()", and a channel forward has no username
  # either.
  describe "when a template references a field the sender does not have" do
    it "does not emit empty parentheses" do
      result = render("{first_name} ({username})", fallback: "{first_name}", first_name: "Ada")
      expect(result).to eq("Ada")
      expect(result).not_to include("()")
    end

    it "treats an empty string the same as a missing field" do
      result = render("{first_name} ({username})", fallback: "{first_name}", first_name: "Ada", username: "")
      expect(result).to eq("Ada")
    end

    it "treats a whitespace only string the same as a missing field" do
      result = render("{first_name} ({username})", fallback: "{first_name}", first_name: "Ada", username: "   ")
      expect(result).to eq("Ada")
    end

    it "applies to channel forwards, which have no username at all" do
      result = render("{first_name} ({username})", fallback: "{display_name}", display_name: "Announcements")
      expect(result).to eq("Announcements")
    end
  end

  it "falls back again when the fallback is also unsatisfiable" do
    expect(render("{username}", fallback: "{first_name}", display_name: "Somebody")).to eq("Somebody")
  end

  it "never returns an empty string" do
    expect(render("{username}", fallback: "{first_name}", native_id: "999")).to eq("999")
  end

  it "supports a composed full_name field" do
    expect(render("{full_name}", first_name: "Ada", last_name: "Lovelace")).to eq("Ada Lovelace")
  end

  it "uses first_name alone when there is no last name" do
    expect(render("{full_name}", first_name: "Ada")).to eq("Ada")
  end

  describe ".unknown_fields_in" do
    it "detects typos so config validation can report them" do
      expect(described_class.unknown_fields_in("{frist_name}")).to eq([:frist_name])
      expect(described_class.unknown_fields_in("{first_name} ({username})")).to be_empty
    end
  end

  describe ".resolve" do
    let(:default) { described_class.new(template: "{username}", fallback: "{first_name}") }

    it "prefers the endpoint template over the room and global ones" do
      naming = described_class.resolve(
        endpoint: endpoint("e", display_name_template: "endpoint {first_name}"),
        room: room("r", display_name_template: "room {first_name}"),
        default: default
      )
      expect(naming.template).to eq("endpoint {first_name}")
    end

    it "prefers the room template over the global one" do
      naming = described_class.resolve(
        endpoint: endpoint("e"),
        room: room("r", display_name_template: "room {first_name}"),
        default: default
      )
      expect(naming.template).to eq("room {first_name}")
    end

    it "falls back to the global template" do
      naming = described_class.resolve(endpoint: endpoint("e"), room: room("r"), default: default)
      expect(naming.template).to eq("{username}")
    end

    it "inherits the broader fallback when only the template is overridden" do
      naming = described_class.resolve(
        endpoint: endpoint("e", display_name_template: "{nickname}"),
        room: nil,
        default: default
      )
      expect(naming.fallback).to eq("{first_name}")
    end
  end
end
