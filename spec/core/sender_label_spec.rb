# frozen_string_literal: true

require "spec_helper"

# The cross platform sender label, whose platform token is the ORIGIN platform's
# own identifier.
RSpec.describe Rubotty::Core::SenderLabel do
  # Stand ins for what a target platform contributes: escaping and bold.
  def render(label, bold: ->(t) { "<b>#{t}</b>" }, escape: ->(t) { t })
    label.render(escape: escape, bold: bold)
  end

  describe ".for" do
    it "takes the username, the origin platform, and the human display name" do
      author = Rubotty::Core::Author.new(username: "owner_handle", display_name: "River (Alex)")
      label = described_class.for(author: author, platform: "discord")
      expect(label.username).to eq("owner_handle")
      expect(label.platform).to eq("discord")
      expect(label.display_name).to eq("River (Alex)")
    end

    it "recovers a Telegram display name from first and last name" do
      author = Rubotty::Core::Author.new(username: "sample_owner", first_name: "Alex", last_name: "R")
      label = described_class.for(author: author, platform: "telegram")
      expect(label.display_name).to eq("Alex R")
    end

    it "carries an optional protocol qualifier through for a federated platform" do
      author = Rubotty::Core::Author.new(username: "alex")
      label = described_class.for(author: author, platform: "matrix.domain.com", protocol: "matrix")
      expect(label.protocol).to eq("matrix")
    end

    it "defaults the protocol to nil for a centralized platform" do
      author = Rubotty::Core::Author.new(username: "owner_handle")
      label = described_class.for(author: author, platform: "discord")
      expect(label.protocol).to be_nil
    end
  end

  describe "#render" do
    it "leads with the bold display name and brackets the username@platform handle" do
      label = described_class.new(username: "owner_handle", platform: "discord", display_name: "River (Alex)")
      expect(render(label)).to eq("<b>River (Alex)</b> [owner_handle@discord]")
    end

    it "generalises the platform token beyond the two built in platforms" do
      label = described_class.new(username: "ada", platform: "matrix.org", display_name: "Ada L")
      expect(render(label)).to eq("<b>Ada L</b> [ada@matrix.org]")
    end

    it "drops the bracket when there is no display name" do
      label = described_class.new(username: "ada", platform: "telegram")
      expect(render(label)).to eq("<b>ada</b>@telegram")
    end

    it "never repeats a display name that merely equals the handle" do
      label = described_class.new(username: "ada", platform: "discord", display_name: "ada")
      expect(render(label)).to eq("<b>ada</b>@discord")
    end

    it "puts the display name in the bold position when there is no username" do
      label = described_class.new(platform: "telegram", display_name: "Announcements")
      expect(render(label)).to eq("<b>Announcements</b>@telegram")
    end

    it "falls back to a last resort name when there is neither username nor display name" do
      label = described_class.new(platform: "telegram", name: "12345")
      expect(render(label)).to eq("<b>12345</b>@telegram")
    end

    it "renders nothing at all rather than a stray bold or bracket when empty" do
      expect(render(described_class.new(platform: "telegram"))).to eq("")
    end

    it "escapes every part it renders" do
      label = described_class.new(username: "a<b>", platform: "x&y", display_name: "d<e>")
      escape = Rubotty::Rendering::TelegramHtml.method(:escape)
      out = label.render(escape: escape, bold: ->(t) { "<b>#{t}</b>" })
      expect(out).to eq("<b>d&lt;e&gt;</b> [a&lt;b&gt;@x&amp;y]")
    end
  end

  # A federated platform token is a bare domain, so the "protocol::" prefix
  # disambiguates, always in plain text even when the identity itself is bold.
  describe "#render with a federated protocol qualifier" do
    it "prefixes the matrix handle, with the normalized MXID (no leading @, no colon before the domain)" do
      label = described_class.new(username: "alex", platform: "matrix.domain.com", protocol: "matrix")
      expect(render(label)).to eq("matrix::<b>alex</b>@matrix.domain.com")
      expect(label.to_s).to eq("matrix::alex@matrix.domain.com")
    end

    it "prefixes the irc handle with the network host as the domain" do
      label = described_class.new(username: "alex", platform: "irc.domain.com", protocol: "irc")
      expect(label.to_s).to eq("irc::alex@irc.domain.com")
    end

    it "prefixes the xmpp handle, the JID already being user@domain" do
      label = described_class.new(username: "alex", platform: "xmpp.domain.com", protocol: "xmpp")
      expect(label.to_s).to eq("xmpp::alex@xmpp.domain.com")
    end

    it "puts the qualifier ahead of the bracketed handle when there is a distinct display name" do
      label = described_class.new(username: "alex", platform: "matrix.domain.com", protocol: "matrix",
                                  display_name: "Alex R")
      expect(render(label)).to eq("<b>Alex R</b> [matrix::alex@matrix.domain.com]")
    end

    it "leaves the centralized shape unchanged when there is no protocol" do
      label = described_class.new(username: "owner_handle", platform: "discord", display_name: "River (Alex)")
      expect(label.protocol).to be_nil
      expect(render(label)).to eq("<b>River (Alex)</b> [owner_handle@discord]")
    end

    it "leaves the guest shape unchanged, guest never taking a protocol" do
      guest = described_class.guest(nickname: "Visiting Reviewer")
      expect(guest.protocol).to be_nil
      expect(render(guest)).to eq("<b>Visiting Reviewer</b>@guest-user")
    end
  end

  # A display name is member-controlled free text, so it must not be able to
  # forge the "protocol::handle@domain" shape and borrow a federated identity.
  describe "impersonation guard" do
    it "collapses a double colon in a display name so it cannot fake a qualifier" do
      label = described_class.new(
        username: "realhandle", platform: "telegram",
        display_name: "matrix::victim@matrix.domain.com"
      )
      expect(label.display_name).to eq("matrix:victim@matrix.domain.com")
      expect(render(label)).to eq("<b>matrix:victim@matrix.domain.com</b> [realhandle@telegram]")
    end

    it "collapses a double colon in a username the same way" do
      label = described_class.new(username: "matrix::alex", platform: "telegram")
      expect(label.username).to eq("matrix:alex")
      expect(render(label)).to eq("<b>matrix:alex</b>@telegram")
    end

    it "collapses a longer run of colons in one pass, not leaving a pair behind" do
      label = described_class.new(username: "matrix::::alex", platform: "telegram")
      expect(label.username).to eq("matrix:alex")
    end

    it "never lets a centralized member's free text alone produce a genuine federated shape" do
      # The real platform token still honestly follows, and the forged double
      # colon is gone.
      forged = described_class.new(
        username: "attacker", platform: "telegram", display_name: "xmpp::admin@xmpp.domain.com"
      )
      genuine = described_class.new(username: "admin", platform: "xmpp.domain.com", protocol: "xmpp")
      expect(forged.to_s).not_to eq(genuine.to_s)
      expect(forged.to_s).to eq("xmpp:admin@xmpp.domain.com [attacker@telegram]")
      expect(genuine.to_s).to eq("xmpp::admin@xmpp.domain.com")
    end
  end

  describe "#to_s" do
    it "is the plain text form with no markup, for out of band identity fields" do
      label = described_class.new(username: "owner_handle", platform: "discord", display_name: "River (Alex)")
      expect(label.to_s).to eq("River (Alex) [owner_handle@discord]")
    end
  end

  # The round trip below splits and rejoins every shape this class can render, so
  # a change the split does not follow fails here rather than in a browser.
  describe ".split" do
    it "bolds the handle when the handle is the identity" do
      expect(described_class.split("alex@telegram")).to eq(["", "alex", "@telegram"])
    end

    it "bolds the display name and leaves the bracketed handle plain" do
      expect(described_class.split("River (Alex) [owner_handle@discord]"))
        .to eq(["", "River (Alex)", " [owner_handle@discord]"])
    end

    it "keeps the protocol qualifier out of the bold, where render puts it" do
      expect(described_class.split("matrix::ada@example.org")).to eq(["matrix::", "ada", "@example.org"])
    end

    it "takes the whole thing when there is nothing to split" do
      expect(described_class.split("ada")).to eq(["", "ada", ""])
      expect(described_class.split("")).to eq(["", "", ""])
    end

    # Matching from the end is what stops a display name's own brackets and at
    # signs being read as the boundary.
    it "is not fooled by a display name carrying a bracket or an at sign" do
      expect(described_class.split("Alex [work] [alex@telegram]"))
        .to eq(["", "Alex [work]", " [alex@telegram]"])
      expect(described_class.split("alex@work@telegram")).to eq(["", "alex@work", "@telegram"])
    end

    it "rejoins to exactly what render produced, for every shape" do
      [
        described_class.new(username: "alex", platform: "telegram"),
        described_class.new(username: "owner_handle", platform: "discord", display_name: "River (Alex)"),
        described_class.new(username: "ada", platform: "example.org", protocol: "matrix"),
        described_class.new(username: "ada", platform: "example.org", display_name: "Ada L", protocol: "irc"),
        described_class.new(display_name: "Ada L", platform: "telegram"),
        described_class.new(name: "someone"),
        described_class.guest(nickname: "Visitor")
      ].each do |label|
        prefix, lead, rest = described_class.split(label.to_s)

        expect(prefix + lead + rest).to eq(label.to_s)
        expect(lead).to eq(label.render(escape: ->(t) { t }, bold: ->(t) { "\x00#{t}\x00" })[/\x00(.*?)\x00/, 1]),
                        "split disagrees with render about what is bold in #{label.to_s.inspect}"
      end
    end
  end

  # Shortened rather than left for the target platform to cut off mid handle.
  describe ".shorten" do
    it "leaves a label alone when it already fits" do
      expect(described_class.shorten("River (Alex) [owner_handle@discord]", 80))
        .to eq("River (Alex) [owner_handle@discord]")
    end

    it "eats into the display name and keeps the bracketed handle whole" do
      shortened = described_class.shorten("River (Alex) [owner_handle@discord]", 32)
      expect(shortened).to end_with(" [owner_handle@discord]")
      expect(shortened).to include("...")
      expect(shortened.length).to eq(32)
    end

    it "shortens the bare identity when there is no bracket to protect" do
      shortened = described_class.shorten("x" * 200, 80)
      expect(shortened).to eq("#{"x" * 77}...")
      expect(shortened.length).to eq(80)
    end

    it "keeps the protocol qualifier and the platform tag whole, shortening the lead between them" do
      shortened = described_class.shorten("matrix::#{"a" * 100}@example.org", 40)
      expect(shortened).to start_with("matrix::")
      expect(shortened).to end_with("@example.org")
      expect(shortened.length).to eq(40)
    end

    it "never introduces the single character ellipsis, only three literal dots" do
      shortened = described_class.shorten("x" * 200, 80)
      expect(shortened).not_to include("…")
      expect(shortened).to include("...")
    end
  end
end

RSpec.describe Rubotty::Core::Author, "#profile_name" do
  it "uses the platform display name when there is one" do
    author = described_class.new(username: "owner_handle", display_name: "River (Alex)")
    expect(author.profile_name).to eq("River (Alex)")
  end

  it "assembles a full name when there is no display name" do
    author = described_class.new(username: "alex", first_name: "Alex", last_name: "R")
    expect(author.profile_name).to eq("Alex R")
  end

  # Never the username: that already occupies the bold half of the label.
  it "is nil when the sender has no name distinct from their handle" do
    expect(described_class.new(username: "alex").profile_name).to be_nil
  end
end

# Through the REAL platform renderers, so per platform bold markup is pinned.
RSpec.describe "sender label rendering through the adapters" do
  let(:label) do
    Rubotty::Core::SenderLabel.new(username: "owner_handle", platform: "discord", display_name: "River (Alex)")
  end

  describe "Telegram" do
    subject(:outbound) { Rubotty::Adapters::Telegram::Outbound.new }

    let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "1" }) }

    it "leads with the bold display name in Telegram HTML" do
      msg = message(place, text: "hi").with(sender_label: label)
      expect(outbound.compose(msg, place)).to start_with("<b>River (Alex)</b> [owner_handle@discord]:\n")
    end
  end

  describe "Discord" do
    subject(:outbound) { Rubotty::Adapters::Discord::Outbound.new }

    let(:place) { endpoint("dc", adapter: :discord, settings: { channel_id: "1" }) }

    it "leads with the bold display name in Discord markdown" do
      msg = message(place, text: "hi").with(sender_label: label)
      expect(outbound.compose(msg, place)).to start_with("**River (Alex)** [owner\\_handle@discord]:\n")
    end

    it "carries the plain text label as a webhook has no in text prefix" do
      # The value object's to_s is what the webhook username uses.
      expect(label.to_s).to eq("River (Alex) [owner_handle@discord]")
    end
  end

  describe "a name somebody chose to be bridged as" do
    def nickname_label(**overrides)
      Rubotty::Core::SenderLabel.nickname(
        **{ nickname: "River", platform: "telegram", username: "sample_owner" }.merge(overrides)
      )
    end

    it "leads with the chosen name and keeps the handle it belongs to" do
      expect(nickname_label.to_s).to eq("River [sample_owner@telegram]")
    end

    it "keeps an emoji in the chosen name" do
      expect(nickname_label(nickname: "River 🇵🇹").to_s).to eq("River 🇵🇹 [sample_owner@telegram]")
    end

    it "carries the protocol qualifier on the handle, never on the chosen name" do
      expect(nickname_label(platform: "example.org", username: "ada", protocol: "matrix").to_s)
        .to eq("River [matrix::ada@example.org]")
    end

    # An account with no handle has nothing to attribute the name to, so the
    # platform follows the name itself rather than an empty bracket.
    it "falls back to the platform when there is no handle" do
      expect(nickname_label(username: nil).to_s).to eq("River@telegram")
    end

    it "does not repeat a chosen name that is already the handle" do
      expect(nickname_label(nickname: "ada", username: "ada").to_s).to eq("ada@telegram")
    end
  end
end
