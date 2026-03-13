# frozen_string_literal: true

module Tell
  # Lightweight language detection using Unicode script analysis and stop words.
  # No external dependencies — works with any Ruby version.
  module Detector
    # Detect the most likely ISO 639-1 language code for the given text.
    # Returns nil if detection confidence is too low.
    def self.detect(text)
      return nil if text.nil? || text.strip.length < 5

      script = dominant_script(text)
      case script
      when :cjk
        cjk_language(text)
      when :hangul
        "ko"
      when :cyrillic
        cyrillic_language(text)
      when :arabic
        "ar"
      when :hebrew
        "he"
      when :thai
        "th"
      when :devanagari
        "hi"
      when :latin
        latin_language(text)
      end
    end

    # --- Script detection ---

    SCRIPT_RANGES = {
      cjk:        /[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF]/,
      hangul:     /[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]/,
      cyrillic:   /[\u0400-\u04FF\u0500-\u052F]/,
      arabic:     /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]/,
      hebrew:     /[\u0590-\u05FF]/,
      thai:       /[\u0E00-\u0E7F]/,
      devanagari: /[\u0900-\u097F]/
    }.freeze

    def self.dominant_script(text)
      counts = Hash.new(0)
      text.each_char do |ch|
        next if ch.match?(/[\s\p{P}\d]/)

        matched = false
        SCRIPT_RANGES.each do |script, pattern|
          if ch.match?(pattern)
            counts[script] += 1
            matched = true
            break
          end
        end
        counts[:latin] += 1 if !matched && ch.match?(/[a-zA-ZÀ-ÖØ-öø-ÿĀ-žƀ-ȳ]/)
      end

      return nil if counts.empty?
      counts.max_by { |_, v| v }&.first
    end

    # --- CJK disambiguation ---

    HIRAGANA = /[\u3040-\u309F]/
    KATAKANA = /[\u30A0-\u30FF]/

    def self.cjk_language(text)
      has_kana = text.match?(HIRAGANA) || text.match?(KATAKANA)
      has_kana ? "ja" : "zh"
    end

    # --- Cyrillic disambiguation ---

    # Ukrainian-specific letters not found in Russian
    UKRAINIAN_CHARS = /[ієїґ]/i

    def self.cyrillic_language(text)
      text.match?(UKRAINIAN_CHARS) ? "uk" : "ru"
    end

    # --- Latin-script language detection via stop words ---

    STOP_WORDS = {
      "en" => %w[the a an and or of to in on at it is are was were am do does did have has had been not but for by if so all will can would could should this that with from they their them what which],
      "sl" => %w[je sem bil bila bilo smo ste kot tudi ali ker pri tem kako zelo],
      "de" => %w[der die das ist ein eine und ich nicht mit auf den dem des sich von aber haben wird],
      "fr" => %w[les des une est dans que pour par sur pas avec sont mais comme],
      "es" => %w[los las una esta este pero por del como para con todo muy],
      "it" => %w[gli una sono della delle questo questa come anche molto perché],
      "pt" => %w[uma dos das não com como mas para por muito isso esta este],
      "nl" => %w[het een zijn heeft voor met niet van ook maar wel deze],
      "pl" => %w[jest nie ale jak tak dla czy ten jest tego jego],
      "cs" => %w[jest není ale jak tak pro ten jeho jsem jsou],
      "hr" => %w[sam bio bila bilo smo ste kao također ili jer pri tom kako vrlo],
      "ro" => %w[este sunt avea fost care dar sau pentru acest aceasta foarte],
      "hu" => %w[egy hogy nem van ezt azt igen nem volt csak mint],
      "sv" => %w[och det att den för med har inte som ett],
      "da" => %w[det har ikke med som kan til jeg den],
      "no" => %w[det har ikke med som kan til den for],
      "fi" => %w[mutta koska vain niin kuin myös joka tämä siitä],
      "tr" => %w[bir var olan için ama veya kadar gibi daha çok],
      "vi" => %w[của không được này một những cũng trong cho các],
      "id" => %w[yang dan dari untuk dengan tidak pada ada ini],
    }.freeze

    def self.latin_language(text)
      words = text.downcase.scan(/[a-zà-öø-ÿā-žƀ-ȳ]+/)
      return nil if words.length < 3

      scores = {}
      STOP_WORDS.each do |lang, stops|
        scores[lang] = words.count { |w| stops.include?(w) }
      end

      best_lang, best_score = scores.max_by { |_, v| v }
      return nil if best_score < 2

      best_lang
    end

    # Diacritics/characters that are distinctive to specific languages
    # and NOT used in English. Used as a fallback when stop-word detection
    # fails (short text, content words only, etc.)
    CHARACTERISTIC_CHARS = {
      "sl" => /[čšž]/i,
      "hr" => /[čšžćđ]/i,
      "sr" => /[čšžćđ]/i,
      "cs" => /[čšžřůěďťň]/i,
      "sk" => /[čšžťďňľĺŕô]/i,
      "pl" => /[ąęćśźżłń]/i,
      "de" => /[ßäöü]/i,
      "fr" => /[éèêëàâùûçœæ]/i,
      "tr" => /[çşğı]/i,
      "ro" => /[șțăî]/i,
      "hu" => /[őű]/i,
      "lt" => /[ąčęėįšųūž]/i,
      "lv" => /[āčēģīķļņšūž]/i,
      "et" => /[äöüõšž]/i,
    }.freeze

    # Check if text contains characters characteristic of a given language.
    def self.has_characteristic_chars?(text, lang)
      pattern = CHARACTERISTIC_CHARS[lang]
      return false unless pattern
      text.match?(pattern)
    end

    # CJK, Hangul, Thai etc. pack far more meaning per character than Latin.
    # A 60-char Japanese sentence routinely becomes 250+ chars in Slovenian.
    # Use a higher multiplier for dense scripts to avoid false positives.
    DENSE_SCRIPTS = %i[cjk hangul thai arabic hebrew devanagari].freeze

    # Is the translation likely an LLM explanation rather than a real translation?
    def self.explanation?(input, translation)
      multiplier = DENSE_SCRIPTS.include?(dominant_script(input)) ? 8 : 3
      translation.length > input.length * multiplier
    end
  end
end
