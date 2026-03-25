# frozen_string_literal: true

require_relative "glosser"
require_relative "kana"

module Tell
  # Japanese bracket reading correction utilities.
  # Character-level alignment of phonetic readings to gloss brackets,
  # particle pronunciation fixes, redundant bracket stripping, and
  # bracket cache generation for alternative phonetic systems.
  #
  # Included by Engine — methods available to japanese_coordinated orchestrator
  # and non-Japanese gloss paths (strip_redundant_brackets).
  module JapaneseBrackets
    HIRAGANA_RE = /\A[\u3040-\u309F]+\z/
    private_constant :HIRAGANA_RE

    # Align phonetic readings into gloss brackets by walking the
    # hiragana string character-by-character, guided by bracket lengths.
    def align_bracket_readings(gloss, hiragana)
      flat = hiragana.delete("・").scan(/[\u3040-\u309F\u30A0-\u30FF]/).join
      pos = 0

      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match unless match.include?("[")

        word = match[/(?:\*\S+?\*)?(\S+?)\[/, 1]
        current = match[/\[([^\]]+)\]/, 1]
        len = current.length

        if pos + len <= flat.length
          reading = flat[pos, len]
          pos += len
          if word&.match?(HIRAGANA_RE)
            match
          else
            match.sub(/\[[^\]]+\]/, "[#{reading}]")
          end
        else
          match
        end
      end
    end

    # Fix Japanese particle pronunciation in bracket readings.
    # は→わ and へ→え when the grammar annotation marks the word as a particle.
    def fix_particle_readings(gloss)
      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match unless match.include?("[") && match.include?("part")

        match
          .sub(/\[([^\]]*?)は([^\]]*)\]/) { "[#{$1}わ#{$2}]" }
          .sub(/\[([^\]]*?)へ([^\]]*)\]/) { "[#{$1}え#{$2}]" }
      end
    end

    # Remove [reading] brackets where the reading is identical to the word —
    # they add no information. Applies to any language.
    def strip_redundant_brackets(gloss)
      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match unless match.include?("[")

        m = match.match(/(?:\*\S+?\*)?(\S+?)\[([^\]]+)\]/)
        next match unless m

        m[1] == m[2] ? match.sub("[#{m[2]}]", "") : match
      end
    end

    # Insert [reading] brackets for hiragana-only words that lack them.
    def ensure_all_brackets(gloss)
      gloss.gsub(Glosser::GLOSS_WORD_RE) do |match|
        next match if match.include?("[")

        m = match.match(/(?:\*\S+?\*)?(\S+?)\(/)
        next match unless m

        word = m[1]
        next match unless word.match?(HIRAGANA_RE)

        match.sub("(", "[#{word}](")
      end
    end

    # Build bracket reading cache with all 4 phonetic systems.
    def build_gloss_bracket_cache(gloss)
      readings = gloss.scan(/\[([^\]]+)\]/).flatten
      return nil if readings.empty?

      cache = { "hiragana" => readings }
      cache["hepburn"] = readings.map { |r| Kana.to_romaji(r, system: "hepburn") }
      cache["kunrei"] = readings.map { |r| Kana.to_romaji(r, system: "kunrei") }
      cache["ipa"] = readings.map { |r| Kana.to_romaji(r, system: "ipa") }
      cache
    end

    # Convert [hiragana] bracket readings to another phonetic system.
    def convert_gloss_brackets(gloss, system)
      gloss.gsub(/\[([^\]]+)\]/) do
        "[#{Kana.to_romaji($1, system: system)}]"
      end
    end
  end
end
