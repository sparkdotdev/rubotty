# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::Catalog do
  it "lists every real feature by its stable key" do
    expect(described_class.names).to contain_exactly(
      "scripts", "bridge", "moderation", "word_filter", "moderated_room", "content_policy", "mention_spam", "link_filter", "anti_spam", "multipost", "warnings",
      "identity_history", "reports",
      "faq", "semantic_analysis", "topic_routing", "topic_routing_moves",
      "link_annotation", "greetings", "scheduled_announcements", "operator_requests", "utility_commands",
      "keyword_watch", "nickname", "redirection", "identify_topic", "anti_raid", "command_builder", "disabled_command_notice", "translation",
      "room_summaries", "backfill", "startup_banner",
      "operator_startup_dm", "guest_portal", "file_rehosting", "telegram_avatars", "commands", "events", "poll",
      "channel_management"
    )
  end

  it "matches the feature_name each class declares" do
    described_class.classes.each do |klass|
      expect(described_class.names).to include(klass.feature_name)
    end
  end

  it "recognises a known feature and rejects an unknown one" do
    expect(described_class.known?("word_filter")).to be(true)
    expect(described_class.known?(:faq)).to be(true)
    expect(described_class.known?("reactions")).to be(false)
    expect(described_class.known?("")).to be(false)
  end

  # Both run unconditionally (see PIPELINE_ORDER), but a catalog that does not
  # know their names breaks anything that validates a feature name against it,
  # such as ControlPlane::FeatureControls#known! and the dashboard's Features page.
  it "knows identify_topic and disabled_command_notice, the two always-on pipeline steps" do
    expect(described_class.known?("identify_topic")).to be(true)
    expect(described_class.known?("disabled_command_notice")).to be(true)
    expect(described_class.class_for("identify_topic")).to eq(Rubotty::Features::IdentifyTopic)
    expect(described_class.class_for("disabled_command_notice")).to eq(Rubotty::Features::DisabledCommandNotice)
  end

  it "resolves a name back to its class" do
    expect(described_class.class_for("bridge")).to eq(Rubotty::Features::Bridge)
    expect(described_class.class_for("nope")).to be_nil
  end

  it "exposes a feature's config schema when it declares one" do
    expect(described_class.config_schema("bridge")).to be_a(Rubotty::Config::Schema)
    expect(described_class.config_schema("nope")).to be_nil
  end

  describe "#description" do
    it "gives every catalog feature its own real, non-default description" do
      described_class.classes.each do |klass|
        description = described_class.description(klass.feature_name)
        expect(description).to be_a(String)
        expect(description).not_to eq("No description yet.")
        expect(description.length).to be > 10
      end
    end

    it "falls back to the default placeholder for an unknown name" do
      expect(described_class.description("nope")).to eq("No description yet.")
    end

    it "tells an operator that guest_portal's everyone setting lets a member issue a link too" do
      expect(described_class.description("guest_portal")).to include("everyone").and include("member")
    end
  end

  # What a feature keeps, for the operator about to switch it on. Almost every feature reads
  # a message and forgets it, so nil is the answer for nearly all of them.
  describe "#retention_notice" do
    it "describes redirection's kept window in the numbers the retention runs at" do
      notice = described_class.retention_notice("redirection")

      expect(notice).to include("messages for #{Rubotty::ControlPlane::RedirectionWindow::TTL_SECONDS / 86_400} days")
    end

    it "explains that room summaries retain input only until a successful summary" do
      expect(described_class.retention_notice("room_summaries")).to include("successful summary")
    end

    it "explains the pending work semantic analysis keeps" do
      expect(described_class.retention_notice("semantic_analysis")).to include("pending room job")
    end

    it "explains that translation keeps content only in the pending job, not indefinitely" do
      expect(described_class.retention_notice("translation")).to include("pending translation job")
    end

    it "is nil for a feature that keeps nothing, and for a name that is not a feature" do
      expect(described_class.retention_notice("word_filter")).to be_nil
      expect(described_class.retention_notice("nope")).to be_nil
    end
  end
end
