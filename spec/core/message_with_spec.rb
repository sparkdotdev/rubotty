# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Message do
  include Builders

  let(:origin) { endpoint("tg-general") }

  # Every attribute set to something distinguishable from its default, so a
  # keyword #with forgets to pass shows up as a reset rather than a coincidence.
  let(:full) do
    described_class.new(
      kind: :edit,
      ref: Rubotty::Core::MessageRef.new("tg-general", "77"),
      origin: origin,
      author: author,
      body: Rubotty::Core::RichText.plain("hello"),
      attachments: [Rubotty::Core::Attachment.new(kind: :file, url: "https://example.test/a")],
      reply_to: Rubotty::Core::MessageRef.new("tg-general", "12"),
      forwarded_from: author(native_id: "u2"),
      timestamp: Time.utc(2026, 1, 1),
      trace: %w[tg-general],
      raw: { "native" => true },
      correlation_id: "abc123",
      sender_label: "Ada",
      reply_preview: Rubotty::Core::ReplyPreview.new(label: "Ada"),
      reaction: Rubotty::Core::Reaction.new(emoji: "👍"),
      reaction_set: [Rubotty::Core::Reaction.new(emoji: "🤣")],
      thread: Rubotty::Core::ThreadRef.new(native_id: "t1", name: "planning"),
      thread_notice: "replied inside thread planning",
      hub_target_room_id: "gs",
      hub_exclude_endpoint_ids: %w[irc-hub],
      synthetic: true
    )
  end

  describe "#with" do
    # A dropped keyword resets that attribute to its default without a word, so
    # the guard is over every reader rather than over the one that broke.
    it "carries every attribute across a copy that changes nothing" do
      copy = full.with

      described_class.instance_methods(false).grep(/\A[a-z_]+\z/).each do |reader|
        next unless described_class.public_method_defined?(reader)
        next unless full.respond_to?(reader) && described_class.instance_method(reader).arity.zero?
        next if %i[with visited inspect].include?(reader)

        expect(copy.public_send(reader)).to eq(full.public_send(reader)), "#with dropped ##{reader}"
      end
    end

    # Bridge and CommandAck both branch on this, so losing it relays a Discord
    # slash-command interaction as ordinary chat.
    it "keeps synthetic set" do
      expect(full.with(trace: %w[a b])).to be_synthetic
    end

    it "keeps synthetic clear" do
      expect(full.with(synthetic: false).visited("x")).not_to be_synthetic
    end

    it "still lets a caller change synthetic" do
      expect(full.with(synthetic: false)).not_to be_synthetic
    end
  end
end
