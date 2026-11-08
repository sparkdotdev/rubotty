# frozen_string_literal: true

require "spec_helper"

RSpec.describe "privacy retention and storage boundaries" do
  it "keeps the guest grace ceiling at one hour" do
    expect(Rubotty::ControlPlane::GuestRetention::MAX_GRACE).to eq(3600)
  end

  it "keeps the content-policy undo window at thirty days" do
    expect(Rubotty::ControlPlane::ContentPolicyActions::MAX_WINDOW_DAYS).to eq(30)
  end

  it "keeps the misfire window at ninety days" do
    expect(Rubotty::ControlPlane::ContentPolicyMisfires::MAX_WINDOW_DAYS).to eq(90)
  end

  it "keeps the topic-proposal window at 183 days" do
    expect(Rubotty::ControlPlane::TopicMoveProposals::MAX_WINDOW_DAYS).to eq(183)
  end

  it "does not expose an unenforced webhook row cap" do
    expect(Rubotty::ControlPlane::Webhooks.constants).not_to include(:COMMUNITY_LIMIT)
  end
end

# The private disclosure is optional only when its entry is absent. lstat keeps
# unreadable files, directories and dangling links on the failing read path.
privacy_document_path = File.expand_path("../PRIVACY.md", __dir__)
privacy_document_present = begin
  File.lstat(privacy_document_path)
  true
rescue Errno::ENOENT
  false
end

# PRIVACY.md makes numeric promises about how long guest content is kept. The
# passage about the grace ceiling was stale for a release because nothing tied
# it to the constant it describes, so these read the numbers off the code.
RSpec.describe "PRIVACY.md" do
  let(:text) { File.read(privacy_document_path, encoding: "UTF-8") }

  it "states the guest grace ceiling that GuestRetention actually enforces" do
    expect(text).to include("MAX_GRACE = #{Rubotty::ControlPlane::GuestRetention::MAX_GRACE}")
  end

  it "still describes that ceiling as one hour, which is what the constant is" do
    expect(text).to include("hard ceiling of one hour")
  end

  it "no longer describes the ceiling as living on an unmerged branch" do
    expect(text).not_to include("unmerged")
    expect(text).not_to include("fix/guest-content-60min-cap")
  end

  it "states the guest send wait ceiling that GuestFeed actually enforces" do
    expect(text).to include(
      "`GuestFeed::MAX_WAIT_SECONDS`, currently **#{Rubotty::ControlPlane::GuestFeed::MAX_WAIT_SECONDS}**"
    )
  end

  it "says the timed reclamation needs the bot process" do
    expect(text).to include("Core::Runtime")
    expect(text).to match(/webui/)
  end

  it "describes the room-summary transcript and its successful-post boundary" do
    expect(text).to include("room_summary_messages")
    expect(text).to include("RoomSummaries::Archive#complete")
    expect(text).to include("Message text is kept for this room until")
    expect(text).to include("its next successful summary, then removed.")
  end

  it "describes the semantic job and its terminal payload clearing" do
    expect(text).to include("semantic_analysis")
    expect(text).to include("DurableScheduler")
    expect(text).to include("Question text is kept only in its pending room job")
    expect(text).to include("while a matching reply is prepared.")
  end

  it "describes translation's job payload and its terminal clearing (#1490)" do
    expect(text).to include("translation")
    expect(text).to include("DurableScheduler")
    expect(text).to include(
      "Message text, formatting, and attachments are kept only in this pending job"
    )
    expect(text).to include("then discarded.")
  end

  it "discloses the LibreTranslate connection alongside the other outbound calls (#1490)" do
    expect(text).to include("Translation::Settings")
    expect(text).to include("LibreTranslate URL")
  end

  # This is the one table that keeps the text of a message already removed
  # everywhere else, so the window it lapses on is worth reading off the code.
  it "describes the restore window that ContentPolicyActions actually caps at" do
    expect(text).to include("content_policy_actions")
    expect(text).to include("ContentPolicyActions::MAX_WINDOW_DAYS")
    expect(text).to include("caps it\nat **30 days**")
  end

  # The body used to be kept only for the two removing actions, which left a
  # flag with nothing for the misfire log to learn from.
  it "says the judged text is kept whatever the action was, and why" do
    section = text[/### A content policy action an operator can still undo.*?(?=\n### )/m]

    expect(section).to include("Every action stores the judged `body`")
    expect(section).to include("reasoning")
    expect(section).to include("PRUNE_KIND")
  end

  # The one table that keeps text past the record it came from, so both its
  # ceiling and its deliberate omission are worth pinning to the code.
  it "describes the misfire log's ceiling and its missing author" do
    section = text[/### The policies that got it wrong.*?(?=\n### )/m]

    expect(section).to include("content_policy_misfires")
    expect(section).to include("ContentPolicyMisfires::MAX_WINDOW_DAYS")
    expect(section).to include("at **90 days**")
    expect(section).to include("records no author")
  end

  # The gap that let a filter delete for a month with nobody told. Both the
  # excerpt cap and the deliberate silence of the rate guards are read off the
  # code rather than typed.
  it "describes the removal alert, its excerpt cap and which filters stay quiet" do
    section = text[/### An automated removal told to the operators.*?(?=\n### )/m]

    expect(section).to include("RemovalNotice::QUOTE_CHARS")
    expect(section).to include("**#{Rubotty::Core::RemovalNotice::QUOTE_CHARS}**")
    expect(section).to include("anti_spam")
    expect(section).to include("multipost")
    expect(section).to include("notify_operators")
  end

  # The longest window in the schema, and the only one measured from the
  # message rather than the row, so both facts are read off the code.
  it "describes the training window and what it is measured from" do
    section = text[/### Moves an operator was asked to confirm.*?(?=\n### )/m]

    expect(section).to include("topic_move_proposals")
    expect(section).to include("MAX_WINDOW_DAYS")
    expect(section).to include("**183 days**")
    expect(section).to include("measured from the message's own date")
  end

  it "does not claim webhook_deliveries has a row cap it does not enforce" do
    section = text[/### Where the envelope is stored.*?(?=\n### )/m]
    expect(section).not_to include("COMMUNITY_LIMIT")
    expect(section).to include("no row cap")
  end

  it "documents polls as a durable, voter-identity-linked exception" do
    expect(text).to include("poll_votes")
    expect(text).to include("poll_options")
    expect(text).to include("so a vote durably links a")
    expect(text).to include("voter's platform handle to their specific answer")
    expect(text).not_to include("is the one exception worth flagging")
  end

  it "counts twelve places a message body reaches a disk, including both API queues" do
    expect(text).to include("twelve places a message body reaches a disk anyway")
    expect(text).to include("api_wrapper_pending_events")
    expect(text).to include("api_pending_message_actions")
  end

  # The move half writes a repostable copy the classifying half never does, and
  # that difference between the two toggles is the whole disclosure.
  it "separates what each of the two topic routing toggles keeps" do
    expect(text).to include("### A topic routing check waiting to run")
    expect(text).to include("SemanticAnalysis::TopicRouter#run")
    expect(text).to include("A room running\n`topic_routing` by itself never writes that copy.")
    expect(text).to include("a finding that moved nothing names\nnobody")
  end

  # The operator DM is the one route a finding's text takes out of the room it
  # was said in, so where a room announces is itself a disclosure.
  it "says where an announced finding goes and what it carries" do
    expect(text).to include("A finding that moved nothing is also announced")
    expect(text).to include("SemanticAnalysis::TopicRouter::NOTICE_QUOTE_CHARS")
    expect(text).to include("`off` nothing is announced and the audit row is the whole trace")
  end

  it "counts topic routing among the features that reach the OpenArc connection" do
    expect(text).to include("Three of the remaining four use the deployment-wide OpenArc connection")
    expect(text).to include("Six operator-enabled features add outbound calls")
    expect(text).to include("Absent those six features")
  end

  it "states the API queue wait ceilings that the code actually enforces" do
    expect(text).to include(
      "`ApiWrapperEvents::MAX_WAIT_SECONDS`, currently **#{Rubotty::ControlPlane::ApiWrapperEvents::MAX_WAIT_SECONDS}**"
    )
    expect(text).to include(
      "`ApiMessageActions::MAX_WAIT_SECONDS`, currently **#{Rubotty::ControlPlane::ApiMessageActions::MAX_WAIT_SECONDS}**"
    )
  end
end if privacy_document_present
