# frozen_string_literal: true

require "spec_helper"

# The deployment this was found on has four operators, all on the deployment-configured
# floor with no explicit operator row. Every check here uses that shape: an
# explicit row passes whether or not the username is threaded and proves
# nothing, since the floor matches on USERNAME and the explicit list on native id.
RSpec.describe "an operator who exists only on the deployment-configured floor" do
  include Builders

  # No explicit operators whatsoever, which is what production looked like.
  let(:directory) { Rubotty::Core::Moderation::Directory.new([]) }

  # A handle from Security::ProtectedOperators::FALLBACK, so the floor is the only thing
  # that can recognise this person.
  let(:owner) { author(native_id: "77", username: "sample_owner") }

  # Same platform id, a handle the floor does not carry.
  let(:bystander) { author(native_id: "78", username: "sam") }

  # Telegram, because Security::HandleFloor only honours a bare username on a platform
  # that issues one uniquely, and the reported deployment is a Telegram community.
  let(:origin) { endpoint("chan", adapter: :telegram) }

  def context_for(person)
    Rubotty::Features::Context.new(
      message: message(origin, text: "/whatever", author: person),
      community: nil, config: {}, logger: Rubotty::Log.null, operators: directory
    )
  end

  it "is invisible to the directory without the username, which is the whole bug" do
    expect(directory.resolve(:telegram, owner.native_id)).to be_nil
    expect(directory.resolve(:telegram, owner.native_id, username: owner.username)).not_to be_nil
  end

  it "counts as empty, since only the explicit operators are counted" do
    expect(directory).to be_empty
  end

  # Each surface's own operator predicate, reached through allocate so the check is of the
  # predicate itself rather than of whatever wiring a feature happens to need. The value on
  # the right is what the predicate says for somebody who IS an operator.
  {
    Rubotty::Features::IdentifyTopic => [:moderator?, true],
    Rubotty::Features::UtilityCommands => [:moderator?, true],
    Rubotty::Features::Nickname => [:operator?, true],
    Rubotty::Features::EventRemindCommand => [:operator?, true],
    Rubotty::Features::EventCommand => [:role_of, :operator],
    Rubotty::Features::GuestCommand => [:role_of, :operator]
  }.each do |feature, (predicate, recognised)|
    describe "#{feature}##{predicate}" do
      let(:subject_feature) { feature.allocate }

      it "recognises the floor operator" do
        expect(subject_feature.send(predicate, context_for(owner))).to eq(recognised)
      end

      it "still says no to somebody the floor does not carry" do
        expect(subject_feature.send(predicate, context_for(bystander))).not_to eq(recognised)
      end
    end
  end

  # A module rather than a feature class, so it needs a host to be reached at all.
  describe "Features::CardCancellation#operator?" do
    let(:host) { Class.new { include Rubotty::Features::CardCancellation }.new }

    it "recognises the floor operator and refuses a bystander" do
      expect(host.send(:operator?, context_for(owner))).to be(true)
      expect(host.send(:operator?, context_for(bystander))).to be(false)
    end
  end

  # These take the message separately rather than reading it off the context.
  describe "Features::Scripts#operator?" do
    it "recognises the floor operator and refuses a bystander" do
      feature = Rubotty::Features::Scripts.allocate
      expect(feature.send(:operator?, context_for(owner), context_for(owner).message)).to be(true)
      expect(feature.send(:operator?, context_for(bystander), context_for(bystander).message)).to be(false)
    end
  end

  describe "Core::Router#script_author_is_operator?" do
    it "recognises the floor operator and refuses a bystander" do
      router = Rubotty::Core::Router.allocate
      expect(router.send(:script_author_is_operator?, context_for(owner), context_for(owner).message)).to be(true)
      expect(
        router.send(:script_author_is_operator?, context_for(bystander), context_for(bystander).message)
      ).to be(false)
    end
  end

  # The filters exempt operators, and they used to short-circuit on Directory#empty?, which
  # is true here however many people the floor carries.
  {
    Rubotty::Features::WordFilter => :exempt?,
    Rubotty::Features::LinkFilter => :exempt?,
    Rubotty::Features::AntiSpam => :exempt?,
    Rubotty::Features::MentionSpam => :exempt?,
    Rubotty::Features::Multipost => :exempt?
  }.each do |feature, predicate|
    describe "#{feature}##{predicate}" do
      it "exempts the floor operator and does not exempt a bystander" do
        instance = feature.allocate
        expect(instance.send(predicate, context_for(owner))).to be(true)
        expect(instance.send(predicate, context_for(bystander))).to be(false)
      end
    end
  end

  describe "Core::Commands#parse" do
    let(:commands) { Rubotty::Core::Commands.new(logger: Rubotty::Log.null) }

    def parse_delete(person)
      commands.parse(
        message(origin, text: "/delete", author: person, reply_to: ref(origin.id, "5")),
        directory: directory
      )
    end

    it "issues the command under the floor operator's own authority" do
      command = parse_delete(owner)
      expect(command).to be_a(Rubotty::Core::Moderation::Command)
      expect(command.issuer).not_to be_nil
    end

    it "refuses a bystander outright" do
      refusal = parse_delete(bystander)
      expect(refusal).to be_a(Rubotty::Core::Commands::Refusal)
      expect(refusal.reason).to eq(:not_permitted)
    end
  end
end
