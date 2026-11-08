# frozen_string_literal: true

require "spec_helper"

# Telegram entity offsets are UTF-16 code units; Ruby indexes strings by
# character. The two agree for ASCII and the whole Basic Multilingual Plane
# but disagree by one position per astral character. Any bug here is
# invisible in English prose and corrupts every message with an emoji, most of them in a chat bridge.
RSpec.describe Rubotty::Util::Utf16 do
  subject(:utf16) { described_class }

  # Deliberately awkward fixtures.
  ASCII = "hello world"
  ACCENTED = "héllo wörld"              # BMP, one code unit per character
  CJK = "日本語のテキスト"                  # BMP, one code unit per character
  EMOJI = "🎉 party time"                # U+1F389, TWO code units
  MULTI_EMOJI = "🎉🎊 double 🎈 trouble"  # three astral characters
  FLAG = "🇬🇧 united"                    # two regional indicators, four units
  FAMILY = "👨‍👩‍👧‍👦 family"                  # four astral plus three ZWJ
  SKIN_TONE = "👋🏽 wave"                  # astral plus astral modifier

  describe ".length" do
    it "matches character length for ASCII" do
      expect(utf16.length(ASCII)).to eq(ASCII.length)
    end

    it "matches character length for accented Latin and CJK, which are all BMP" do
      expect(utf16.length(ACCENTED)).to eq(ACCENTED.length)
      expect(utf16.length(CJK)).to eq(CJK.length)
    end

    it "counts an astral character as two code units" do
      expect(EMOJI.length).to eq(12)
      expect(utf16.length(EMOJI)).to eq(13)
    end

    it "counts a regional indicator flag as four code units" do
      expect(FLAG.length).to eq(9)
      expect(utf16.length(FLAG)).to eq(11)
    end

    it "counts a ZWJ sequence per component" do
      # 4 astral characters (8 units) + 3 ZWJ (3 units) + " family" (7 units)
      expect(utf16.length(FAMILY)).to eq(18)
    end

    it "returns zero for nil and empty" do
      expect(utf16.length(nil)).to eq(0)
      expect(utf16.length("")).to eq(0)
    end
  end

  describe ".boundaries" do
    it "has one more entry than the string has characters" do
      expect(utf16.boundaries(EMOJI).length).to eq(EMOJI.length + 1)
    end

    it "is the identity for BMP only text" do
      expect(utf16.boundaries(ACCENTED)).to eq((0..ACCENTED.length).to_a)
    end

    it "steps by two across an astral character" do
      expect(utf16.boundaries(EMOJI).first(4)).to eq([0, 2, 3, 4])
    end

    it "ends at the total UTF-16 length" do
      expect(utf16.boundaries(FAMILY).last).to eq(utf16.length(FAMILY))
    end
  end

  describe ".char_index" do
    it "is the identity for BMP only text" do
      table = utf16.boundaries(ACCENTED)
      (0..ACCENTED.length).each do |index|
        expect(utf16.char_index(index, table)).to eq(index)
      end
    end

    it "maps a post emoji offset back by the accumulated surrogate count" do
      table = utf16.boundaries(EMOJI)
      # "party" begins at character 2 but at UTF-16 offset 3.
      expect(EMOJI[2, 5]).to eq("party")
      expect(utf16.char_index(3, table)).to eq(2)
    end

    it "accumulates across several astral characters" do
      table = utf16.boundaries(MULTI_EMOJI)
      # "trouble" is at character index 12; Telegram would report offset 15,
      # because three astral characters precede it.
      expect(MULTI_EMOJI[12, 7]).to eq("trouble")
      expect(utf16.char_index(15, table)).to eq(12)
    end

    it "snaps down when an offset falls inside a surrogate pair" do
      table = utf16.boundaries(EMOJI)
      # Offset 1 is the low surrogate of the party popper. There is no
      # character there, so it resolves to the character containing it.
      expect(utf16.char_index(1, table)).to eq(0)
    end

    it "clamps offsets outside the string" do
      table = utf16.boundaries(EMOJI)
      expect(utf16.char_index(-5, table)).to eq(0)
      expect(utf16.char_index(9_999, table)).to eq(EMOJI.length)
    end
  end

  describe ".unit_offset" do
    it "round trips with char_index for every character boundary" do
      [ASCII, ACCENTED, CJK, EMOJI, MULTI_EMOJI, FLAG, FAMILY, SKIN_TONE].each do |text|
        table = utf16.boundaries(text)
        (0..text.length).each do |index|
          expect(utf16.char_index(utf16.unit_offset(index, table), table)).to eq(index)
        end
      end
    end
  end

  describe ".slice" do
    it "extracts what Telegram meant, not what naive slicing gives" do
      # Telegram would describe "party" in "🎉 party time" as offset 3 length 5.
      expect(utf16.slice(EMOJI, 3, 5)).to eq("party")
      # The naive version silently produces the wrong text.
      expect(EMOJI[3, 5]).to eq("arty ")
    end

    it "extracts an astral character itself" do
      expect(utf16.slice(EMOJI, 0, 2)).to eq("🎉")
    end

    it "handles offsets after several astral characters" do
      expect(utf16.slice(MULTI_EMOJI, 15, 7)).to eq("trouble")
    end

    it "returns empty for a non positive length" do
      expect(utf16.slice(EMOJI, 0, 0)).to eq("")
      expect(utf16.slice(nil, 0, 4)).to eq("")
    end

    it "does not blow up when a slice severs a surrogate pair" do
      expect { utf16.slice(EMOJI, 1, 3) }.not_to raise_error
    end
  end
end
