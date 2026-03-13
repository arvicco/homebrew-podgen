# frozen_string_literal: true

require "open3"

module Tell
  # Wraps espeak-ng for IPA phonetic transcription.
  # Produces narrow phonetic output with proper allophonic variation.
  #
  # Two modes:
  #   ipa       — phrase-level connected speech (for standalone PH: display)
  #   ipa_words — per-word transcription, 1:1 mapping (for gloss [bracket] readings)
  class Espeak
    # Languages where espeak-ng IPA is known to be broken or unusable.
    # Japanese: reads kanji as "Chinese letter", Chinese: no word segmentation.
    UNSUPPORTED = %w[ja zh].freeze

    # Map tell language codes to espeak-ng voice names where they differ.
    VOICE_MAP = {
      "zh" => "cmn",
      "no" => "nb",
      "fr" => "fr-fr"
    }.freeze

    # Word regex: Unicode letters/marks, including hyphenated words.
    WORD_RE = /[\p{L}\p{M}]+(?:['-][\p{L}\p{M}]+)*/

    class << self
      def available?
        return @available unless @available.nil?

        @available = begin
          _, _, status = Open3.capture3("espeak-ng", "--version")
          status.success?
        rescue Errno::ENOENT
          false
        end
      end

      def supports?(lang)
        return false if UNSUPPORTED.include?(lang)

        available? && voices.include?(voice_for(lang))
      end

      # Phrase-level IPA: natural connected speech with sandhi, stress shifts,
      # and proclitic merging. For standalone display (PH: line).
      # Punctuation preserved when word counts align.
      def ipa(text, lang:)
        return nil unless supports?(lang)

        voice = voice_for(lang)
        input_words = text.scan(WORD_RE)
        return nil if input_words.empty?

        ipa_words = transcribe(text, voice)
        return nil unless ipa_words

        if ipa_words.size == input_words.size
          reassemble(text, ipa_words)
        else
          "/#{ipa_words.join(" ")}/"
        end
      end

      # Word-level IPA: one reading per input word, guaranteed 1:1 mapping.
      # For split_phonetic / merge_phonetic (gloss bracket readings).
      # Pipe-separated input prevents proclitic merging while preserving
      # allophonic context from neighboring words.
      def ipa_words(text, lang:)
        return nil unless supports?(lang)

        voice = voice_for(lang)
        input_words = text.scan(WORD_RE)
        return nil if input_words.empty?

        # 1. Try full text — works when no proclitic merging.
        ipa_result = transcribe(text, voice)
        return reassemble(text, ipa_result) if ipa_result&.size == input_words.size

        # 2. Pipe-separated fallback — prevents merging.
        #    Some languages (uk, pl) read "|" as a word; their count will be
        #    higher, so this step harmlessly fails and falls through.
        piped = transcribe(input_words.join(" | "), voice)
        return reassemble(text, piped) if piped&.size == input_words.size

        # 3. Raw fallback.
        "/#{(ipa_result || piped || []).join(" ")}/"
      end

      # IPA from kana (hiragana/katakana). Bypasses UNSUPPORTED check since
      # eSpeak handles pure kana well — it only fails on kanji.
      # Input may use ・ as word separator (from AI hiragana output).
      def ipa_from_kana(kana_text)
        return nil unless available?

        voice = voice_for("ja")
        text = kana_text.gsub("・", " ")
        input_words = text.scan(WORD_RE)
        return nil if input_words.empty?

        ipa_result = transcribe(text, voice)
        return nil unless ipa_result

        if ipa_result.size == input_words.size
          reassemble(text, ipa_result)
        else
          "/#{ipa_result.join(" ")}/"
        end
      end

      private

      def transcribe(text, voice)
        raw = run(text, voice)
        return nil unless raw

        raw.split(/\s+/).reject(&:empty?)
      end

      def reassemble(text, ipa_words)
        idx = 0
        result = text.gsub(WORD_RE) do
          w = ipa_words[idx]
          idx += 1
          w
        end
        "/#{result.strip}/"
      end

      def run(text, voice)
        stdout, _, status = Open3.capture3("espeak-ng", "-q", "--ipa", "-v", voice, text)
        return nil unless status.success?

        output = stdout.strip
        output.empty? ? nil : output
      end

      def voice_for(lang)
        VOICE_MAP.fetch(lang, lang)
      end

      def voices
        @voices ||= begin
          stdout, _, status = Open3.capture3("espeak-ng", "--voices")
          return Set.new unless status.success?

          require "set"
          stdout.lines.drop(1).map { |l| l.split[1] }.compact.to_set
        end
      end
    end
  end
end
