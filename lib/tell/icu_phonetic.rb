# frozen_string_literal: true

module Tell
  # Wraps ICU transliteration (via ffi-icu) for deterministic romanization.
  # Covers Cyrillic (scholarly/simple), Greek (ELOT), and Korean (revised).
  # Falls back gracefully: if ffi-icu is not installed, available? returns false.
  class IcuPhonetic
    # Transliterator IDs for (language, system) pairs.
    # Scholarly Cyrillic uses per-language BGN transliterators;
    # simple Cyrillic chains generic Cyrillic-Latin with Latin-ASCII to strip diacritics.
    TRANSLITERATORS = {
      ["ru", "scholarly"] => "Russian-Latin/BGN",
      ["uk", "scholarly"] => "Ukrainian-Latin/BGN",
      ["bg", "scholarly"] => "Bulgarian-Latin/BGN",
      ["sr", "scholarly"] => "Serbian-Latin/BGN",
      ["mk", "scholarly"] => "Macedonian-Latin/BGN",
      ["be", "scholarly"] => "Belarusian-Latin/BGN",
      ["ru", "simple"]    => "Cyrillic-Latin; Latin-ASCII",
      ["uk", "simple"]    => "Cyrillic-Latin; Latin-ASCII",
      ["bg", "simple"]    => "Cyrillic-Latin; Latin-ASCII",
      ["sr", "simple"]    => "Cyrillic-Latin; Latin-ASCII",
      ["mk", "simple"]    => "Cyrillic-Latin; Latin-ASCII",
      ["be", "simple"]    => "Cyrillic-Latin; Latin-ASCII",
      ["el", "elot"]      => "Greek-Latin/UNGEGN",
      ["ko", "rr"]        => "Hangul-Latin"
    }.freeze

    class << self
      def available?
        return @available unless @available.nil?

        @available = begin
          require "ffi-icu"
          # Verify ICU is actually functional
          ICU::Transliteration::Transliterator.new("Latin-ASCII")
          true
        rescue LoadError, ICU::Error
          false
        end
      end

      def supports?(lang, system)
        available? && TRANSLITERATORS.key?([lang, system])
      end

      def transliterate(text, lang:, system:)
        return nil unless supports?(lang, system)

        text = text.strip
        return nil if text.empty?

        tid = TRANSLITERATORS[[lang, system]]
        transliterator = ICU::Transliteration::Transliterator.new(tid)
        transliterator.transliterate(text)
      rescue ICU::Error
        nil
      end
    end
  end
end
