# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::ContentPolicy do
  include Builders

  class ContentPolicyFeatureService
    attr_reader :contexts

    def initialize = @contexts = []

    def enqueue(context) = @contexts << context
  end

  # Records what the feature handed the service's condemn seam, and answers with
  # the outcome a configured policy would produce.
  class CondemnService < ContentPolicyFeatureService
    attr_reader :condemned

    def initialize(outcome: nil)
      super()
      @condemned = []
      @outcome = outcome ||
                 Rubotty::ContentPolicy::Service::Outcome.new(status: :done, code: "cp-7", policy: "spam links")
    end

    def condemn(**asked)
      @condemned << asked
      @outcome
    end
  end

  # Stands in for Core::Moderation::Directory, which the feature only ever asks
  # to resolve the one identity that typed the command.
  class CondemnOperators
    def initialize(operator_id) = @operator_id = operator_id

    def resolve(_adapter, native_id, username: nil)
      native_id == @operator_id ? "operator #{username}" : nil
    end
  end

  let(:endpoint) { Rubotty::Core::Endpoint.new(id: "telegram-general", adapter_name: :telegram, account: "default") }
  let(:service) { ContentPolicyFeatureService.new }
  let(:feature) { described_class.new(logger: Rubotty::Log.null, service: service) }

  # A real Context, not a bare Struct holding the message: the feature reads a
  # command word off the front of every message now, and that goes through
  # Context#command_prefixes.
  let(:context) do
    Rubotty::Features::Context.new(message: message(endpoint, text: "join our whatsapp group"))
  end

  it "continues the pipeline after scheduling its separate background check" do
    expect(feature.call(context)).to be_continue

    expect(service.contexts).to eq([context])
  end

  it "is inert without its durable service" do
    expect(described_class.new(logger: Rubotty::Log.null).call(context)).to be_continue
  end

  it "is a distinct feature from semantic FAQ matching" do
    expect(described_class.feature_name).to eq("content_policy")
    expect(described_class.feature_name).not_to eq(Rubotty::Features::SemanticAnalysis.feature_name)
  end

  it "is off by default, since a classifier decision can remove messages" do
    expect(described_class.default_enabled?).to be(false)
  end

  describe "the entries field's default" do
    let(:schema) { described_class.config_schema }

    it "resolves an unset config to no entries at all, enforcing nothing until an operator adds one" do
      resolved = schema.call({})

      expect(resolved.valid?).to be(true)
      expect(resolved.value[:entries]).to eq([])
    end

    it "does not override a community's own entries, even a deliberately empty list" do
      resolved = schema.call({ "entries" => [] })

      expect(resolved.valid?).to be(true)
      expect(resolved.value[:entries]).to eq([])
    end

    it "does not override a community's own configured entries" do
      resolved = schema.call({ "entries" => [{ "name" => "spam links", "description" => "posts a link to another server", "action" => "delete" }] })

      expect(resolved.valid?).to be(true)
      expect(resolved.value[:entries])
        .to eq([{ name: "spam links", description: "posts a link to another server", action: "delete",
                  mode: "forbids" }])
    end
  end

  # Every entry configured before the field existed reads as forbidding, which
  # is what the check has always done, so turning this on changes nothing until
  # somebody sets an entry to requires.
  it "fills in a forbidding mode for an entry that names none" do
    resolved = described_class.config_schema.call(
      { "entries" => [{ "name" => "spam", "description" => "posts an invite", "action" => "notify" }] }
    )

    expect(resolved.valid?).to be(true)
    expect(resolved.value[:entries].first[:mode]).to eq(Rubotty::ContentPolicy::Service::MODE_FORBIDS)
  end

  it "keeps a requiring mode an operator did set" do
    resolved = described_class.config_schema.call(
      { "entries" => [{ "name" => "kansas", "description" => "must mention Kansas",
                        "action" => "notify", "mode" => "requires" }] }
    )

    expect(resolved.valid?).to be(true)
    expect(resolved.value[:entries].first[:mode]).to eq(Rubotty::ContentPolicy::Service::MODE_REQUIRES)
  end

  it "refuses a mode that is neither" do
    resolved = described_class.config_schema.call(
      { "entries" => [{ "name" => "kansas", "description" => "d", "action" => "notify", "mode" => "sideways" }] }
    )

    expect(resolved.valid?).to be(false)
  end

  describe "the restore window" do
    let(:schema) { described_class.config_schema }
    let(:field) { ::Rubotty::ContentPolicy::Service::WINDOW_FIELD }

    it "defaults to the ceiling, so a community that names nothing still has a month to disagree" do
      resolved = schema.call({})

      expect(resolved.valid?).to be(true)
      expect(resolved.value[field.to_sym])
        .to eq(Rubotty::ControlPlane::ContentPolicyActions::MAX_WINDOW_DAYS)
    end

    # A snapshot symbolizes every config key before a reader sees it, so a
    # constant held as a string named nothing and the prune silently kept the
    # ceiling however short a community set its window.
    it "is a symbol, which is what the config it is looked up in is keyed by" do
      expect(field).to be_a(Symbol)
      expect(described_class::MISFIRE_WINDOW_FIELD).to be_a(Symbol)
    end

    it "refuses a window of zero or less rather than storing a number that keeps nothing" do
      expect(schema.call({ field => 0 }).valid?).to be(false)
      expect(schema.call({ field => -3 }).valid?).to be(false)
    end

    # The schema takes the number; the ceiling is enforced on every read, so a
    # row written before the ceiling existed is pulled down rather than honoured.
    it "is held to the ceiling where it is read, whatever a community stored" do
      expect(Rubotty::ControlPlane::ContentPolicyActions.window_days(365))
        .to eq(Rubotty::ControlPlane::ContentPolicyActions::MAX_WINDOW_DAYS)
      expect(Rubotty::ControlPlane::ContentPolicyActions.window_days(7)).to eq(7)
    end
  end

  # The operator's verb for a miss, in reply to the message the policies should
  # have caught. Room-side only: the service's half is covered in
  # spec/content_policy/service_spec.rb.
  describe "/condemn" do
    let(:adapter) { Fakes::ReactingAdapter.new }
    let(:adapters) { Hash.new(adapter) }
    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null) }
    let(:ephemeral) do
      Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", endpoint)),
        logger: Rubotty::Log.null
      )
    end
    let(:directory) { CondemnOperators.new("u1") }
    let(:community) do
      instance_double(Rubotty::ControlPlane::Snapshot::Community,
                      id: 7, name: "C", feature_config: {}, operators: directory)
    end
    let(:condemning) { CondemnService.new }
    let(:feature) do
      described_class.new(logger: Rubotty::Log.null, service: condemning,
                          ephemeral: ephemeral, cleanup: scheduler, adapters: adapters)
    end

    def preview
      Rubotty::Core::ReplyPreview.new(
        author: author(native_id: "777", username: "bo"), body: "Hitler was good",
        ref: Rubotty::Core::MessageRef.new("telegram-general", "900")
      )
    end

    def condemn(text: "/condemn", native_id: "u1", reply: preview)
      typed = message(endpoint, text: text, native_id: "1000",
                                author: author(native_id: native_id, username: "ada"),
                                reply_to: reply&.ref, reply_preview: reply)
      feature.call(Rubotty::Features::Context.new(message: typed, community: community))
    end

    def posted = adapter.delivered_to("telegram-general").map { |sent| sent.body.text }

    it "never relays the invocation onward, whatever it does with it" do
      expect(condemn).to be_halt
    end

    it "runs the policy's own action on the replied-to message" do
      condemn

      expect(condemning.condemned.length).to eq(1)
      asked = condemning.condemned.first
      expect(asked[:message].ref.native_id).to eq("900")
      expect(asked[:message].body.text).to eq("Hitler was good")
      expect(asked[:message].author.username).to eq("bo")
    end

    it "hands back the code /vindicate reverses it by" do
      condemn

      expect(posted.first).to include("spam links")
      expect(posted.first).to include("/vindicate cp-7")
    end

    # A miss is named by pointing at it, and there is nothing else to point with:
    # unlike /vindicate there is no code to type, because nothing ever fired.
    it "asks for a reply rather than guessing which message was meant" do
      condemn(reply: nil)

      expect(condemning.condemned).to be_empty
      expect(posted.first).to include("only works as a reply")
    end

    it "is an operator's verb, and says so to anybody else" do
      condemn(native_id: "u9")

      expect(condemning.condemned).to be_empty
      expect(posted.first).to include("operator standing")
    end

    it "reads a quoted policy name, so one with a space in it is not read as a reason" do
      condemn(text: %(/condemn "spam links" the check let this through))

      asked = condemning.condemned.first
      expect(asked[:policy]).to eq("spam links")
      expect(asked[:statement]).to eq("the check let this through")
    end

    # A community running one policy should not have to type its name, so an
    # unquoted rest is all reason and the service picks the policy.
    it "takes an unquoted rest as the reason alone" do
      condemn(text: "/condemn the check let this through")

      asked = condemning.condemned.first
      expect(asked[:policy]).to be_nil
      expect(asked[:statement]).to eq("the check let this through")
    end

    # An operator condemning a message is saying it broke a policy, and that is
    # what a strike records, so the flag has to be asked for to be turned off.
    it "asks for the strike unless the operator says otherwise" do
      condemn(text: "/condemn the check let this through")

      expect(condemning.condemned.first[:warn]).to be(true)
    end

    it "takes warn=false off the end, and does not leave it in the reason" do
      condemn(text: "/condemn the check let this through warn=false")

      asked = condemning.condemned.first
      expect(asked[:warn]).to be(false)
      expect(asked[:statement]).to eq("the check let this through")
    end

    it "reads no, and reads it with a quoted policy in front of it" do
      condemn(text: %(/condemn "spam links" missed this warn=no))

      asked = condemning.condemned.first
      expect(asked[:warn]).to be(false)
      expect(asked[:policy]).to eq("spam links")
      expect(asked[:statement]).to eq("missed this")
    end

    # Only the last word is tested, so a reason that happens to say it is a
    # reason rather than a flag.
    it "leaves the phrase alone anywhere but the end of the reason" do
      condemn(text: "/condemn warn=false is what I meant to type")

      asked = condemning.condemned.first
      expect(asked[:warn]).to be(true)
      expect(asked[:statement]).to eq("warn=false is what I meant to type")
    end

    it "never queues a background check for the command itself" do
      condemn

      expect(condemning.contexts).to be_empty
    end

    # It names the operator condemning a member's message, which is the
    # reprisal a thirty second acknowledgement window hands to that member.
    it "removes the invocation at once rather than on the acknowledgement window" do
      condemn

      expect(adapter.deleted).to include(%w[telegram-general 1000])
    end

    it "removes a refused invocation too, since a refusal names its operator" do
      condemn(native_id: "u9")

      expect(adapter.deleted).to include(%w[telegram-general 1000])
    end

    # It is gone by the time the answer is posted, so pairing the same ref
    # would leave the reaper retrying a delete against nothing.
    it "does not also pair the invocation with its acknowledgement" do
      condemn
      before = adapter.deleted.count(%w[telegram-general 1000])
      scheduler.run_due if scheduler.respond_to?(:run_due)

      expect(adapter.deleted.count(%w[telegram-general 1000])).to eq(before)
    end
  end

  # The notice used to promise message text lived only in the pending job,
  # which stopped being true once a removed message had to survive to be
  # restored.
  it "says a removed message is kept for the restore window, since it now is" do
    expect(described_class.retention_notice).to include("pending policy-check job")
    expect(described_class.retention_notice).to include("restore window")
  end
end
