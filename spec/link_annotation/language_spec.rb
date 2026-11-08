# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::LinkAnnotation::Language do
  describe ".declared" do
    it "reads the publisher's own lang attribute, which is the signal to trust" do
      expect(described_class.declared('<html lang="de"><body>x</body></html>')).to eq("de")
    end

    it "reduces a regional tag to the language, since both need the same translation" do
      expect(described_class.declared('<html lang="pt-BR">')).to eq("pt")
      expect(described_class.declared('<html lang="zh-Hans-CN">')).to eq("zh")
    end

    it "falls through the other spellings of the same declaration" do
      expect(described_class.declared('<html xml:lang="fr">')).to eq("fr")
      expect(described_class.declared(
               '<meta http-equiv="content-language" content="it">'
             )).to eq("it")
      expect(described_class.declared('<meta property="og:locale" content="nl_NL">')).to eq("nl")
    end

    it "treats a placeholder declaration as no declaration at all" do
      expect(described_class.declared('<html lang="x-default">')).to be_nil
      expect(described_class.declared('<html lang="und">')).to be_nil
      expect(described_class.declared('<html lang="">')).to be_nil
    end

    it "is nil when nothing was declared" do
      expect(described_class.declared("<html><body>hello</body></html>")).to be_nil
    end
  end

  describe ".from_text" do
    def paragraph(text) = ([text] * 12).join(" ")

    it "reads German from its function words" do
      german = paragraph("Der Bericht ist nicht vollstaendig und die Sprecherin hat sich auch " \
                         "nicht dazu geaeussert, denn eine Entscheidung werden sie erst mit dem " \
                         "neuen Jahr auf den Weg bringen")

      expect(described_class.from_text(german)).to eq("de")
    end

    it "reads French from its function words" do
      french = paragraph("Les responsables des services ont indique dans une note que la mesure " \
                         "qui devait entrer en vigueur pour tous les habitants ne sera pas " \
                         "appliquee avec la meme rigueur sur plus de dix communes mais")

      expect(described_class.from_text(french)).to eq("fr")
    end

    it "reads a single-language script without counting a word" do
      japanese = "これは日本語の文章です。" * 40

      expect(described_class.from_text(japanese)).to eq("ja")
    end

    it "picks within Cyrillic rather than assuming Russian" do
      ukrainian = ([
        "Вони повідомили що це рішення для всіх мешканців було також ухвалене після його заяви але вона"
      ] * 12).join(" ")

      expect(described_class.from_text(ukrainian)).to eq("uk")
    end

    it "says nothing rather than guessing at a page with no prose on it" do
      expect(described_class.from_text("Home About Contact")).to be_nil
      expect(described_class.from_text("")).to be_nil
    end

    # The whole point of the margin: a coin toss comes back as no answer, and no
    # answer means the room hears nothing.
    it "says nothing when two languages score alike" do
      expect(described_class.from_text(("lorem ipsum dolor sit amet consectetur " * 40).to_s)).to be_nil
    end
  end

  describe ".normalise" do
    it "accepts a code and rejects anything that is not one" do
      expect(described_class.normalise("EN_gb")).to eq("en")
      expect(described_class.normalise("javascript")).to be_nil
      expect(described_class.normalise("*")).to be_nil
      expect(described_class.normalise(nil)).to be_nil
    end
  end

  describe ".name" do
    it "names a language for the sentence posted back to the room" do
      expect(described_class.name("de")).to eq("German")
    end

    it "shows an unnamed code as itself rather than as nothing" do
      expect(described_class.name("yo")).to eq("yo")
    end
  end

  describe ".detect" do
    it "prefers the declaration over the body, even when the body disagrees" do
      html = '<html lang="de"><body>' + ("the and that with have this from they which " * 20) + "</body></html>"

      expect(described_class.detect(html, text: "the and that with have this from they which " * 20)).to eq("de")
    end
  end
end
