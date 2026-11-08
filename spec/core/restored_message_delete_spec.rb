# frozen_string_literal: true

require "spec_helper"

# A message rubotty restored is the bot's own post carrying somebody else's
# words, so the ordinary ownership test can never say it is theirs. This is the
# one thing that lets that member take it down, and the whole point of these
# examples is that it lets them take down nothing else.
RSpec.describe "deleting a message rubotty restored" do
  let(:tg) { endpoint("tg") }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([]) }

  # Stands in for ControlPlane::ContentPolicyReposts, answering only for the
  # exact triple it was told about.
  class RepostAllowlist
    def initialize(rows = []) = @rows = rows

    def deletable_by?(endpoint_id:, native_id:, author_native_id:)
      @rows.include?([endpoint_id.to_s, native_id.to_s, author_native_id.to_s])
    end
  end

  # The restoration: posted by the bot, speaking for member "u9".
  let(:allowlist) { RepostAllowlist.new([["tg", "restored-1", "u9"]]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS,
                                reposts: allowlist, logger: Rubotty::Log.null)
  end

  # A /delete replying to +parent_id+, written by +author_id+, where the
  # replied-to message was authored by +parent_author+ (the bot, by default).
  def parse(author_id:, parent_id: "restored-1", parent_author: "bot-1", commands: self.commands)
    reply = Rubotty::Core::ReplyPreview.new(
      author: author(native_id: parent_author, username: "rubotty"),
      body: Rubotty::Core::RichText.plain("Ada wrote: something")
    )
    msg = message(tg, text: "/delete", native_id: "cmd", author: author(native_id: author_id),
                  reply_to: Rubotty::Core::MessageRef.new("tg", parent_id), reply_preview: reply)
    commands.parse(msg, directory: directory)
  end

  it "lets the member it speaks for take their restored message down" do
    command = parse(author_id: "u9")

    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.action).to eq(:delete)
    # No operator: the authority is the allowlist, not a grant.
    expect(command.issuer).to be_nil
  end

  it "refuses anybody else, even replying to that same restored message" do
    expect(parse(author_id: "someone-else")).to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "refuses the right member replying to a message that is not a restoration" do
    expect(parse(author_id: "u9", parent_id: "some-other-message"))
      .to be_a(Rubotty::Core::Commands::Refusal)
  end

  # A native id means nothing outside the endpoint it was minted on, so the
  # same id in another room must not carry the grant with it.
  it "refuses the same message id on a different endpoint" do
    other = Rubotty::Core::Commands.new(
      actions: Rubotty::Core::Moderation::ACTIONS,
      reposts: RepostAllowlist.new([["other-endpoint", "restored-1", "u9"]]),
      logger: Rubotty::Log.null
    )

    expect(parse(author_id: "u9", commands: other)).to be_a(Rubotty::Core::Commands::Refusal)
  end

  # The grant is for one verb. Anything else from a non-operator is refused
  # exactly as it was before this existed.
  it "grants delete and nothing else" do
    %w[ban kick mute pin unpin].each do |verb|
      msg = message(tg, text: "/#{verb}", native_id: "cmd", author: author(native_id: "u9"),
                    reply_to: Rubotty::Core::MessageRef.new("tg", "restored-1"))
      expect(commands.parse(msg, directory: directory))
        .to be_a(Rubotty::Core::Commands::Refusal), "#{verb} was not refused"
    end
  end

  it "grants nothing at all without a store, which is how it degrades" do
    bare = Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS,
                                       logger: Rubotty::Log.null)

    expect(parse(author_id: "u9", commands: bare)).to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "grants nothing when the store cannot answer, rather than failing open" do
    broken = Class.new do
      def deletable_by?(**) = raise("store is down")
    end.new
    guarded = Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS,
                                          reposts: broken, logger: Rubotty::Log.null)

    expect(parse(author_id: "u9", commands: guarded)).to be_a(Rubotty::Core::Commands::Refusal)
  end

  # The behaviour that already existed has to keep working untouched.
  it "still lets anybody delete their own message" do
    command = parse(author_id: "u9", parent_id: "their-own", parent_author: "u9")

    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.action).to eq(:delete)
  end
end
