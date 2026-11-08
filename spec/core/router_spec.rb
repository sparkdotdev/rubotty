# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Router do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:irc) { endpoint("irc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  def build_router(*rooms)
    described_class.new(
      topology: topology(*rooms),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: loop_guard,
      logger: Rubotty::Log.null,
      ttl: 3600
    )
  end

  describe "fan out" do
    it "delivers a two endpoint message to the other endpoint" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.map(&:first)).to eq(["dc"])
    end

    # N way is the point of the topology model, with pairwise falling out of it.
    it "delivers to every other endpoint in an N way room" do
      router = build_router(room("r", tg, dc, irc))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.map(&:first)).to contain_exactly("dc", "irc")
    end

    it "never delivers back to the origin" do
      router = build_router(room("r", tg, dc, irc))
      router.handle(message(dc, text: "hi"))
      expect(adapter.delivered.map(&:first)).not_to include("dc")
    end

    it "delivers into every room the origin belongs to" do
      hub = endpoint("hub")
      router = build_router(room("r1", hub, tg), room("r2", hub, dc))
      router.handle(message(hub, text: "hi"))
      expect(adapter.delivered.map(&:first)).to contain_exactly("tg", "dc")
    end

    it "skips endpoints configured not to receive deliveries" do
      readonly = endpoint("readonly", sends: false)
      router = build_router(room("r", tg, readonly))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered).to be_empty
    end

    it "ignores an endpoint that belongs to no room" do
      router = build_router(room("r", dc, irc))
      expect(router.handle(message(tg, text: "hi"))).to eq([])
    end

    it "drops a message with neither text nor attachments" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: ""))
      expect(adapter.delivered).to be_empty
    end

    it "renders a configured display name template to a plain string label" do
      router = build_router(room("r", tg, dc, display_name_template: "{first_name} ({username})"))
      router.handle(message(tg, text: "hi", author: author(first_name: "Ada", username: "ada")))
      expect(adapter.delivered.first.last.sender_label).to eq("Ada (ada)")
    end

    # With no template configured, the label is the structured cross platform
    # form, tagged with the ORIGIN platform.
    it "builds a structured cross platform label by default" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi", author: author(first_name: "Ada", username: "ada")))
      label = adapter.delivered.first.last.sender_label
      expect(label).to be_a(Rubotty::Core::SenderLabel)
      expect(label.username).to eq("ada")
      expect(label.display_name).to eq("Ada")
    end

    # The platform token comes from the origin ADAPTER, so a federated platform
    # supplies its own; the recording adapter here reports itself as :fake.
    it "sources the platform token from the origin adapter, not a hardcoded map" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.first.last.sender_label.platform).to eq("fake")
    end

    it "honours an adapter that overrides its origin label, as a homeserver would" do
      allow(adapter).to receive(:origin_label).and_return("matrix.org")
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.first.last.sender_label.platform).to eq("matrix.org")
    end

    # Core::SenderLabel prefixes the protocol qualifier onto the handle, so
    # Matrix, IRC and XMPP (each a bare domain) stay distinguishable.
    it "sources the protocol qualifier from the origin adapter when it supplies one" do
      allow(adapter).to receive(:origin_label).and_return("matrix.org")
      allow(adapter).to receive(:origin_protocol).and_return("matrix")
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi", author: author(username: "ada", first_name: nil)))
      label = adapter.delivered.first.last.sender_label
      expect(label.protocol).to eq("matrix")
      expect(label.to_s).to eq("matrix::ada@matrix.org")
    end

    it "defaults the protocol qualifier to nil for a centralized adapter" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.first.last.sender_label.protocol).to be_nil
    end

    it "keeps delivering after one target fails" do
      router = build_router(room("r", tg, dc, irc))
      adapter.fail_next(Rubotty::AdapterError.new("boom", adapter: :fake))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.size).to eq(1)
    end
  end

  describe "loop prevention" do
    it "drops a message authored by our own bot account" do
      router = build_router(room("r", tg, dc))
      mine = message(tg, text: "echo", author: author(native_id: "bot-1"))
      loop_guard.register_identity(:fake, "default", "bot-1")
      router.handle(mine)
      expect(adapter.delivered).to be_empty
    end

    it "drops a message the platform echoed back to us right after we wrote it" do
      router = build_router(room("r", tg, dc))
      loop_guard.note_delivery("tg", "77")
      router.handle(message(tg, text: "echo", native_id: "77"))
      expect(adapter.delivered).to be_empty
    end

    it "drops a message that the durable map already knows we wrote" do
      router = build_router(room("r", tg, dc))
      storage.record(source: ref("dc", "1"), destination: ref("tg", "88"), room_id: "r")
      router.handle(message(tg, text: "echo", native_id: "88"))
      expect(adapter.delivered).to be_empty
    end

    it "does not drop a genuine message from another user" do
      router = build_router(room("r", tg, dc))
      loop_guard.register_identity(:fake, "default", "bot-1")
      router.handle(message(tg, text: "hi", author: author(native_id: "u9")))
      expect(adapter.delivered.size).to eq(1)
    end

    # A shared endpoint would otherwise be reached twice and amplify without bound.
    it "refuses to visit the same endpoint twice in one routing operation" do
      shared = endpoint("shared")
      router = build_router(room("r1", tg, shared), room("r2", tg, shared))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.size).to eq(1)
    end
  end

  describe "the message map" do
    it "records what it delivered so edits can find it later" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi", native_id: "5"))
      expect(storage.counterparts(ref("tg", "5"))).to eq([ref("dc", "d1")])
    end

    it "sets an expiry from the configured TTL" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi", native_id: "5"))
      expect(storage.size).to eq(1)
      # The relay also writes an exactly-once claim on the same TTL, so the purge
      # clears that as well as the map row.
      expect(storage.purge(now: Time.now + 7200)).to be >= 1
      expect(storage.size).to eq(0)
    end
  end

  describe "edits" do
    it "edits every copy it made" do
      router = build_router(room("r", tg, dc, irc))
      router.handle(message(tg, text: "hi", native_id: "5"))
      router.handle(message(tg, text: "fixed", native_id: "5", kind: :edit))
      expect(adapter.edited.map { |(id, native, _)| [id, native] })
        .to contain_exactly(%w[dc d1], %w[irc d2])
    end

    it "ignores an edit for a message it never relayed" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "fixed", native_id: "999", kind: :edit))
      expect(adapter.edited).to be_empty
    end
  end

  describe "deletes" do
    it "deletes every copy it made" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi", native_id: "5"))
      router.handle(message(tg, text: "", native_id: "5", kind: :delete))
      expect(adapter.deleted).to eq([%w[dc d1]])
    end

    it "forgets the mapping afterwards" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi", native_id: "5"))
      router.handle(message(tg, text: "", native_id: "5", kind: :delete))
      expect(storage.counterparts(ref("tg", "5"))).to be_empty
    end
  end

  describe "replies" do
    it "translates a reply pointer into the target's id space" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "parent", native_id: "1"))
      router.handle(message(tg, text: "child", native_id: "2", reply_to: ref("tg", "1")))
      child = adapter.delivered.last.last
      expect(child.reply_to).to eq(ref("dc", "d1"))
    end

    it "leaves the pointer untranslated when the parent was never relayed" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "child", native_id: "2", reply_to: ref("tg", "404")))
      child = adapter.delivered.last.last
      # Still the parent on its own endpoint, so the adapter can tell "not a
      # reply" apart from "reply we cannot express natively".
      expect(child.reply_to).to eq(ref("tg", "404"))
    end

    it "leaves reply_to nil when the message was not a reply" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "hi"))
      expect(adapter.delivered.last.last.reply_to).to be_nil
    end
  end

  describe "relay policies" do
    it "does not relay joins from an endpoint that has them disabled" do
      quiet = endpoint("quiet", relay: { join_messages: false })
      router = build_router(room("r", quiet, dc))
      router.handle(message(quiet, text: "", kind: :join))
      expect(adapter.delivered).to be_empty
    end

    it "does not relay joins to an endpoint that has them disabled" do
      quiet = endpoint("quiet", relay: { join_messages: false })
      router = build_router(room("r", tg, quiet))
      router.handle(message(tg, text: "", kind: :join))
      expect(adapter.delivered).to be_empty
    end

    it "relays joins when nothing disables them" do
      router = build_router(room("r", tg, dc))
      router.handle(message(tg, text: "", kind: :join))
      expect(adapter.delivered.size).to eq(1)
    end
  end
end
