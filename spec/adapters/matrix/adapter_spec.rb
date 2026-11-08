# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Matrix::Adapter do
  let(:client) do
    MatrixFakes::Client.new(displaynames: { "@ada:example.org" => "Ada L" })
  end
  let(:sync) { MatrixFakes::Sync.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }

  let(:general) do
    endpoint("mx-general", adapter: :matrix, settings: { room_id: "!room:example.org" })
  end

  subject(:adapter) do
    described_class.new(
      account: "mx",
      settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: [general]
    ).replace_client(client).replace_sync(sync)
  end

  # The operator alert names where a flagged message is, and matrix.to is the
  # one shape that resolves across servers.
  describe "#message_permalink" do
    it "writes both ids with their sigils and names the room's own server" do
      expect(adapter.message_permalink(general, "$abc123"))
        .to eq("https://matrix.to/#/!room:example.org/$abc123?via=example.org")
    end

    it "leaves the via hint off a room id that carries no server" do
      local = endpoint("mx-local", adapter: :matrix, settings: { room_id: "!room" })

      expect(adapter.message_permalink(local, "$abc123")).to eq("https://matrix.to/#/!room/$abc123")
    end

    it "answers nothing without an event to point at" do
      expect(adapter.message_permalink(general, "")).to be_nil
    end
  end

  describe "startup" do
    it "learns its own user id, derives the homeserver, and starts syncing" do
      adapter.start
      expect(adapter.own_account_id).to eq("@bot:example.org")
      expect(adapter.origin_label).to eq("example.org")
      expect(sync.started).to be(true)
      expect(adapter).to be_running
    end

    # A bare domain cannot tell the federated platforms apart, so SenderLabel
    # prefixes the protocol onto the handle: "matrix::ada@example.org".
    it "reports its own protocol qualifier" do
      expect(adapter.origin_protocol).to eq("matrix")
    end

    it "refuses to start if it cannot learn its own id" do
      allow(client).to receive(:whoami).and_return(nil)
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /loop prevention/)
    end

    it "converts an unexpected start failure into an AdapterError" do
      allow(client).to receive(:whoami).and_raise(RuntimeError.new("boom"))
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /failed to start.*boom/)
    end

    # One account is one access token, so a missing one means "not yet
    # connected" rather than a fatal boot error.
    it "opts into graceful dormancy when its token is absent" do
      expect(described_class.dormant_on_missing_secret?).to be(true)
    end
  end

  describe "capabilities" do
    it "reports edits, deletes, reactions and the moderation vocabulary" do
      expect(adapter.capabilities.edits?).to be(true)
      expect(adapter.capabilities.reactions?).to be(true)
      %i[delete ban unban kick].each { |a| expect(adapter.capabilities.moderates?(a)).to be(true) }
    end

    it "declares a real upload ceiling" do
      expect(adapter.capabilities.max_attachment_bytes).to eq(25 * 1024 * 1024)
    end
  end

  # Matrix inherited supports_backfill? as false from Adapters::Base, so the
  # paced sweep skipped it entirely and skip_backlog's nightly /sync
  # reconnect had nowhere to go and recover what was said in the gap.
  describe "backfill" do
    before { adapter.start }

    it "reports that it can reconstruct history, its reactions, and answer gap ownership" do
      expect(adapter.supports_backfill?).to be(true)
      expect(adapter.supports_reaction_backfill?).to be(true)
      expect(adapter.supports_gap_ownership?).to be(true)
    end

    it "acquires its own cursor: the first page asks for no from token, walking backward" do
      allow(client).to receive(:messages).and_return([[], nil])
      adapter.backfill_messages(general, since: Time.now - 3600)
      expect(client).to have_received(:messages).with("!room:example.org", from: nil, dir: "b", limit: 100)
    end

    it "reconstructs canonical messages from room history, oldest first" do
      older = MatrixFakes.message_event(id: "$older", content: "first", ts: 1_700_000_100_000)
      newer = MatrixFakes.message_event(id: "$newer", content: "second", ts: 1_700_000_200_000)
      # /messages with dir: "b" hands events back newest first.
      allow(client).to receive(:messages).and_return([[newer, older], nil])

      messages = adapter.backfill_messages(general, since: Time.at(1_700_000_000))

      expect(messages.map { |m| m.ref.native_id }).to eq(%w[$older $newer])
      expect(messages.map { |m| m.body.text }).to eq(%w[first second])
      expect(messages).to all(have_attributes(kind: :chat, origin: general))
    end

    it "pages until it walks past the since horizon, following the previous page's end token" do
      page1 = [MatrixFakes.message_event(id: "$p1", content: "newest", ts: 1_700_000_900_000)]
      page2 = [MatrixFakes.message_event(id: "$p2", content: "too old", ts: 1_700_000_100_000)]
      allow(client).to receive(:messages)
        .with("!room:example.org", from: nil, dir: "b", limit: 100).and_return([page1, "tok1"])
      allow(client).to receive(:messages)
        .with("!room:example.org", from: "tok1", dir: "b", limit: 100).and_return([page2, "tok2"])

      messages = adapter.backfill_messages(general, since: Time.at(1_700_000_500))

      expect(messages.map { |m| m.ref.native_id }).to eq(["$p1"])
    end

    it "stops walking once the room runs out of history to page to" do
      only_page = [MatrixFakes.message_event(id: "$only", ts: 1_700_000_900_000)]
      allow(client).to receive(:messages).and_return([only_page, nil])
      messages = adapter.backfill_messages(general, since: Time.at(1_700_000_000))
      expect(messages.map(&:ref).map(&:native_id)).to eq(["$only"])
    end

    it "skips an m.replace edit row: the original already carries what the edit produced" do
      edit = MatrixFakes.message_event(
        id: "$edit", content: "* fixed",
        "m.new_content" => { "msgtype" => "m.text", "body" => "fixed" },
        "m.relates_to" => { "rel_type" => "m.replace", "event_id" => "$orig" }
      )
      allow(client).to receive(:messages).and_return([[edit], nil])
      expect(adapter.backfill_messages(general, since: Time.at(1_699_000_000))).to be_empty
    end

    it "drops a copy this bridge posted itself, keeping only what a stranger sent" do
      ours = MatrixFakes.message_event(sender: "@bot:example.org", id: "$ours", content: "echo")
      stranger = MatrixFakes.message_event(sender: "@ada:example.org", id: "$theirs", content: "hi")
      allow(client).to receive(:messages).and_return([[stranger, ours], nil])

      messages = adapter.backfill_messages(general, since: Time.at(1_699_000_000))

      expect(messages.map(&:ref).map(&:native_id)).to eq(["$theirs"])
    end

    # #backfill_candidates is the read only twin: same history, nothing dropped.
    it "pairs each backfill candidate with its ownership answer, dropping nothing" do
      ours = MatrixFakes.message_event(sender: "@bot:example.org", id: "$ours", content: "echo")
      stranger = MatrixFakes.message_event(sender: "@ada:example.org", id: "$theirs", content: "hi")
      allow(client).to receive(:messages).and_return([[stranger, ours], nil])

      pairs = adapter.backfill_candidates(general, since: Time.at(1_699_000_000))

      # The fake page arrives newest first ([stranger, ours]); #backfill_candidates
      # returns oldest first, so ours (older) comes back ahead of theirs (newer).
      expect(pairs.map { |message, _ownership| message.ref.native_id }).to eq(%w[$ours $theirs])
      expect(pairs.map { |_message, ownership| ownership }).to eq(%i[ours not_ours])
    end

    it "shapes each history reaction into a reaction_add through the builder a live one takes" do
      allow(client).to receive(:relations)
        .and_return([MatrixFakes.reaction_event(id: "$r1", target: "$msg1", key: "👍")])

      reactions = adapter.backfill_reactions(general, "$msg1")

      expect(reactions.size).to eq(1)
      reaction = reactions.first
      expect(reaction.kind).to eq(:reaction_add)
      expect(reaction.origin).to eq(general)
      expect(reaction.ref).to eq(ref("mx-general", "$msg1"))
      expect(reaction.author.native_id).to eq("@ada:example.org")
      expect(reaction.reaction.emoji).to eq("👍")
    end

    it "asks the relations page for the given limit" do
      allow(client).to receive(:relations).and_return([])
      adapter.backfill_reactions(general, "$msg1", limit: 25)
      expect(client).to have_received(:relations).with("!room:example.org", "$msg1", limit: 25)
    end

    it "treats a message that is already gone as no reactions rather than a sweep failure" do
      allow(client).to receive(:relations)
        .and_raise(Rubotty::AdapterError.new("Matrix GET failed (404 M_NOT_FOUND)", adapter: :matrix))
      expect(adapter.backfill_reactions(general, "$gone")).to eq([])
    end

    it "lets a genuine refusal out rather than swallowing it as gone" do
      allow(client).to receive(:relations)
        .and_raise(Rubotty::PermissionError.new("Matrix GET failed (403 M_FORBIDDEN)", adapter: :matrix))
      expect { adapter.backfill_reactions(general, "$msg1") }.to raise_error(Rubotty::PermissionError)
    end
  end

  describe "inbound" do
    def deliver_event(event) = adapter.handle_event("!room:example.org", event)

    it "converts a message into canonical form and resolves the display name" do
      message = deliver_event(MatrixFakes.message_event(content: "hello"))
      expect(dispatcher.last).to eq(message)
      expect(message.origin.id).to eq("mx-general")
      expect(message.body.text).to eq("hello")
      expect(message.author.username).to eq("ada")
      expect(message.author.display_name).to eq("Ada L")
    end

    it "treats an m.replace as an edit of the original event" do
      event = MatrixFakes.message_event(
        content: "* fixed",
        "m.new_content" => { "msgtype" => "m.text", "body" => "fixed" },
        "m.relates_to" => { "rel_type" => "m.replace", "event_id" => "$orig" }
      )
      message = deliver_event(event)
      expect(message.kind).to eq(:edit)
      expect(message.ref).to eq(ref("mx-general", "$orig"))
      expect(message.body.text).to eq("fixed")
    end

    it "captures a media message as an attachment with an http url" do
      event = MatrixFakes.message_event(
        content: "photo.png", "msgtype" => "m.image",
        "url" => "mxc://example.org/abc123", "info" => { "mimetype" => "image/png", "size" => 10 }
      )
      captured = deliver_event(event).attachments.first
      expect(captured.kind).to eq(:photo)
      expect(captured.url).to eq("https://example.org/_matrix/media/v3/download/example.org/abc123")
    end

    it "records a reply and strips the quoted fallback from the body" do
      event = MatrixFakes.message_event(
        content: "> <@grace:example.org> the original\n\nmy reply",
        "m.relates_to" => { "m.in_reply_to" => { "event_id" => "$parent" } }
      )
      message = deliver_event(event)
      expect(message.reply_to).to eq(ref("mx-general", "$parent"))
      expect(message.body.text).to eq("my reply")
    end

    it "turns an annotation into a reaction event" do
      event = { "type" => "m.reaction", "event_id" => "$r1", "sender" => "@ada:example.org",
                "content" => { "m.relates_to" => { "rel_type" => "m.annotation",
                                                   "event_id" => "$target", "key" => "👍" } } }
      message = deliver_event(event)
      expect(message.kind).to eq(:reaction_add)
      expect(message.reaction.emoji).to eq("👍")
      expect(message.ref).to eq(ref("mx-general", "$target"))
    end

    it "turns a redaction into a delete of the redacted event" do
      event = { "type" => "m.room.redaction", "event_id" => "$x", "sender" => "@ada:example.org",
                "redacts" => "$gone" }
      message = deliver_event(event)
      expect(message.kind).to eq(:delete)
      expect(message.ref).to eq(ref("mx-general", "$gone"))
    end

    # Taking a reaction back on Matrix redacts the m.reaction event itself,
    # not the message. That event id lives in no message map, so
    # translating every redaction into :delete found nothing to remove, and
    # the emoji stayed up on every mirror for good.
    it "turns a redacted reaction into a reaction_remove rather than an unrouteable delete" do
      add = { "type" => "m.reaction", "event_id" => "$react1", "sender" => "@ada:example.org",
              "content" => { "m.relates_to" => { "rel_type" => "m.annotation",
                                                 "event_id" => "$msg1", "key" => "👍" } } }
      remove = { "type" => "m.room.redaction", "event_id" => "$redact1", "sender" => "@ada:example.org",
                 "redacts" => "$react1" }
      deliver_event(add)

      message = deliver_event(remove)

      expect(message.kind).to eq(:reaction_remove)
      expect(message.ref).to eq(ref("mx-general", "$msg1"))
      expect(message.reaction.emoji).to eq("👍")
    end

    # Matrix lets a moderator redact somebody else's m.reaction, and the
    # redaction event's sender field names the moderator. The reaction_remove
    # this produces has to keep crediting the original reactor, or it reads
    # as the moderator taking their own reaction back.
    it "attributes a moderator's redaction of another member's reaction to the original reactor" do
      add = { "type" => "m.reaction", "event_id" => "$react1", "sender" => "@ada:example.org",
              "content" => { "m.relates_to" => { "rel_type" => "m.annotation",
                                                 "event_id" => "$msg1", "key" => "👍" } } }
      redact = { "type" => "m.room.redaction", "event_id" => "$redact1", "sender" => "@mod:example.org",
                 "redacts" => "$react1" }
      deliver_event(add)

      message = deliver_event(redact)

      expect(message.kind).to eq(:reaction_remove)
      expect(message.author.native_id).to eq("@ada:example.org")
    end

    it "relays a genuine join but not a mere profile change" do
      join = { "type" => "m.room.member", "event_id" => "$j", "sender" => "@ada:example.org",
               "state_key" => "@ada:example.org", "content" => { "membership" => "join" },
               "unsigned" => { "prev_content" => { "membership" => "leave" } } }
      expect(deliver_event(join).kind).to eq(:join)

      rename = { "type" => "m.room.member", "event_id" => "$p", "sender" => "@ada:example.org",
                 "state_key" => "@ada:example.org", "content" => { "membership" => "join" },
                 "unsigned" => { "prev_content" => { "membership" => "join" } } }
      expect(deliver_event(rename)).to be_nil
    end

    # unsigned.prev_content is optional and some homeservers never send it;
    # without a fallback, a routine displayname change on an already joined
    # member reads exactly like a fresh join, since "join" != nil.
    it "does not misread a profile change as a fresh join when the homeserver sends no prev_content at all" do
      join = { "type" => "m.room.member", "event_id" => "$j", "sender" => "@ada:example.org",
               "state_key" => "@ada:example.org", "content" => { "membership" => "join" } }
      expect(deliver_event(join).kind).to eq(:join)

      profile_change = { "type" => "m.room.member", "event_id" => "$p", "sender" => "@ada:example.org",
                         "state_key" => "@ada:example.org",
                         "content" => { "membership" => "join", "displayname" => "Ada Renamed" } }
      expect(deliver_event(profile_change)).to be_nil
    end

    it "still relays a first-ever join with no prev_content, since nothing marked that member as known yet" do
      join = { "type" => "m.room.member", "event_id" => "$j", "sender" => "@grace:example.org",
               "state_key" => "@grace:example.org", "content" => { "membership" => "join" } }
      expect(deliver_event(join).kind).to eq(:join)
    end

    it "ignores a room it has no endpoint for" do
      expect(adapter.handle_event("!other:example.org", MatrixFakes.message_event)).to be_nil
    end

    it "reads an m.thread relation as the message's thread" do
      event = MatrixFakes.message_event(
        content: "in the thread",
        "m.relates_to" => { "rel_type" => "m.thread", "event_id" => "$root" }
      )
      message = deliver_event(event)
      expect(message.in_thread?).to be(true)
      expect(message.thread.native_id).to eq("$root")
    end

    it "leaves a plain channel message with no thread" do
      expect(deliver_event(MatrixFakes.message_event).in_thread?).to be(false)
    end

    it "reads formatted_body back into spans when it carries recognised markup" do
      event = MatrixFakes.message_event(
        content: "bold text", "format" => "org.matrix.custom.html",
        "formatted_body" => "<b>bold</b> text"
      )
      body = deliver_event(event).body
      expect(body.text).to eq("bold text")
      span = body.spans.first
      expect(span.kind).to eq(:bold)
      expect(body.text[span.begin_index...span.end_index]).to eq("bold")
    end

    it "falls back to the plain body when formatted_body is not well formed" do
      event = MatrixFakes.message_event(
        content: "plain fallback", "format" => "org.matrix.custom.html",
        "formatted_body" => "<b>unclosed"
      )
      expect(deliver_event(event).body.text).to eq("plain fallback")
    end

    it "ignores formatted_body when format is not the HTML custom format" do
      event = MatrixFakes.message_event(
        content: "plain only", "formatted_body" => "<b>should not be read</b>"
      )
      message = deliver_event(event)
      expect(message.body.text).to eq("plain only")
      expect(message.body.spans).to be_empty
    end
  end

  describe "outbound" do
    let(:outgoing) { message(general, text: "hello").with(sender_label: "Ada") }

    it "sends a plaintext body and an HTML formatted_body with the sender prefix" do
      receipt = adapter.deliver(outgoing, general)
      content = client.sent_events.first[:content]
      expect(content["body"]).to start_with("Ada:")
      expect(content["body"]).to include("hello")
      expect(content["formatted_body"]).to include("<b>Ada</b>")
      expect(content["format"]).to eq("org.matrix.custom.html")
      expect(receipt.native_id).to eq("$event-1")
    end

    it "turns text newlines into <br/> in the HTML body but keeps them in plain" do
      multiline = message(general, text: "line1\nline2").with(sender_label: "Ada")
      adapter.deliver(multiline, general)
      content = client.sent_events.first[:content]
      expect(content["formatted_body"]).to include("line1<br/>line2")
      expect(content["body"]).to include("line1\nline2")
    end

    it "does not double-render a structured label (the SenderLabel mutation guard)" do
      label = Rubotty::Core::SenderLabel.new(username: "ada", platform: "matrix", display_name: "Ada L")
      adapter.deliver(message(general, text: "hi").with(sender_label: label), general)
      content = client.sent_events.first[:content]
      expect(content["body"]).to start_with("Ada L [ada@matrix]:")
      expect(content["formatted_body"]).to include("<b>Ada L</b> [ada@matrix]")
    end

    it "attaches a native reply relation when the parent lives on this endpoint" do
      local = outgoing.with(reply_to: ref("mx-general", "$parent"))
      adapter.deliver(local, general)
      relation = client.sent_events.first[:content]["m.relates_to"]
      expect(relation).to eq("m.in_reply_to" => { "event_id" => "$parent" })
    end

    it "quotes the parent when a native reply is impossible" do
      preview = Rubotty::Core::ReplyPreview.new(body: Rubotty::Core::RichText.plain("the original"), label: "Grace")
      foreign = outgoing.with(reply_to: ref("tg-general", "42"), reply_preview: preview)
      adapter.deliver(foreign, general)
      content = client.sent_events.first[:content]
      expect(content["body"]).to include("> Grace: the original")
      expect(content["formatted_body"]).to include("<blockquote>")
      expect(content["m.relates_to"]).to be_nil
    end

    it "sends an edit as an m.replace pointing at the original event" do
      edited = outgoing.with(body: Rubotty::Core::RichText.plain("fixed"))
      receipt = adapter.edit(edited, general, "$orig")
      content = client.sent_events.first[:content]
      expect(content["m.relates_to"]).to eq("rel_type" => "m.replace", "event_id" => "$orig")
      expect(content["m.new_content"]["body"]).to include("fixed")
      expect(receipt.native_id).to eq("$orig")
    end

    it "redacts a message to delete it, treating a gone one as success" do
      adapter.delete(general, "$m1")
      expect(client.redactions.first[:event]).to eq("$m1")

      allow(client).to receive(:redact)
        .and_raise(Rubotty::AdapterError.new("Matrix redact failed (404 M_NOT_FOUND)", adapter: :matrix))
      expect { adapter.delete(general, "$gone") }.not_to raise_error
    end

    # No sender prefix, no attachments: nothing worth posting, a routine
    # decline rather than an attempted send that came back empty.
    it "signals a blank body as NOT_APPLICABLE rather than a bare nil" do
      blank = message(general, text: "")
      receipt = adapter.deliver(blank, general)
      expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(receipt).to be_nil
      expect(client.sent_events).to be_empty
    end
  end

  # Nothing on the send path used to check whether a room was end to end
  # encrypted before posting a plaintext event into it, even though the
  # inbound side already detects m.room.encrypted and refuses to read it.
  describe "a room this bridge has learned is encrypted" do
    let(:outgoing) { message(general, text: "hello") }

    before do
      encrypted = { "type" => "m.room.encrypted", "event_id" => "$e1", "sender" => "@ada:example.org",
                    "content" => {} }
      adapter.handle_event("!room:example.org", encrypted)
    end

    it "refuses to deliver a plaintext message into it" do
      expect { adapter.deliver(outgoing, general) }.to raise_error(Rubotty::AdapterError, /encrypted/)
      expect(client.sent_events).to be_empty
    end

    it "refuses to post a plaintext edit into it" do
      expect { adapter.edit(outgoing, general, "$orig") }.to raise_error(Rubotty::AdapterError, /encrypted/)
      expect(client.sent_events).to be_empty
    end

    it "refuses to post a plaintext reaction into it" do
      thumbs = Rubotty::Core::Reaction.new(emoji: "👍")
      expect { adapter.sync_reactions(general, "$target", desired: [thumbs], previous: []) }
        .to raise_error(Rubotty::AdapterError, /encrypted/)
      expect(client.sent_events).to be_empty
    end
  end

  # matrix/outbound.rb declared attachments and attachment_by_url but
  # matrix/client.rb had no upload method at all, so a Telegram file URL
  # (which embeds the bot token and always fails the public url test) always
  # degraded to "[label, could not be relayed]" and never actually arrived.
  describe "media" do
    let(:outgoing) { message(general, text: "look").with(sender_label: "Ada") }

    def stubbed_fetcher(&block)
      Rubotty::Util::MediaFetcher.new(http: block)
    end

    def fake_file(bytes)
      StringIO.new(bytes).tap { |io| io.define_singleton_method(:unlink) { nil } }
    end

    it "uploads a resolvable attachment into the content repository and posts it as a real event" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("PNGDATA") })
      allow(client).to receive(:upload).and_return("mxc://example.org/newid")
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")

      adapter.deliver(outgoing.with(attachments: [photo]), general)

      expect(client.sent_events.size).to eq(2)
      text, media = client.sent_events
      expect(text[:content]["body"]).to include("look")
      expect(text[:content]["body"]).not_to include("https://cdn.example/a.png")
      expect(media[:content]).to include("msgtype" => "m.image", "url" => "mxc://example.org/newid")
      expect(client).to have_received(:upload).with("PNGDATA", filename: "a.png", content_type: nil)
    end

    it "never puts a credentialed source URL into the room, uploading its bytes instead" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("JPEGDATA") })
      allow(client).to receive(:upload).and_return("mxc://example.org/leaky")
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )

      adapter.deliver(outgoing.with(attachments: [leaky]), general)

      bodies = client.sent_events.map { |event| event[:content].to_s }
      expect(bodies.join).not_to include("AAsecret")
      expect(client.sent_events.map { |e| e[:content]["url"] }).to include("mxc://example.org/leaky")
    end

    it "falls back to the existing link degradation when the download fails" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| nil })
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")

      adapter.deliver(outgoing.with(attachments: [photo]), general)

      expect(client.sent_events.size).to eq(1)
      expect(client.sent_events.first[:content]["body"]).to include("https://cdn.example/a.png")
    end

    it "falls back to the marker when the upload itself is refused and the source url is not safe to link either" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("JPEGDATA") })
      allow(client).to receive(:upload)
        .and_raise(Rubotty::AdapterError.new("Matrix upload failed (413)", adapter: :matrix))
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )

      receipt = adapter.deliver(outgoing.with(attachments: [leaky]), general)

      expect(client.sent_events.size).to eq(1)
      expect(client.sent_events.first[:content]["body"]).to include("[a.jpg, could not be relayed]")
      # An upload that failed still counts as unrelayed for the sender note
      # #notes_extra reports, the same as a credentialed url that was never
      # tried.
      expect(receipt.extra[:notes]).to include(a_string_matching(/could not relay a\.jpg/))
    end

    it "carries no failure note once the upload succeeds, even for a url the link fallback would refuse" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("JPEGDATA") })
      allow(client).to receive(:upload).and_return("mxc://example.org/leaky")
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )

      receipt = adapter.deliver(outgoing.with(attachments: [leaky]), general)

      expect(receipt.extra).to eq({})
    end

    # A media upload that reaches the content repository but never gets an
    # m.room.message event posted (a 429, a dropped connection) used to look
    # identical to "nothing to send by design" when the message also had no
    # text body: native_id fell back to nil either way, so content vanished with no error.
    it "raises rather than reporting NOT_APPLICABLE when an upload succeeds but posting it fails" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("PNGDATA") })
      allow(client).to receive(:upload).and_return("mxc://example.org/newid")
      allow(client).to receive(:send_event).and_raise(RuntimeError.new("429"))
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      blank = message(general, text: "").with(attachments: [photo])

      expect { adapter.deliver(blank, general) }.to raise_error(Rubotty::AdapterError, /could not post/)
    end

    it "notes an uploaded attachment whose posting failed, once other content still lets delivery succeed" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("PNGDATA") })
      allow(client).to receive(:upload).and_return("mxc://example.org/newid")
      allow(client).to receive(:send_event).and_wrap_original do |original, room_id, type, event_content, **kwargs|
        raise RuntimeError, "429" if event_content["msgtype"] == "m.image"

        original.call(room_id, type, event_content, **kwargs)
      end
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")

      receipt = adapter.deliver(outgoing.with(attachments: [photo]), general)

      expect(client.sent_events.size).to eq(1)
      expect(receipt.extra[:notes]).to include(a_string_matching(/could not relay a\.png/))
    end

    it "anchors the delivery receipt to the uploaded attachment when there is no text to send" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("PNGDATA") })
      allow(client).to receive(:upload).and_return("mxc://example.org/newid")
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      blank = message(general, text: "").with(attachments: [photo])

      receipt = adapter.deliver(blank, general)

      expect(client.sent_events.size).to eq(1)
      expect(client.sent_events.first[:content]["url"]).to eq("mxc://example.org/newid")
      expect(receipt.native_id).to eq("$event-1")
    end
  end

  describe "reactions" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }

    it "adds an annotation event and redacts it to remove the reaction" do
      adapter.sync_reactions(general, "$target", desired: [thumbs], previous: [])
      annotation = client.sent_events.first
      expect(annotation[:type]).to eq("m.reaction")
      expect(annotation[:content]["m.relates_to"]).to include("key" => "👍", "event_id" => "$target")

      adapter.sync_reactions(general, "$target", desired: [], previous: [thumbs])
      expect(client.redactions.map { |r| r[:event] }).to include("$event-1")
    end

    it "skips a foreign custom emoji with no Matrix equivalent" do
      custom = Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot")
      adapter.sync_reactions(general, "$target", desired: [custom], previous: [])
      expect(client.sent_events).to be_empty
    end

    # Swallowing this left the bridge recording the mirror as placed, and
    # storage then holds an emoji the message does not have.
    it "lets a refused annotation out, rather than reporting one it did not send" do
      allow(client).to receive(:send_event)
        .and_raise(Rubotty::PermissionError.new("Matrix send failed (403): M_FORBIDDEN",
                                                adapter: :matrix))
      expect { adapter.sync_reactions(general, "$target", desired: [thumbs], previous: []) }
        .to raise_error(Rubotty::PermissionError)
    end

    it "still treats an annotation on an event that is already gone as done" do
      allow(client).to receive(:send_event)
        .and_raise(Rubotty::AdapterError.new("Matrix send failed (404): M_NOT_FOUND", adapter: :matrix))
      expect { adapter.sync_reactions(general, "$target", desired: [thumbs], previous: []) }
        .not_to raise_error
    end

    def build_adapter_with(client, storage)
      described_class.new(
        account: "mx",
        settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      ).replace_client(client).replace_sync(MatrixFakes::Sync.new).tap { |a| a.storage = storage }
    end

    it "still finds and redacts the placing event after a restart, with storage shared across instances" do
      storage = Rubotty::Storage::Memory.new
      before_restart_client = MatrixFakes::Client.new
      build_adapter_with(before_restart_client, storage)
                      .sync_reactions(general, "$target", desired: [thumbs], previous: [])
      expect(before_restart_client.sent_events.first[:type]).to eq("m.reaction")

      # A fresh instance, as a restart would produce: nothing survives in its
      # own in process Hash, only whatever storage carried forward.
      after_restart_client = MatrixFakes::Client.new
      build_adapter_with(after_restart_client, storage)
                      .sync_reactions(general, "$target", desired: [], previous: [thumbs])

      expect(after_restart_client.redactions.map { |r| r[:event] }).to eq(["$event-1"])
    end
  end

  describe "accepting a room invite" do
    # Recognising our own invite compares state_key against own_account_id,
    # which #start learns from whoami; every scenario here needs that done
    # first, the same as a real boot before the sync loop ever sees an invite.
    before { adapter.start }

    it "reports that it can leave a room and post a bare notice into one" do
      expect(adapter.supports_leave?).to be(true)
      expect(adapter.supports_space_notice?).to be(true)
    end

    it "joins the room named in rooms.invite, with no guard wired" do
      adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state)
      expect(client.joins).to eq(["!invited:example.org"])
    end

    it "does nothing for stripped state carrying no invite naming our own user id" do
      adapter.handle_invite("!invited:example.org", [])
      expect(client.joins).to be_empty
    end

    it "does not raise when accepting the invite itself fails" do
      client.fail_next_join!
      expect { adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state) }.not_to raise_error
      expect(client.joins).to be_empty
    end

    it "feeds the newly joined room to discovery, using the name from the invite state" do
      discovery = instance_double(Rubotty::ControlPlane::ChannelDiscovery)
      allow(discovery).to receive(:saw)
      allow(discovery).to receive(:inventory)
      with_discovery = described_class.new(
        account: "mx", settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general], discovery: discovery
      ).replace_client(client).replace_sync(sync)
      with_discovery.start

      with_discovery.handle_invite("!invited:example.org", MatrixFakes.invite_state(title: "Chat Room"))

      expect(discovery).to have_received(:saw).with(
        adapter: :matrix, account: "mx", external_id: "mx", route_key: "!invited:example.org", name: "Chat Room"
      )
    end

    describe "with a join guard wired" do
      let(:guard) do
        Class.new do
          attr_reader :calls
          attr_accessor :decision

          def initialize
            @calls = []
            @decision = Rubotty::ControlPlane::JoinGuard::Decision.new(action: :leave, notice: "private bot, leaving")
            @leave_failures = []
          end

          def on_join(adapter:, account:, external_id:, title: nil, inviter: nil, channel_sample: [])
            @calls << { adapter: adapter, account: account, external_id: external_id, title: title,
                        inviter: inviter, channel_sample: channel_sample }
            @decision
          end

          def record_leave_failure(adapter:, account:, external_id:)
            key = [adapter, account, external_id]
            return false if @leave_failures.include?(key)

            @leave_failures << key
            true
          end
        end.new
      end

      subject(:guarded_adapter) do
        described_class.new(
          account: "mx", settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general], join_guard: guard
        ).replace_client(client).replace_sync(sync)
      end

      before { guarded_adapter.start }

      it "asks the guard about the room with the room id as the space id and the invite's title" do
        guarded_adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state(title: "Chat Room"))
        expect(guard.calls.size).to eq(1)
        expect(guard.calls.first).to include(adapter: :matrix, account: "mx", external_id: "!invited:example.org",
                                              title: "Chat Room")
        expect(guard.calls.first[:inviter].native_id).to eq("@ada:example.org")
      end

      it "leaves an unauthorized room after accepting it, posting the guard's notice" do
        guarded_adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state)
        expect(client.joins).to eq(["!invited:example.org"])
        expect(client.leaves).to eq(["!invited:example.org"])
        notice = client.sent_events.find { |e| e[:content]["msgtype"] == "m.notice" }
        expect(notice[:content]["body"]).to eq("private bot, leaving")
      end

      it "posts the inert fallback notice when the leave call itself fails" do
        allow(client).to receive(:leave_room)
          .and_raise(Rubotty::AdapterError.new("Matrix leave failed (403): M_FORBIDDEN", adapter: :matrix))
        guarded_adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state)
        notice = client.sent_events.find { |e| e[:content]["body"] == Rubotty::ControlPlane::JoinGuard::INERT_NOTICE }
        expect(notice).not_to be_nil
      end

      it "stays in an authorized room, posting nothing and leaving nothing further" do
        guard.decision = Rubotty::ControlPlane::JoinGuard::Decision.new(action: :stay)
        guarded_adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state)
        expect(client.joins).to eq(["!invited:example.org"])
        expect(client.leaves).to be_empty
        expect(client.sent_events).to be_empty
      end
    end

    describe "with a pending-spaces service wired" do
      let(:guard) do
        Class.new do
          def on_join(adapter:, account:, external_id:, title: nil, inviter: nil, channel_sample: [])
            Rubotty::ControlPlane::JoinGuard::Decision.new(action: :leave, notice: "unused")
          end
        end.new
      end

      let(:pending_spaces) do
        Class.new do
          attr_reader :calls, :marked, :reconfirmed
          attr_accessor :outcome

          def initialize
            row = Struct.new(:id, :notice_posted_at).new(1, nil)
            @outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(action: :pending, row: row, post_notice: true)
            @calls = []
            @marked = []
            @reconfirmed = []
          end

          def on_join!(**kwargs)
            @calls << kwargs
            @outcome
          end

          def mark_notice_posted!(row) = @marked << row

          def reconfirm_denied!(row) = @reconfirmed << row
        end.new
      end

      subject(:pending_adapter) do
        described_class.new(
          account: "mx", settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general],
          join_guard: guard, pending_spaces: pending_spaces
        ).replace_client(client).replace_sync(sync)
      end

      before { pending_adapter.start }

      it "consumes the normalized join signal instead of leaving directly" do
        pending_adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state(title: "New Space"))
        expect(client.leaves).to be_empty
        expect(pending_spaces.calls.size).to eq(1)
        expect(pending_spaces.calls.first).to include(
          adapter: :matrix, account: "mx", external_id: "!invited:example.org", name: "New Space",
          inviter_native_id: "@ada:example.org", sample_channels: []
        )
      end

      it "posts the pending notice and records that it did, when the outcome says to" do
        pending_adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state)
        notice = client.sent_events.find { |e| e[:content]["body"] == Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE }
        expect(notice).not_to be_nil
        expect(pending_spaces.marked.size).to eq(1)
      end

      it "reconfirms a denied re-invite through the service, posting and leaving nothing itself" do
        pending_spaces.outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(
          action: :leave, row: pending_spaces.outcome.row, post_notice: false
        )
        pending_adapter.handle_invite("!invited:example.org", MatrixFakes.invite_state)
        expect(pending_spaces.reconfirmed.size).to eq(1)
        expect(client.sent_events).to be_empty
        expect(client.leaves).to be_empty
      end
    end
  end

  describe "moderation" do
    def command(action)
      Rubotty::Core::Moderation::Command.new(
        action: action,
        issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general,
        target_user_id: "@bad:example.org"
      )
    end

    it "redacts for a delete, and kicks, bans and unbans through the room" do
      expect(adapter.moderate(command(:delete), general, "$m1").status).to eq(:done)
      expect(client.redactions.first[:event]).to eq("$m1")

      expect(adapter.moderate(command(:kick), general, nil).status).to eq(:done)
      expect(client.kicks.first).to include(room: "!room:example.org", user: "@bad:example.org")

      expect(adapter.moderate(command(:ban), general, nil).status).to eq(:done)
      expect(adapter.moderate(command(:unban), general, nil).status).to eq(:done)
    end

    it "reports an action outside its vocabulary as unsupported" do
      expect(adapter.moderate(command(:mute), general, nil).status).to eq(:unsupported)
    end
  end

  describe "#send_admin_dm" do
    it "says it can" do
      expect(adapter.supports_admin_dm?).to be(true)
    end

    it "opens a direct room and posts into it, handing back a DmReceipt" do
      receipt = adapter.send_admin_dm("@ada:example.org", "a room needs you")

      expect(receipt).to be_a(Rubotty::Core::DmReceipt)
      expect(client.created_rooms.first).to include(invite: "@ada:example.org")
      expect(client.sent_events.first).to include(room: receipt.channel_ref)
      expect(client.sent_events.first[:content]).to include(body: "a room needs you")
    end

    it "reuses the room already recorded for that person rather than opening a second one" do
      first = adapter.send_admin_dm("@ada:example.org", "one")
      second = adapter.send_admin_dm("@ada:example.org", "two")

      expect(client.created_rooms.length).to eq(1)
      expect(second.channel_ref).to eq(first.channel_ref)
    end

    it "answers nil rather than sending, for blank text" do
      expect(adapter.send_admin_dm("@ada:example.org", "   ")).to be_nil
      expect(client.created_rooms).to be_empty
    end

    it "answers nil rather than raising, when the send itself fails" do
      allow(client).to receive(:create_room).and_raise(Rubotty::AdapterError.new("boom", adapter: :matrix))

      expect { expect(adapter.send_admin_dm("@ada:example.org", "hi")).to be_nil }.not_to raise_error
    end
  end

  describe "#delete_admin_dm" do
    it "says it can" do
      expect(adapter.supports_admin_dm_delete?).to be(true)
    end

    it "redacts the event in the direct room the receipt names" do
      receipt = adapter.send_admin_dm("@ada:example.org", "a room needs you")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
      expect(client.redactions.first).to eq(room: receipt.channel_ref, event: receipt.native_id)
    end

    it "treats an already gone event as success" do
      receipt = adapter.send_admin_dm("@ada:example.org", "a room needs you")
      allow(client).to receive(:redact)
        .and_raise(Rubotty::AdapterError.new("Matrix redact failed (404 M_NOT_FOUND): Unknown event", adapter: :matrix))

      expect(adapter.delete_admin_dm(receipt)).to be(true)
    end

    it "answers false for a nil receipt" do
      expect(adapter.delete_admin_dm(nil)).to be(false)
    end
  end

  # Matrix has no guild id at all, so the bot's own account is the coarse space
  # discovery scopes to. No fixture wires a Matrix account, so the
  # platform_connection it needs is seeded by hand.
  describe "room discovery (#38, #39)", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community) { models.community.first }

    let(:matrix_connection) do
      models.platform_connection.create(
        community_id: community.id, adapter: "matrix", account: "mx", external_id: "mx",
        label: nil, created_at: Time.now, updated_at: Time.now
      )
    end

    let(:store) do
      Class.new do
        def initialize = @h = {}

        def get_state(key)
          row = @h[key]
          row && (row[:expires_at].nil? || row[:expires_at] > Time.now) ? row[:value] : nil
        end

        def put_state(key, value, expires_at: nil) = @h[key] = { value: value, expires_at: expires_at }
      end.new
    end

    let(:notifier) do
      Class.new do
        attr_reader :prompts

        def initialize = @prompts = []

        def prompt(community:, descriptor:) = @prompts << descriptor
      end.new
    end

    let(:watch) { Rubotty::ControlPlane::NewChannelWatch.new(models: models, store: store) }
    let(:discovery) do
      Rubotty::ControlPlane::ChannelDiscovery.new(models: models, watch: watch, notifier: notifier)
    end

    let(:discovery_client) { MatrixFakes::Client.new }

    def build_adapter(endpoints: [], discovery: nil)
      described_class.new(
        account: "mx",
        settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: endpoints, discovery: discovery
      ).replace_client(discovery_client).replace_sync(MatrixFakes::Sync.new)
    end

    subject(:discovering_adapter) do
      matrix_connection # force creation before the adapter touches the connection
      build_adapter(discovery: discovery)
    end

    def enable_alerts
      settings = community.json_value(:settings)
      settings["new_channel_alerts"] = { "enabled" => true, "ignore" => [] }
      community.update(settings: JSON.generate(settings))
    end

    def disable_alerts
      settings = community.json_value(:settings)
      settings["new_channel_alerts"] = { "enabled" => false }
      community.update(settings: JSON.generate(settings))
    end

    describe "passive: a message reveals the room (#39)" do
      it "learns a brand-new room and prompts the operator in an opted-in community" do
        enable_alerts
        discovering_adapter.handle_event("!fresh:example.org", MatrixFakes.message_event)

        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["!fresh:example.org"])
        row = models.channel.where(adapter: "matrix", route_key: "!fresh:example.org").first
        expect(row).not_to be_nil
      end

      it "prompts by default, without an explicit opt-in" do
        discovering_adapter.handle_event("!fresh2:example.org", MatrixFakes.message_event)
        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["!fresh2:example.org"])
      end

      it "learns nothing once a community explicitly opts out" do
        disable_alerts
        discovering_adapter.handle_event("!fresh:example.org", MatrixFakes.message_event)
        expect(notifier.prompts).to be_empty
        expect(models.channel.where(route_key: "!fresh:example.org").first).to be_nil
      end

      it "never consumes the event: a mapped room's message still routes" do
        matrix_connection
        mapped = endpoint("mx-mapped", adapter: :matrix, settings: { room_id: "!mapped:example.org" })
        adapter = build_adapter(endpoints: [mapped], discovery: discovery)

        adapter.handle_event("!mapped:example.org", MatrixFakes.message_event(content: "hi"))
        expect(dispatcher.last.body.text).to eq("hi")
      end

      it "ignores a non-message event (a reaction carries no route to learn)" do
        enable_alerts
        event = { "type" => "m.reaction", "event_id" => "$r1", "sender" => "@ada:example.org",
                  "content" => { "m.relates_to" => { "rel_type" => "m.annotation",
                                                     "event_id" => "$t", "key" => "👍" } } }
        discovering_adapter.handle_event("!fresh:example.org", event)
        expect(notifier.prompts).to be_empty
      end

      it "does not fail the receive loop when discovery raises" do
        allow(discovery).to receive(:saw).and_raise(StandardError.new("boom"))
        expect do
          discovering_adapter.handle_event("!fresh:example.org", MatrixFakes.message_event)
        end.not_to raise_error
      end
    end

    describe "active: enumerating joined rooms at start (#38)" do
      it "records every joined room, named from m.room.name or the canonical alias" do
        discovery_client.set_joined_rooms(%w[!named:example.org !aliased:example.org !bare:example.org])
        discovery_client.set_room_name("!named:example.org", "General")
        discovery_client.set_room_alias("!aliased:example.org", "#lobby:example.org")

        discovering_adapter.start

        rows = models.channel.where(adapter: "matrix").order(:route_key).all
        expect(rows.map(&:route_key)).to contain_exactly(
          "!aliased:example.org", "!bare:example.org", "!named:example.org"
        )
        expect(rows.find { |r| r.route_key == "!named:example.org" }.label).to eq("General")
        expect(rows.find { |r| r.route_key == "!aliased:example.org" }.label).to eq("#lobby:example.org")
        expect(rows.find { |r| r.route_key == "!bare:example.org" }.label).to be_nil
      end

      it "is idempotent: a second sweep records nothing new" do
        discovery_client.set_joined_rooms(["!again:example.org"])
        discovering_adapter.start
        expect(models.channel.where(route_key: "!again:example.org").count).to eq(1)

        build_adapter(discovery: discovery).start
        expect(models.channel.where(route_key: "!again:example.org").count).to eq(1)
      end

      it "does not break start when listing rooms fails" do
        allow(discovery_client).to receive(:joined_rooms)
          .and_raise(Rubotty::AdapterError.new("homeserver unreachable", adapter: :matrix))
        expect { discovering_adapter.start }.not_to raise_error
        expect(discovering_adapter).to be_running
      end

      it "records a room even when its name and alias lookups both fail" do
        discovery_client.set_joined_rooms(["!broken:example.org"])
        allow(discovery_client).to receive(:room_name)
          .and_raise(Rubotty::AdapterError.new("boom", adapter: :matrix))
        allow(discovery_client).to receive(:room_canonical_alias)
          .and_raise(Rubotty::AdapterError.new("boom", adapter: :matrix))

        expect { discovering_adapter.start }.not_to raise_error
        row = models.channel.where(route_key: "!broken:example.org").first
        expect(row).not_to be_nil
        expect(row.label).to be_nil
      end

      it "does nothing without discovery wired" do
        plain = build_adapter
        expect(discovery_client).not_to receive(:joined_rooms)
        plain.start
      end
    end
  end
end
