# frozen_string_literal: true

module Tell
  # Converts hiragana/katakana to romaji using Hepburn or Kunrei-shiki systems.
  # Katakana is normalized to hiragana first, then romanized via lookup tables.
  # Non-kana characters (punctuation, spaces, Latin) are preserved as-is.
  class Kana
    SYSTEMS = %w[hepburn kunrei ipa].freeze

    # Katakana → hiragana offset (ア 0x30A1 - あ 0x3041 = 0x60).
    KATA_HIRA_OFFSET = 0x60

    # Katakana range for conversion (ァ..ヶ).
    KATA_START = 0x30A1
    KATA_END   = 0x30F6

    # Prolonged sound mark (ー) for long vowels in katakana.
    CHOONPU = "ー"

    # Small tsu (っ) triggers gemination.
    SOKUON = "っ"

    # Syllabic n (ん).
    SYLLABIC_N = "ん"

    # Labial consonants — ん becomes "m" before these in Hepburn.
    LABIALS = %w[m b p].freeze

    # Vowel for long-vowel repetition after choonpu.
    FINAL_VOWEL = {
      "a" => "a", "i" => "i", "u" => "u", "e" => "e", "o" => "o"
    }.freeze

    # Base kana mappings shared by both systems.
    COMMON = {
      # Vowels
      "あ" => "a",  "い" => "i",  "う" => "u",  "え" => "e",  "お" => "o",
      # K-row
      "か" => "ka", "き" => "ki", "く" => "ku", "け" => "ke", "こ" => "ko",
      # S-row (sa, su, se, so — shared; si/shi handled per-system)
      "さ" => "sa",                "す" => "su", "せ" => "se", "そ" => "so",
      # T-row (ta, te, to — shared; ti/chi, tu/tsu handled per-system)
      "た" => "ta",                              "て" => "te", "と" => "to",
      # N-row
      "な" => "na", "に" => "ni", "ぬ" => "nu", "ね" => "ne", "の" => "no",
      # H-row (ha, hi, he, ho — shared; hu/fu handled per-system)
      "は" => "ha", "ひ" => "hi",               "へ" => "he", "ほ" => "ho",
      # M-row
      "ま" => "ma", "み" => "mi", "む" => "mu", "め" => "me", "も" => "mo",
      # Y-row
      "や" => "ya",               "ゆ" => "yu",               "よ" => "yo",
      # R-row
      "ら" => "ra", "り" => "ri", "る" => "ru", "れ" => "re", "ろ" => "ro",
      # W-row
      "わ" => "wa", "ゐ" => "wi", "ゑ" => "we", "を" => "wo",
      # Syllabic n
      "ん" => "n",
      # G-row
      "が" => "ga", "ぎ" => "gi", "ぐ" => "gu", "げ" => "ge", "ご" => "go",
      # Z-row (za, zu, ze, zo — shared; zi/ji handled per-system)
      "ざ" => "za",               "ず" => "zu", "ぜ" => "ze", "ぞ" => "zo",
      # D-row (da, de, do — shared; di/ji, du/zu handled per-system)
      "だ" => "da",                              "で" => "de", "ど" => "do",
      # B-row
      "ば" => "ba", "び" => "bi", "ぶ" => "bu", "べ" => "be", "ぼ" => "bo",
      # P-row
      "ぱ" => "pa", "ぴ" => "pi", "ぷ" => "pu", "ぺ" => "pe", "ぽ" => "po",
      # V-row (foreign sounds)
      "ゔ" => "vu",
      # Small kana (standalone fallback for unrecognized digraphs)
      "ぁ" => "a", "ぃ" => "i", "ぅ" => "u", "ぇ" => "e", "ぉ" => "o",
      "ゃ" => "ya", "ゅ" => "yu", "ょ" => "yo"
    }.freeze

    # Common digraphs (same in both systems).
    COMMON_DIGRAPHS = {
      "きゃ" => "kya", "きゅ" => "kyu", "きょ" => "kyo",
      "ぎゃ" => "gya", "ぎゅ" => "gyu", "ぎょ" => "gyo",
      "にゃ" => "nya", "にゅ" => "nyu", "にょ" => "nyo",
      "ひゃ" => "hya", "ひゅ" => "hyu", "ひょ" => "hyo",
      "びゃ" => "bya", "びゅ" => "byu", "びょ" => "byo",
      "ぴゃ" => "pya", "ぴゅ" => "pyu", "ぴょ" => "pyo",
      "みゃ" => "mya", "みゅ" => "myu", "みょ" => "myo",
      "りゃ" => "rya", "りゅ" => "ryu", "りょ" => "ryo",
      # Foreign sound digraphs (loan words)
      "ゔぁ" => "va", "ゔぃ" => "vi", "ゔぇ" => "ve", "ゔぉ" => "vo",
      "うぃ" => "wi", "うぇ" => "we", "うぉ" => "wo",
      "とぅ" => "tu", "どぅ" => "du",
      "てぃ" => "ti", "でぃ" => "di"
    }.freeze

    # Hepburn-specific mappings (override COMMON).
    HEPBURN_SINGLE = {
      "し" => "shi", "ち" => "chi", "つ" => "tsu", "ふ" => "fu",
      "じ" => "ji",  "ぢ" => "ji",  "づ" => "zu"
    }.freeze

    HEPBURN_DIGRAPHS = {
      "しゃ" => "sha", "しゅ" => "shu", "しょ" => "sho",
      "ちゃ" => "cha", "ちゅ" => "chu", "ちょ" => "cho",
      "じゃ" => "ja",  "じゅ" => "ju",  "じょ" => "jo",
      "ぢゃ" => "ja",  "ぢゅ" => "ju",  "ぢょ" => "jo",
      # Foreign sound digraphs
      "ふぁ" => "fa", "ふぃ" => "fi", "ふぇ" => "fe", "ふぉ" => "fo",
      "しぇ" => "she", "じぇ" => "je", "ちぇ" => "che",
      "つぁ" => "tsa", "つぃ" => "tsi", "つぇ" => "tse", "つぉ" => "tso"
    }.freeze

    # Kunrei-shiki mappings (override COMMON).
    KUNREI_SINGLE = {
      "し" => "si",  "ち" => "ti",  "つ" => "tu",  "ふ" => "hu",
      "じ" => "zi",  "ぢ" => "di",  "づ" => "du"
    }.freeze

    KUNREI_DIGRAPHS = {
      "しゃ" => "sya", "しゅ" => "syu", "しょ" => "syo",
      "ちゃ" => "tya", "ちゅ" => "tyu", "ちょ" => "tyo",
      "じゃ" => "zya", "じゅ" => "zyu", "じょ" => "zyo",
      "ぢゃ" => "dya", "ぢゅ" => "dyu", "ぢょ" => "dyo",
      # Foreign sound digraphs (same as Hepburn — no Kunrei standard exists)
      "ふぁ" => "fa", "ふぃ" => "fi", "ふぇ" => "fe", "ふぉ" => "fo",
      "しぇ" => "sye", "じぇ" => "zye", "ちぇ" => "tye",
      "つぁ" => "tua", "つぃ" => "tui", "つぇ" => "tue", "つぉ" => "tuo"
    }.freeze

    # IPA-specific mappings (override COMMON). Broad/phonemic Japanese IPA.
    IPA_SINGLE = {
      # Vowels
      "う" => "ɯ",
      # K-row
      "く" => "kɯ",
      # S-row
      "し" => "ɕi", "す" => "sɯ",
      # T-row
      "ち" => "tɕi", "つ" => "tsɯ",
      # N-row
      "ぬ" => "nɯ",
      # H-row
      "ひ" => "çi", "ふ" => "ɸɯ",
      # M-row
      "む" => "mɯ",
      # Y-row
      "や" => "ja", "ゆ" => "jɯ", "よ" => "jo",
      # R-row (alveolar tap)
      "ら" => "ɾa", "り" => "ɾi", "る" => "ɾɯ", "れ" => "ɾe", "ろ" => "ɾo",
      # W-row
      "を" => "o",
      # Syllabic n (uvular nasal)
      "ん" => "ɴ",
      # G-row (IPA ɡ)
      "が" => "ɡa", "ぎ" => "ɡi", "ぐ" => "ɡɯ", "げ" => "ɡe", "ご" => "ɡo",
      # Z-row
      "じ" => "dʑi", "ず" => "zɯ",
      # D-row
      "ぢ" => "dʑi", "づ" => "dzɯ",
      # B-row
      "ぶ" => "bɯ",
      # P-row
      "ぷ" => "pɯ",
      # V-row
      "ゔ" => "vɯ",
      # Small kana
      "ぅ" => "ɯ", "ゃ" => "ja", "ゅ" => "jɯ", "ょ" => "jo"
    }.freeze

    IPA_DIGRAPHS = {
      # Palatal digraphs (override COMMON_DIGRAPHS)
      "きゃ" => "kja", "きゅ" => "kjɯ", "きょ" => "kjo",
      "ぎゃ" => "ɡja", "ぎゅ" => "ɡjɯ", "ぎょ" => "ɡjo",
      "にゃ" => "ɲa",  "にゅ" => "ɲɯ",  "にょ" => "ɲo",
      "ひゃ" => "ça",   "ひゅ" => "çɯ",  "ひょ" => "ço",
      "びゃ" => "bja", "びゅ" => "bjɯ", "びょ" => "bjo",
      "ぴゃ" => "pja", "ぴゅ" => "pjɯ", "ぴょ" => "pjo",
      "みゃ" => "mja", "みゅ" => "mjɯ", "みょ" => "mjo",
      "りゃ" => "ɾja", "りゅ" => "ɾjɯ", "りょ" => "ɾjo",
      # Foreign sound overrides
      "とぅ" => "tɯ",  "どぅ" => "dɯ",
      # Sibilant/affricate palatal
      "しゃ" => "ɕa",  "しゅ" => "ɕɯ",  "しょ" => "ɕo",
      "ちゃ" => "tɕa", "ちゅ" => "tɕɯ", "ちょ" => "tɕo",
      "じゃ" => "dʑa", "じゅ" => "dʑɯ", "じょ" => "dʑo",
      "ぢゃ" => "dʑa", "ぢゅ" => "dʑɯ", "ぢょ" => "dʑo",
      # Foreign F-row
      "ふぁ" => "ɸa",  "ふぃ" => "ɸi",  "ふぇ" => "ɸe",  "ふぉ" => "ɸo",
      # Foreign sibilant
      "しぇ" => "ɕe",  "じぇ" => "dʑe", "ちぇ" => "tɕe",
      # Ts-row foreign
      "つぁ" => "tsa", "つぃ" => "tsi", "つぇ" => "tse", "つぉ" => "tso"
    }.freeze

    class << self
      def available?
        true
      end

      def supports?(lang, system = nil)
        return false unless lang == "ja"
        return true if system.nil?

        SYSTEMS.include?(system)
      end

      def to_romaji(text, system: "hepburn")
        raise ArgumentError, "unknown system: #{system}" unless SYSTEMS.include?(system)

        table, digraphs = build_tables(system)
        convert(text, table, digraphs, system)
      end

      def to_hepburn(text)
        to_romaji(text, system: "hepburn")
      end

      def to_kunrei(text)
        to_romaji(text, system: "kunrei")
      end

      def to_ipa(text)
        to_romaji(text, system: "ipa")
      end

      private

      def build_tables(system)
        @tables ||= {}
        @tables[system] ||= begin
          case system
          when "hepburn"
            single = COMMON.merge(HEPBURN_SINGLE)
            digraphs = COMMON_DIGRAPHS.merge(HEPBURN_DIGRAPHS)
          when "kunrei"
            single = COMMON.merge(KUNREI_SINGLE)
            digraphs = COMMON_DIGRAPHS.merge(KUNREI_DIGRAPHS)
          when "ipa"
            single = COMMON.merge(IPA_SINGLE)
            digraphs = COMMON_DIGRAPHS.merge(IPA_DIGRAPHS)
          end
          [single, digraphs]
        end
      end

      def convert(text, table, digraphs, system)
        hiragana = katakana_to_hiragana(text)
        chars = hiragana.chars
        result = +""
        i = 0

        while i < chars.length
          char = chars[i]

          # Prolonged sound mark: IPA uses length mark (ː), others repeat vowel.
          if char == CHOONPU
            if system == "ipa"
              result << "ː"
            else
              prev_vowel = extract_final_vowel(result)
              result << (prev_vowel || "")
            end
            i += 1
            next
          end

          # Gemination (っ): double the next consonant.
          if char == SOKUON
            next_romaji = peek_romaji(chars, i + 1, table, digraphs)
            if next_romaji && !next_romaji.empty?
              consonant = next_romaji[0]
              # Special case: っち → tchi (hepburn), っつ → ttsu (hepburn)
              # The doubled letter is always the first letter of the next syllable.
              result << consonant
            end
            i += 1
            next
          end

          # Syllabic n before labials: "m" in Hepburn, "n" in Kunrei.
          # IPA: always ɴ (broad transcription), skip assimilation.
          if char == SYLLABIC_N && system != "ipa"
            next_romaji = peek_romaji(chars, i + 1, table, digraphs)
            if next_romaji && LABIALS.include?(next_romaji[0])
              result << (system == "hepburn" ? "m" : "n")
              i += 1
              next
            end
          end

          # Try digraph (two-char lookup) first.
          if i + 1 < chars.length
            pair = char + chars[i + 1]
            if digraphs.key?(pair)
              result << digraphs[pair]
              i += 2
              next
            end
          end

          # Single kana lookup.
          if table.key?(char)
            result << table[char]
            i += 1
            next
          end

          # Non-kana character: preserve as-is.
          result << char
          i += 1
        end

        result
      end

      # Convert katakana characters to hiragana. Non-katakana passes through.
      def katakana_to_hiragana(text)
        text.each_char.map do |ch|
          cp = ch.ord
          if cp >= KATA_START && cp <= KATA_END
            (cp - KATA_HIRA_OFFSET).chr(Encoding::UTF_8)
          else
            ch
          end
        end.join
      end

      # Look up what the next kana syllable would romanize to (for gemination/n).
      def peek_romaji(chars, pos, table, digraphs)
        return nil if pos >= chars.length

        # Try digraph first.
        if pos + 1 < chars.length
          pair = chars[pos] + chars[pos + 1]
          return digraphs[pair] if digraphs.key?(pair)
        end

        table[chars[pos]]
      end

      # Extract the last vowel from the romaji built so far.
      def extract_final_vowel(romaji)
        return nil if romaji.empty?

        last = romaji[-1]
        FINAL_VOWEL[last]
      end
    end
  end
end
