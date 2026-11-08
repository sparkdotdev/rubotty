# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Irc::Protocol do
  describe ".parse" do
    it "pulls the nick, command, target and trailing text from a PRIVMSG" do
      line = described_class.parse(":ada!user@host PRIVMSG #room :hello world\r\n")
      expect(line.nick).to eq("ada")
      expect(line.command).to eq("PRIVMSG")
      expect(line.target).to eq("#room")
      expect(line.trailing).to eq("hello world")
      expect(line).to be_channel
    end

    it "recognises a server PING with no prefix" do
      line = described_class.parse("PING :irc.example.org")
      expect(line.command).to eq("PING")
      expect(line.trailing).to eq("irc.example.org")
    end

    it "reads a numeric welcome" do
      line = described_class.parse(":irc.example.org 001 rubotty :Welcome")
      expect(line.command).to eq("001")
    end

    it "does not treat a private message as a channel" do
      line = described_class.parse(":ada!u@h PRIVMSG rubotty :hi")
      expect(line).not_to be_channel
    end
  end

  describe ".join_failure" do
    it "gives a clear reason for an invite only channel (issue #205)" do
      line = described_class.parse(":irc.example.org 473 rubotty #ops :Cannot join channel (+i)")
      expect(described_class.join_failure(line)).to eq(
        "IRC could not join #ops: invite only (+i); the bot needs an invite, or an op to /invite it"
      )
    end

    it "gives a clear reason for a wrong or missing channel key" do
      line = described_class.parse(":irc.example.org 475 rubotty #ops :Cannot join channel (+k)")
      expect(described_class.join_failure(line)).to include("#ops").and include("channel key (+k)")
    end

    it "gives a clear reason for a ban" do
      line = described_class.parse(":irc.example.org 474 rubotty #ops :Cannot join channel (+b)")
      expect(described_class.join_failure(line)).to include("banned")
    end

    it "gives a clear reason for a full channel" do
      line = described_class.parse(":irc.example.org 471 rubotty #ops :Cannot join channel (+l)")
      expect(described_class.join_failure(line)).to include("full")
    end

    it "is nil for a numeric that is not a join failure" do
      line = described_class.parse(":irc.example.org 001 rubotty :Welcome")
      expect(described_class.join_failure(line)).to be_nil
    end
  end

  describe ".parse with IRCv3 message tags (issue #220)" do
    it "has no tags at all on a plain line, an empty Hash rather than nil" do
      line = described_class.parse(":ada!u@h PRIVMSG #room :hi")
      expect(line.tags).to eq({})
      expect(line.tag("msgid")).to be_nil
    end

    it "parses a tags prefix ahead of the source prefix" do
      line = described_class.parse("@msgid=123;+draft/reply=9 :ada!u@h PRIVMSG #room :sure")
      expect(line.tags).to eq("msgid" => "123", "+draft/reply" => "9")
      expect(line.tag("msgid")).to eq("123")
      expect(line.command).to eq("PRIVMSG")
      expect(line.trailing).to eq("sure")
    end

    it "gives a tag with no '=value' the boolean value true" do
      line = described_class.parse("@+typing :ada!u@h TAGMSG #room")
      expect(line.tag("+typing")).to be(true)
    end

    it "unescapes semicolon, space, backslash, CR and LF in a tag value" do
      line = described_class.parse('@note=one\:two\sthree\\\\four\r\nfive :ada!u@h TAGMSG #room')
      expect(line.tag("note")).to eq("one;two three\\four\r\nfive")
    end

    it "drops the backslash of an escape sequence it does not recognise" do
      line = described_class.parse('@note=a\zb :ada!u@h TAGMSG #room')
      expect(line.tag("note")).to eq("azb")
    end

    it "drops a trailing lone backslash rather than raising" do
      line = described_class.parse('@note=abc\ :ada!u@h TAGMSG #room')
      expect(line.tag("note")).to eq("abc")
    end

    it "parses server-time's ISO8601 'time' tag" do
      line = described_class.parse("@time=2011-10-19T16:40:51.620Z :ada!u@h PRIVMSG #room :hi")
      expect(line.tag("time")).to eq("2011-10-19T16:40:51.620Z")
    end
  end

  describe ".escape_tag_value / .unescape_tag_value" do
    it "round trips a value containing every special character" do
      value = "semi;colon space\\backslash\r\n"
      expect(described_class.unescape_tag_value(described_class.escape_tag_value(value))).to eq(value)
    end

    it "escapes semicolon and space, which would otherwise corrupt the tag list" do
      expect(described_class.escape_tag_value("a;b c")).to eq('a\:b\sc')
    end
  end

  describe ".parse_cap_list" do
    it "parses a plain list of capability names with no values" do
      expect(described_class.parse_cap_list("message-tags server-time msgid")).to eq(
        "message-tags" => nil, "server-time" => nil, "msgid" => nil
      )
    end

    it "captures a capability's advertised value, e.g. sasl's mechanism list" do
      expect(described_class.parse_cap_list("sasl=PLAIN,EXTERNAL server-time")).to eq(
        "sasl" => "PLAIN,EXTERNAL", "server-time" => nil
      )
    end

    it "is empty for a blank or nil list" do
      expect(described_class.parse_cap_list(nil)).to eq({})
      expect(described_class.parse_cap_list("")).to eq({})
    end
  end

  describe ".cap_continuation?" do
    it "is true when a '*' follows the LS subcommand: more pages are coming" do
      line = described_class.parse(":irc.example.org CAP * LS * :multi-prefix extended-join")
      expect(described_class).to be_cap_continuation(line)
    end

    it "is false on the final (or only) page" do
      line = described_class.parse(":irc.example.org CAP * LS :away-notify chghost")
      expect(described_class).not_to be_cap_continuation(line)
    end
  end

  describe ".strip_ctcp" do
    it "recognises a CTCP ACTION" do
      text, action = described_class.strip_ctcp("\x01ACTION waves\x01")
      expect(text).to eq("waves")
      expect(action).to be(true)
    end

    it "leaves ordinary text alone" do
      text, action = described_class.strip_ctcp("just talking")
      expect(text).to eq("just talking")
      expect(action).to be(false)
    end
  end

  describe ".split_message" do
    it "turns hard newlines into separate lines" do
      expect(described_class.split_message("one\ntwo")).to eq(%w[one two])
    end

    it "wraps an over long line on a space boundary" do
      words = (["word"] * 200).join(" ")
      lines = described_class.split_message(words)
      expect(lines.size).to be > 1
      expect(lines.all? { |line| line.bytesize <= described_class::MAX_MESSAGE_BYTES }).to be(true)
      expect(lines.join(" ")).to eq(words)
    end

    it "splits a single over long token without tearing a multibyte character" do
      token = "é" * 400
      lines = described_class.split_message(token)
      expect(lines.size).to be > 1
      expect(lines.all? { |line| line.bytesize <= described_class::MAX_MESSAGE_BYTES }).to be(true)
      expect(lines.join).to eq(token)
      expect(lines.all? { |line| line.force_encoding("UTF-8").valid_encoding? }).to be(true)
    end

    it "drops empty lines produced by blank input" do
      expect(described_class.split_message("")).to eq([])
    end
  end
end
