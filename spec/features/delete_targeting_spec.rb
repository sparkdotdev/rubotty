# frozen_string_literal: true

require "spec_helper"

# Where a platform has no replies, /delete names its target by text or as the issuer's own
# last message, and the moderation feature resolves it from the recent buffer.
RSpec.describe "reply-less /delete targeting" do
  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { fake: ["55"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end

  describe "the parser" do
    let(:tg) { endpoint("tg") }

    def parse(text, author_id: "999")
      commands.parse(message(tg, text: text, native_id: "cmd", author: author(native_id: author_id)),
                     directory: directory)
    end

    it "reads a bare /delete as the issuer's own-last-message mode" do
      command = parse("/delete")
      expect(command.action).to eq(:delete)
      expect(command.targeting).to eq(:own_last)
      expect(command.target_ref).to be_nil
      expect(command.issuer_native_id).to eq("999")
    end

    it "reads /delete <text> as text-match mode, carrying the text" do
      command = parse("/delete spam link")
      expect(command.targeting).to eq(:text)
      expect(command.arguments).to eq(%w[spam link])
    end

    it "resolves the operator issuer when one asks, and nil for a regular member" do
      expect(parse("/delete", author_id: "55").issuer).to eq(operator)
      expect(parse("/delete", author_id: "999").issuer).to be_nil
    end

    it "still refuses a reply-less pin or ban: only /delete has no-reply modes" do
      expect(parse("/pin")).to be_a(Rubotty::Core::Commands::Refusal)
      expect(parse("/ban")).to be_a(Rubotty::Core::Commands::Refusal)
    end
  end

  describe "the feature" do
    let(:tg) { endpoint("tg") }
    let(:adapter) { Fakes::ReactingAdapter.new }
    let(:storage) { Rubotty::Storage::Memory.new }
    let(:feature) do
      Rubotty::Features::Moderation.new(
        topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
        logger: Rubotty::Log.null, commands: commands, cleanup: nil, cleanup_after: 0, acknowledge: false
      )
    end

    def say(text, author_id, native_id)
      feature.call(ctx(message(tg, text: text, native_id: native_id, author: author(native_id: author_id))))
    end

    def run_delete(argument, author_id, native_id: "cmd")
      text = "/delete #{argument}".strip
      feature.call(ctx(message(tg, text: text, native_id: native_id, author: author(native_id: author_id))))
    end

    def ctx(message) = Rubotty::Features::Context.new(message: message, operators: directory)

    def deleted = adapter.deleted

    it "deletes the issuer's own last message on a bare /delete" do
      say("first", "999", "m1")
      say("second", "999", "m2")
      run_delete("", "999")

      expect(deleted).to include(%w[tg m2])
      expect(deleted).not_to include(%w[tg m1])
    end

    it "lets an operator delete anyone's message by its exact text" do
      say("spam link", "999", "m5")
      run_delete("spam link", "55")

      expect(deleted).to include(%w[tg m5])
    end

    it "lets a regular member delete their OWN message by text" do
      say("oops", "999", "m6")
      run_delete("oops", "999")

      expect(deleted).to include(%w[tg m6])
    end

    it "refuses a regular member deleting someone ELSE's message by text" do
      say("spam", "999", "m7")
      run_delete("spam", "888")

      expect(deleted).not_to include(%w[tg m7])
      expect(adapter.moderations).to be_empty
    end

    it "does nothing when the issuer has no last message to delete" do
      run_delete("", "777")
      expect(deleted).to be_empty
    end

    it "does nothing when no recent message matches the text" do
      say("hello", "999", "m8")
      run_delete("not here", "55")
      expect(deleted).to be_empty
    end

    # Asserted against what was moderated, because the invocation is also removed
    # afterwards as cleanup and a bare deletion list cannot tell the two apart.
    it "never targets the /delete command itself, only a real earlier message" do
      say("real message", "55", "m9")
      run_delete("", "55")
      expect(deleted).to include(%w[tg m9])
      expect(adapter.moderations.map { |entry| entry[:native_id] }).to eq(["m9"])
    end

    it "matches the whole text, so a substring of a message is not a target" do
      say("please stop spamming", "999", "m10")
      run_delete("spam", "55")
      expect(deleted).to be_empty
    end
  end
end
