# frozen_string_literal: true

require_relative "../test_helper"
require "tell/espeak"

class TestTellEspeak < Minitest::Test
  # --- availability ---

  def test_available_when_espeak_installed
    # This test runs on machines with espeak-ng installed
    skip "espeak-ng not installed" unless system("which espeak-ng > /dev/null 2>&1")
    assert Tell::Espeak.available?
  end

  def test_available_false_when_not_installed
    Open3.stub(:capture3, ->(*_) { raise Errno::ENOENT }) do
      Tell::Espeak.instance_variable_set(:@available, nil)
      Tell::Espeak.instance_variable_set(:@voices, nil)
      refute Tell::Espeak.available?
      Tell::Espeak.instance_variable_set(:@available, nil)
      Tell::Espeak.instance_variable_set(:@voices, nil)
    end
  end

  # --- supports? ---

  def test_supports_slovenian
    skip_unless_espeak
    assert Tell::Espeak.supports?("sl")
  end

  def test_supports_german
    skip_unless_espeak
    assert Tell::Espeak.supports?("de")
  end

  def test_supports_russian
    skip_unless_espeak
    assert Tell::Espeak.supports?("ru")
  end

  def test_does_not_support_japanese
    skip_unless_espeak
    refute Tell::Espeak.supports?("ja")
  end

  def test_does_not_support_chinese
    skip_unless_espeak
    refute Tell::Espeak.supports?("zh")
  end

  def test_does_not_support_unknown_language
    skip_unless_espeak
    refute Tell::Espeak.supports?("xx")
  end

  # --- ipa (phrase-level) ---

  def test_single_word
    skip_unless_espeak
    result = Tell::Espeak.ipa("dan", lang: "sl")
    assert result
    assert result.start_with?("/")
    assert result.end_with?("/")
    assert_match(/dˈaːn/, result)
  end

  def test_multiple_words
    skip_unless_espeak
    result = Tell::Espeak.ipa("dober dan", lang: "sl")
    assert result
    inner = result.delete_prefix("/").delete_suffix("/")
    words = inner.split(/\s+/)
    assert_equal 2, words.size
  end

  def test_punctuation_preserved
    skip_unless_espeak
    result = Tell::Espeak.ipa("dober dan, kako ste?", lang: "sl")
    assert result
    assert_includes result, ","
    assert_includes result, "?"
  end

  def test_period_preserved
    skip_unless_espeak
    result = Tell::Espeak.ipa("To je lepo. Hvala.", lang: "sl")
    assert result
    assert_includes result, "."
  end

  def test_exclamation_preserved
    skip_unless_espeak
    result = Tell::Espeak.ipa("Hvala!", lang: "sl")
    assert result
    assert_includes result, "!"
  end

  def test_allophonic_variation_slovenian_v
    skip_unless_espeak
    # Before vowel: labiodental approximant
    voda = Tell::Espeak.ipa("voda", lang: "sl")
    assert_match(/ʋ/, voda)

    # Word-final: labial-velar approximant
    nov = Tell::Espeak.ipa("nov", lang: "sl")
    assert_match(/w/, nov)

    # Before obstruent: vowel
    vstopiti = Tell::Espeak.ipa("vstopiti", lang: "sl")
    assert_match(/u/, vstopiti)
  end

  def test_phrase_level_allows_proclitic_merging
    skip_unless_espeak
    # Phrase-level may merge "v" with next word — natural connected speech
    result = Tell::Espeak.ipa("sem bil v trgovini", lang: "sl")
    assert result
    assert result.start_with?("/")
  end

  def test_german
    skip_unless_espeak
    result = Tell::Espeak.ipa("Guten Tag", lang: "de")
    assert result
    inner = result.delete_prefix("/").delete_suffix("/")
    words = inner.split(/\s+/)
    assert_equal 2, words.size
  end

  def test_korean
    skip_unless_espeak
    result = Tell::Espeak.ipa("\uC548\uB155\uD558\uC138\uC694", lang: "ko")
    assert result
    assert result.start_with?("/")
  end

  def test_empty_text_returns_nil
    skip_unless_espeak
    assert_nil Tell::Espeak.ipa("", lang: "sl")
  end

  def test_punctuation_only_returns_nil
    skip_unless_espeak
    assert_nil Tell::Espeak.ipa("...", lang: "sl")
  end

  def test_unsupported_language_returns_nil
    skip_unless_espeak
    assert_nil Tell::Espeak.ipa("hello", lang: "ja")
  end

  # --- ipa_words (word-level) ---

  def test_ipa_words_single_word
    skip_unless_espeak
    result = Tell::Espeak.ipa_words("dan", lang: "sl")
    assert result
    assert_match(/dˈaːn/, result)
  end

  def test_ipa_words_proclitic_not_merged
    skip_unless_espeak
    result = Tell::Espeak.ipa_words("sem bil v trgovini", lang: "sl")
    inner = result.delete_prefix("/").delete_suffix("/")
    words = inner.split(/\s+/)
    # "v" must be its own IPA word, not merged with "trgovini"
    assert_equal 4, words.size
  end

  def test_ipa_words_proclitic_with_punctuation
    skip_unless_espeak
    result = Tell::Espeak.ipa_words("To je lepo. Hvala!", lang: "sl")
    assert_includes result, "."
    assert_includes result, "!"
  end

  def test_ipa_words_matches_input_count
    skip_unless_espeak
    text = "Danes je lep dan"
    input_count = text.scan(Tell::Espeak::WORD_RE).size
    result = Tell::Espeak.ipa_words(text, lang: "sl")
    inner = result.delete_prefix("/").delete_suffix("/")
    ipa_count = inner.split(/\s+/).size
    assert_equal input_count, ipa_count
  end

  def test_ipa_words_unsupported_returns_nil
    skip_unless_espeak
    assert_nil Tell::Espeak.ipa_words("hello", lang: "ja")
  end

  # --- WORD_RE ---

  def test_word_regex_basic
    assert_equal %w[dober dan], "dober dan".scan(Tell::Espeak::WORD_RE)
  end

  def test_word_regex_with_punctuation
    assert_equal %w[dober dan kako ste], "dober dan, kako ste?".scan(Tell::Espeak::WORD_RE)
  end

  def test_word_regex_hyphenated
    assert_equal ["tako-rekoč", "je"], "tako-rekoč je".scan(Tell::Espeak::WORD_RE)
  end

  def test_word_regex_apostrophe
    assert_equal ["it's", "fine"], "it's fine".scan(Tell::Espeak::WORD_RE)
  end

  def test_word_regex_unicode
    assert_equal %w[Здравствуйте как дела], "Здравствуйте, как дела?".scan(Tell::Espeak::WORD_RE)
  end

  # --- ipa_from_kana ---

  def test_ipa_from_kana_hiragana
    skip_unless_espeak
    result = Tell::Espeak.ipa_from_kana("こんにちは")
    assert result
    assert result.start_with?("/")
    assert result.end_with?("/")
  end

  def test_ipa_from_kana_katakana
    skip_unless_espeak
    result = Tell::Espeak.ipa_from_kana("コーヒー")
    assert result
    assert result.start_with?("/")
  end

  def test_ipa_from_kana_with_nakaguro_separator
    skip_unless_espeak
    result = Tell::Espeak.ipa_from_kana("おげんき・です・か")
    assert result
    # ・ replaced with spaces, should produce multi-word output
    inner = result.delete_prefix("/").delete_suffix("/")
    words = inner.split(/\s+/)
    assert_operator words.size, :>=, 2
  end

  def test_ipa_from_kana_empty_returns_nil
    skip_unless_espeak
    assert_nil Tell::Espeak.ipa_from_kana("")
  end

  def test_ipa_from_kana_bypasses_unsupported
    skip_unless_espeak
    # Regular supports? returns false for ja, but ipa_from_kana works
    refute Tell::Espeak.supports?("ja")
    result = Tell::Espeak.ipa_from_kana("あいうえお")
    assert result
  end

  # --- voice mapping ---

  def test_chinese_maps_to_cmn
    assert_equal "cmn", Tell::Espeak.send(:voice_for, "zh")
  end

  def test_slovenian_maps_to_sl
    assert_equal "sl", Tell::Espeak.send(:voice_for, "sl")
  end

  def test_french_maps_to_fr_fr
    assert_equal "fr-fr", Tell::Espeak.send(:voice_for, "fr")
  end

  private

  def skip_unless_espeak
    skip "espeak-ng not installed" unless Tell::Espeak.available?
  end
end
