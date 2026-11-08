# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Telegram::Outbound do
  subject(:outbound) { described_class.new }

  # Pins the current boundary table and binary search against a verbatim copy of
  # the older O(n^2) loop, so the speed up cannot have moved where the cut lands.
  describe "#clamp preserves the exact truncation of the original algorithm" do
    # A verbatim copy of the pre optimisation logic, kept here as the oracle.
    def old_clamp(html, limit)
      return html if Rubotty::Util::Utf16.length(html) <= limit

      budget = limit - 1
      cut = html.length
      cut -= 1 while cut.positive? && Rubotty::Util::Utf16.length(html[0, cut]) > budget
      truncated = html[0, cut].to_s

      last_open = truncated.rindex("<")
      last_close = truncated.rindex(">")
      truncated = truncated[0, last_open].to_s if last_open && (last_close.nil? || last_open > last_close)

      old_close_dangling(truncated) + "…"
    end

    def old_close_dangling(html)
      open = []
      html.scan(%r{<(/?)([a-z-]+)[^>]*>}) do |slash, tag|
        if slash.empty?
          open << tag
        elsif open.last == tag
          open.pop
        end
      end
      html + open.reverse.map { |tag| "</#{tag}>" }.join
    end

    def clamp(html, limit)
      outbound.send(:clamp, html, limit)
    end

    it "returns a short string untouched" do
      expect(clamp("hello", 4096)).to eq(old_clamp("hello", 4096)).and eq("hello")
    end

    it "cuts a long ASCII run at the same character" do
      html = "x" * 5000
      expect(clamp(html, 100)).to eq(old_clamp(html, 100))
    end

    # Every emoji here is two UTF-16 code units, which is where a naive cut drifts.
    it "cuts through a run of astral characters at the same code unit" do
      html = ("a" * 10) + ("\u{1F600}" * 40) + ("b" * 10)
      (18..60).each do |limit|
        expect(clamp(html, limit)).to eq(old_clamp(html, limit)), "diverged at limit #{limit}"
      end
    end

    it "never cuts inside a tag and closes what it opened, identically" do
      html = "<b>#{"word " * 40}<i>#{"more " * 40}</i></b>"
      (10..120).each do |limit|
        expect(clamp(html, limit)).to eq(old_clamp(html, limit)), "diverged at limit #{limit}"
      end
    end

    it "matches on a mixed message at the caption and text limits" do
      html = "<b>hi</b> plain \u{1F680} " * 300
      [Rubotty::Adapters::Telegram::Outbound::CAPTION_LIMIT,
       Rubotty::Adapters::Telegram::Outbound::TEXT_LIMIT].each do |limit|
        expect(clamp(html, limit)).to eq(old_clamp(html, limit))
      end
    end

    # A budget rather than a property, since the old O(n^2) form took roughly a
    # second at this size and there is nowhere else for the ceiling to go.
    it "clamps a 20KB message quickly" do
      budget = 0.2
      html = "x" * 20_000
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      clamp(html, 4096)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < budget,
                         "clamping 20KB took #{elapsed.round(3)}s against a #{budget}s budget: " \
                         "either the quadratic form is back, or this box is loaded"
    end
  end

  # The bridge decides when the notice applies and builds the sentence; the
  # composer only renders it.
  describe "the thread notice" do
    let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100" }) }

    it "renders the bridge-built notice as an italic line under the body" do
      msg = message(place, text: "yes", thread_notice: 'replied inside the thread "bar"')
      rendered = outbound.compose(msg, place)
      expect(rendered).to include(%(yes\n<i>replied inside the thread "bar"</i>))
    end

    it "renders nothing when the bridge set no notice, the default" do
      expect(outbound.compose(message(place, text: "yes"), place)).not_to include("replied inside")
    end
  end

  # A poll card's ballot on Telegram, where no keycap can be tapped.
  describe "the inline keyboard" do
    let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100" }) }
    let(:logs) { StringIO.new }

    def button(token, label) = Rubotty::Core::Button.new(token: token, label: label)

    def carded(*buttons) = message(place, text: "Poll: which map?", buttons: buttons)

    it "sends one row per button, each carrying its own token as callback data" do
      _, params = outbound.send_calls(carded(button("poll-option:1", "1 Dust II"),
                                             button("poll-option:2", "2 Inferno")), place).first

      expect(params[:reply_markup]).to eq(
        inline_keyboard: [[{ text: "1 Dust II", callback_data: "poll-option:1" }],
                          [{ text: "2 Inferno", callback_data: "poll-option:2" }]]
      )
    end

    it "names no keyboard at all for an ordinary message" do
      _, params = outbound.send_calls(message(place, text: "hello"), place).first

      expect(params[:reply_markup]).to be_nil
    end

    # An edit naming no keyboard takes the buttons off the message, so a card
    # refreshed after a vote would lose its ballot.
    it "restates the keyboard on an edit" do
      _, params = outbound.edit_call(carded(button("poll-option:1", "1 Dust II")), place, "42")

      expect(params[:reply_markup]).to eq(
        inline_keyboard: [[{ text: "1 Dust II", callback_data: "poll-option:1" }]]
      )
    end

    # Telegram rejects the whole send over one oversized callback_data, which
    # would cost the room the card rather than one button.
    it "leaves out a button whose token is past the 64 byte limit, and says so" do
      wordy = described_class.new(logger: Rubotty::Log.build(level: "warn", io: logs))
      _, params = wordy.send_calls(carded(button("x" * 65, "Too long"),
                                          button("poll-option:2", "2 Inferno")), place).first

      expect(params[:reply_markup]).to eq(
        inline_keyboard: [[{ text: "2 Inferno", callback_data: "poll-option:2" }]]
      )
      expect(logs.string).to include("Too long")
    end
  end
end
