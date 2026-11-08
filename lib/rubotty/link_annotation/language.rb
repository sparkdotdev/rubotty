# frozen_string_literal: true

module Rubotty
  module LinkAnnotation
    # What language a page is in, and what to call it in a sentence. The
    # domain is never consulted, since country code TLDs measure badly
    # against page language (.in is 97 percent English pages, .pk 99).
    # Signals are trusted in order: the +lang+ attribute on <html>, then its
    # other spellings (xml:lang, content-language, og:locale), then the body
    # text by script and function words; nil when the text pass is not
    # confident, since a link into the wrong language is worse than no link.
    module Language
      # Values that appear in a lang attribute and declare nothing.
      GENERIC = %w[x-default und mul zxx qaa].freeze

      # Enough of a name to put in a sentence. A code with no entry is shown raw.
      NAMES = {
        "ar" => "Arabic", "bg" => "Bulgarian", "ca" => "Catalan", "cs" => "Czech",
        "da" => "Danish", "de" => "German", "el" => "Greek", "en" => "English",
        "es" => "Spanish", "et" => "Estonian", "fa" => "Persian", "fi" => "Finnish",
        "fr" => "French", "he" => "Hebrew", "hi" => "Hindi", "hr" => "Croatian",
        "hu" => "Hungarian", "id" => "Indonesian", "is" => "Icelandic", "it" => "Italian",
        "ja" => "Japanese", "ko" => "Korean", "lt" => "Lithuanian", "lv" => "Latvian",
        "nl" => "Dutch", "no" => "Norwegian", "pl" => "Polish", "pt" => "Portuguese",
        "ro" => "Romanian", "ru" => "Russian", "sk" => "Slovak", "sl" => "Slovenian",
        "sr" => "Serbian", "sv" => "Swedish", "th" => "Thai", "tr" => "Turkish",
        "uk" => "Ukrainian", "vi" => "Vietnamese", "zh" => "Chinese"
      }.freeze

      # Scripts only one language of interest is written in, checked before the
      # word lists.
      SCRIPTS = {
        "ja" => /[\p{Hiragana}\p{Katakana}]/,
        "ko" => /\p{Hangul}/,
        "th" => /\p{Thai}/,
        "el" => /\p{Greek}/,
        "he" => /\p{Hebrew}/,
        "hi" => /\p{Devanagari}/,
        "zh" => /\p{Han}/
      }.freeze

      # Cyrillic is shared, so it only narrows to a shortlist the word lists
      # decide between. Han is the same: the kana test in SCRIPTS fires first.
      CYRILLIC = /\p{Cyrillic}/

      # The languages in {WORDS} written in Cyrillic. Splitting the word lists by
      # script keeps a Latin page from being scored against a Cyrillic list.
      CYRILLIC_LANGUAGES = %w[ru uk bg sr].freeze

      # Function words: the closed class a language cannot write a paragraph
      # without. Only reached when a page declares no lang attribute.
      WORDS = {
        "en" => %w[the and that with have this from they which been would about their there],
        "de" => %w[der die das und ist nicht sich auch eine dem den mit von auf werden],
        "fr" => %w[les des une dans pour que qui pas sur avec est plus par sont mais],
        "es" => %w[que los las del por con una para como pero más sus está sobre],
        "pt" => %w[que não uma dos para com como mais isso pelo pela são está],
        "it" => %w[che non per una con sono nel gli dei alla come anche più],
        "nl" => %w[het een van dat niet zijn met voor door maar ook worden wordt],
        "pl" => %w[nie się jest oraz przez tego które który jako aby jego już],
        "sv" => %w[och att för med inte den som har det var till från men],
        "da" => %w[og det ikke som til med for har blev efter deres men],
        "no" => %w[ikke som til med for har blir etter deres men over],
        "fi" => %w[että ovat myös kuin sekä mutta niin oli tämä hän jotka],
        "cs" => %w[nebo jako podle který která které této bylo jsou ale ještě],
        "tr" => %w[için daha bir ile ancak olarak sonra kadar oldu gibi ise],
        "ro" => %w[care este pentru sunt dar mai fost după între prin până],
        "hu" => %w[hogy nem egy volt csak még már amely között szerint mint],
        "id" => %w[yang dan dengan untuk tidak pada dari akan ini itu adalah],
        "vi" => %w[không của và các được người những cho trong này khi],
        "ru" => %w[что это для как его она они мы был были также после],
        "uk" => %w[що це для як його вона вони був були також після але],
        "bg" => %w[че това като него тя те беше бяха също след но],
        "sr" => %w[који која које није био била њихов од са али када]
      }.freeze

      # How many list words a page must carry, and how far ahead of the runner
      # up, so a short or mixed page comes back unknown instead of wrong.
      MIN_HITS = 6
      MIN_MARGIN = 1.5

      module_function

      # A language code reduced to its primary subtag, or nil when the value
      # declares nothing. "pt-BR" and "PT_br" both come back as "pt".
      def normalise(value)
        tag = value.to_s.strip.downcase.tr("_", "-").split("-").first.to_s
        return nil if tag.empty? || tag == "*"
        return nil unless tag.match?(/\A[a-z]{2,3}\z/)
        return nil if GENERIC.include?(tag)

        tag
      end

      # The English name of a language code, for the sentence posted back.
      def name(code) = NAMES[code.to_s] || code.to_s

      # The language +html+ declares, or nil when it declares none.
      def declared(html)
        text = html.to_s[0, 65_536]
        candidates = [
          text[/<html[^>]*\slang\s*=\s*["']([^"']+)["']/i, 1],
          text[/<html[^>]*\sxml:lang\s*=\s*["']([^"']+)["']/i, 1],
          text[/<meta[^>]+http-equiv\s*=\s*["']content-language["'][^>]+content\s*=\s*["']([^"']+)["']/i, 1],
          text[/<meta[^>]+property\s*=\s*["']og:locale["'][^>]+content\s*=\s*["']([^"']+)["']/i, 1]
        ]
        candidates.filter_map { |value| normalise(value) }.first
      end

      # The language of a run of plain text, or nil when the evidence is thin.
      def from_text(text)
        body = text.to_s
        return nil if body.strip.length < 200

        script = script_language(body)
        return script if script && script != :cyrillic

        shortlist = script == :cyrillic ? CYRILLIC_LANGUAGES : WORDS.keys - CYRILLIC_LANGUAGES
        by_words(body, shortlist)
      end

      # What the page says it is, and failing that what it reads like.
      def detect(html, text: nil)
        declared(html) || from_text(text || html)
      end

      # The single-language script this text is written in, :cyrillic for the
      # shared one, or nil for Latin and for a page too mixed to call. A script
      # must carry a real share of the letters.
      def script_language(text)
        sample = text[0, 20_000]
        letters = sample.gsub(/[[:^alpha:]]/, "").length.to_f
        return nil if letters < 50

        SCRIPTS.each do |code, pattern|
          return code if sample.scan(pattern).length / letters > 0.2
        end
        sample.scan(CYRILLIC).length / letters > 0.2 ? :cyrillic : nil
      end

      def by_words(text, shortlist)
        tokens = text.downcase.scan(/[[:alpha:]]{2,}/)
        return nil if tokens.length < 40

        seen = tokens.tally
        scores = shortlist.to_h { |code| [code, WORDS.fetch(code, []).sum { |word| seen.fetch(word, 0) }] }
        best, best_score = scores.max_by { |_, score| score }
        return nil if best_score < MIN_HITS

        runner_up = scores.reject { |code, _| code == best }.values.max.to_i
        return nil if runner_up.positive? && best_score < runner_up * MIN_MARGIN

        best
      end
    end
  end
end
