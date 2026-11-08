# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Directory do
  let(:alex) do
    Rubotty::Core::Person.new(
      name: "Alex",
      identities: { telegram: ["55"], discord: ["900"], matrix: ["@alex:example.org"] },
      handles: { telegram: ["alex"], discord: ["mattsz"] }
    )
  end
  let(:sam) do
    Rubotty::Core::Person.new(name: "Sam", identities: { telegram: ["66"] })
  end

  subject(:directory) { described_class.new([alex, sam]) }

  it "finds a person by their id on either platform" do
    expect(directory.by_identity(:telegram, "55")).to eq(alex)
    expect(directory.by_identity(:discord, "900")).to eq(alex)
  end

  it "finds a person by handle, which is all a Telegram mention carries" do
    expect(directory.by_handle(:telegram, "alex")).to eq(alex)
  end

  it "matches a handle case insensitively and ignores a leading at sign" do
    expect(directory.by_handle(:telegram, "@ALEX")).to eq(alex)
  end

  it "does not match an id belonging to another platform" do
    expect(directory.by_identity(:discord, "55")).to be_nil
  end

  it "returns nothing for an unknown person" do
    expect(directory.by_identity(:telegram, "999")).to be_nil
    expect(directory.by_handle(:telegram, "nobody")).to be_nil
  end

  it "reports the id a person has on a given platform" do
    expect(alex.id_on(:discord)).to eq("900")
    expect(sam.id_on(:discord)).to be_nil
  end

  describe "#resolve_mention" do
    it "resolves a Telegram text_mention, which carries a user id" do
      expect(directory.resolve_mention(tg_user_id: "55")).to eq(alex)
    end

    it "resolves a Telegram @handle mention, which carries only a name" do
      expect(directory.resolve_mention(username: "alex")).to eq(alex)
    end

    it "resolves a Discord mention by id" do
      expect(directory.resolve_mention(discord_id: "900")).to eq(alex)
    end

    it "resolves a Matrix mention by its MXID" do
      expect(directory.resolve_mention(matrix_id: "@alex:example.org")).to eq(alex)
    end

    it "returns nothing when nobody matches" do
      expect(directory.resolve_mention(username: "stranger")).to be_nil
      expect(directory.resolve_mention(nil)).to be_nil
    end
  end
end

RSpec.describe "mention resolution through the router" do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new }
  let(:alex) do
    Rubotty::Core::Person.new(
      name: "Alex", identities: { telegram: ["55"], discord: ["900"] },
      handles: { telegram: ["alex"] }
    )
  end

  def route(body, people: [alex])
    router = Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      people: Rubotty::Core::Directory.new(people)
    )
    router.handle(message(tg, text: body))
    adapter.delivered.last.last.body
  end

  it "annotates a mention with the target platform's id for that person" do
    body = rich("hi Alex", span(:mention, 3, 7, tg_user_id: "55"))
    delivered = route(body)
    expect(delivered.spans.first.attributes[:discord_id_for_target]).to eq("900")
  end

  it "resolves a bare handle, which is all Telegram gives for @mentions" do
    body = rich("hi @alex", span(:mention, 3, 8, username: "alex"))
    expect(route(body).spans.first.attributes[:discord_id_for_target]).to eq("900")
  end

  # Somebody who is not on the other platform should still read correctly.
  it "leaves an unresolvable mention untouched" do
    body = rich("hi @stranger", span(:mention, 3, 12, username: "stranger"))
    delivered = route(body)
    expect(delivered.spans.first.attributes).not_to have_key(:discord_id_for_target)
    expect(delivered.text).to eq("hi @stranger")
  end

  it "does nothing when no people are configured" do
    body = rich("hi Alex", span(:mention, 3, 7, tg_user_id: "55"))
    expect(route(body, people: []).spans.first.attributes).not_to have_key(:discord_id_for_target)
  end

  it "leaves ordinary formatting alone" do
    body = rich("bold text", span(:bold, 0, 4))
    expect(route(body).spans.map(&:kind)).to eq([:bold])
  end

  # Bug B: annotating the span with an id was never enough, since nothing
  # rewrote the TEXT, so a mention crossing to Telegram kept showing whatever
  # the origin adapter captured. Alex has no configured Telegram display name,
  # so the target's own bare "username@platform" is what should show.
  it "rewrites the mention TEXT to the target's own identity, not what the origin captured" do
    body = rich("hi Alex", span(:mention, 3, 7, discord_id: "900"))
    router = Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      people: Rubotty::Core::Directory.new([alex])
    )
    router.handle(message(dc, text: body))
    delivered = adapter.delivered.last.last.body

    expect(Rubotty::Rendering::TelegramHtml.new.render(delivered))
      .to eq(%(hi <a href="tg://user?id=55">alex@telegram</a>))
  end
end

RSpec.describe "mention resolution through the router, into and out of Matrix" do
  let(:mx) { endpoint("mx", adapter: :matrix) }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new }
  let(:alex) do
    Rubotty::Core::Person.new(
      name: "Alex", identities: { matrix: ["@alex:example.org"], discord: ["900"] }
    )
  end

  def route(origin, body)
    router = Rubotty::Core::Router.new(
      topology: topology(room("r", mx, dc)),
      adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      people: Rubotty::Core::Directory.new([alex])
    )
    router.handle(message(origin, text: body))
    adapter.delivered.last.last.body
  end

  it "resolves a Matrix-typed mention (a pill) into a real Discord ping" do
    body = rich("hi Alex", span(:mention, 3, 7, matrix_id: "@alex:example.org", username: "alex"))
    delivered = route(mx, body)
    expect(delivered.spans.first.attributes[:discord_id_for_target]).to eq("900")
    expect(Rubotty::Rendering::DiscordMarkdown.new.render(delivered)).to eq("hi <@900>")
  end

  it "resolves a Discord mention into a real, pinging Matrix pill plus m.mentions" do
    body = rich("hi Alex", span(:mention, 3, 7, discord_id: "900"))
    delivered = route(dc, body)
    expect(delivered.spans.first.attributes[:matrix_id_for_target]).to eq("@alex:example.org")

    content = Rubotty::Adapters::Matrix::Outbound.new.send_content(message(mx, text: delivered), mx)
    expect(content["m.mentions"]).to eq({ "user_ids" => ["@alex:example.org"] })
    expect(content["formatted_body"]).to include(%(href="https://matrix.to/#/@alex:example.org"))
  end
end

RSpec.describe "rendering a resolved mention" do
  it "produces a real Discord ping" do
    body = rich("hi Alex", span(:mention, 3, 7, discord_id_for_target: "900"))
    expect(Rubotty::Rendering::DiscordMarkdown.new.render(body)).to eq("hi <@900>")
  end

  it "leaves an unresolved mention as readable text on Discord" do
    body = rich("hi Alex", span(:mention, 3, 7, username: "alex"))
    expect(Rubotty::Rendering::DiscordMarkdown.new.render(body)).to eq("hi Alex")
  end

  # By the time a mention's span reaches the renderer, the bridge has already
  # rewritten its text to the target's own identity (see
  # Features::Bridge#resolve_mentions), never what a Telegram reader should
  # see. TelegramHtml's only job here is to wrap whatever text the span carries.
  it "produces a real Telegram ping" do
    label = "Alex [mattsz@telegram]"
    body = rich("hi #{label}", span(:mention, 3, 3 + label.length, telegram_id_for_target: "55"))
    expect(Rubotty::Rendering::TelegramHtml.new.render(body))
      .to eq(%(hi <a href="tg://user?id=55">#{label}</a>))
  end

  # Same "the bridge already rewrote the text" contract as Telegram, above:
  # Matrix::Html only wraps whatever text the span already carries.
  it "produces a real, pinging Matrix pill" do
    label = "Alex [alex@example.org]"
    body = rich("hi #{label}", span(:mention, 3, 3 + label.length, matrix_id_for_target: "@alex:example.org"))
    expect(Rubotty::Adapters::Matrix::Html.new.render(body))
      .to eq(%(hi <a href="https://matrix.to/#/@alex:example.org">#{label}</a>))
  end

  # A regression guard against reintroducing something like the old
  # suffix-trimming hack: a label the bridge built out of Core::SenderLabel
  # legitimately contains an "@" of its own (the bare "username@platform"
  # fallback), and the renderer must wrap it whole, not trim the suffix.
  it "wraps a bare username@platform label whole, @ and all" do
    label = "ada@telegram"
    body = rich("hey #{label}", span(:mention, 4, 4 + label.length, telegram_id_for_target: "123"))
    expect(Rubotty::Rendering::TelegramHtml.new.render(body))
      .to eq(%(hey <a href="tg://user?id=123">#{label}</a>))
  end

  it "keeps other formatting intact around a rewritten Discord mention" do
    body = rich("hi Alex now", span(:mention, 3, 7, discord_id_for_target: "900"),
                span(:bold, 8, 11))
    expect(Rubotty::Rendering::DiscordMarkdown.new.render(body)).to eq("hi <@900> **now**")
  end
end

RSpec.describe Rubotty::Core::RichText, "#splice" do
  it "replaces a range and shifts later spans" do
    text = rich("hi Alex now", span(:bold, 8, 11))
    spliced = text.splice([[(3...7), "<@900>"]])
    expect(spliced.text).to eq("hi <@900> now")
    expect(spliced.text[spliced.spans.first.begin_index...spliced.spans.first.end_index]).to eq("now")
  end

  it "leaves earlier spans where they were" do
    text = rich("bold hi Alex", span(:bold, 0, 4))
    spliced = text.splice([[(8...12), "<@1>"]])
    expect(spliced.spans.first.begin_index).to eq(0)
    expect(spliced.spans.first.end_index).to eq(4)
  end

  it "drops a span whose text was replaced underneath it" do
    text = rich("hi Alex", span(:mention, 3, 7))
    expect(text.splice([[(3...7), "<@900>"]]).spans).to be_empty
  end

  it "applies several edits in one pass" do
    text = rich("a X b Y c")
    spliced = text.splice([[(2...3), "<@1>"], [(6...7), "<@2>"]])
    expect(spliced.text).to eq("a <@1> b <@2> c")
  end

  it "returns itself when there is nothing to do" do
    text = rich("unchanged")
    expect(text.splice([])).to equal(text)
  end
end
