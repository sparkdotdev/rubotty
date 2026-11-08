# frozen_string_literal: true

require "spec_helper"

# A webhook message cannot make a native reply (Execute Webhook has no
# message_reference), so the quote is the only way the relationship survives.
# compose() used to suppress the quote whenever a native reply id resolved, so a
# reply relayed through a webhook arrived looking like an unrelated message.
RSpec.describe Rubotty::Adapters::Discord::Outbound, "reply quoting on the webhook path" do
  subject(:outbound) { described_class.new }

  let(:target) { endpoint("dc-general", adapter: :discord, settings: { channel_id: "1" }) }
  let(:origin) { endpoint("tg-general", adapter: :telegram) }

  # A reply whose parent the bridge relayed, so its id resolves on the Discord
  # target: the case that used to be dropped.
  def reply_to_relayed
    preview = Rubotty::Core::ReplyPreview.new(
      body: Rubotty::Core::RichText.plain("the parent message"),
      label: "Alice"
    )
    message(origin, text: "my reply", reply_to: ref(target.id, "999"), reply_preview: preview)
  end

  it "keeps the quote when posting through a webhook, since no native reply is possible" do
    body = outbound.compose(reply_to_relayed, target, webhook: true)
    expect(body).to include("the parent message")
    expect(body).to include("> ")
  end

  it "still omits the quote when posting as the bot, where the native reply shows the parent" do
    body = outbound.compose(reply_to_relayed, target, webhook: false)
    expect(body).not_to include("the parent message")
  end
end
