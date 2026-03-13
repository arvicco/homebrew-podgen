# frozen_string_literal: true

require_relative "../test_helper"
require "tell/detector"

class TestTellDetector < Minitest::Test
  # --- Script-based detection ---

  def test_japanese_hiragana
    assert_equal "ja", Tell::Detector.detect("こんにちは世界、元気ですか")
  end

  def test_japanese_katakana
    assert_equal "ja", Tell::Detector.detect("カタカナのテスト文字列です")
  end

  def test_chinese_no_kana
    assert_equal "zh", Tell::Detector.detect("你好世界今天天气很好")
  end

  def test_korean
    assert_equal "ko", Tell::Detector.detect("안녕하세요 세계 오늘 날씨가 좋습니다")
  end

  def test_russian_cyrillic
    assert_equal "ru", Tell::Detector.detect("Привет мир как дела сегодня")
  end

  def test_ukrainian_cyrillic
    assert_equal "uk", Tell::Detector.detect("Привіт світ як справи сьогодні")
  end

  def test_arabic
    assert_equal "ar", Tell::Detector.detect("مرحبا بالعالم كيف حالك اليوم")
  end

  def test_hebrew
    assert_equal "he", Tell::Detector.detect("שלום עולם מה שלומך היום")
  end

  def test_thai
    assert_equal "th", Tell::Detector.detect("สวัสดีชาวโลกวันนี้เป็นอย่างไร")
  end

  def test_hindi_devanagari
    assert_equal "hi", Tell::Detector.detect("नमस्ते दुनिया आज कैसा है")
  end

  # --- Latin stop-word detection ---

  def test_english
    assert_equal "en", Tell::Detector.detect("this is a test of the English language which has many words")
  end

  def test_slovenian
    assert_equal "sl", Tell::Detector.detect("to je test slovenskega jezika ki ima tudi veliko besed")
  end

  def test_german
    assert_equal "de", Tell::Detector.detect("das ist ein Test der deutschen Sprache die viele Wörter hat")
  end

  def test_french
    assert_equal "fr", Tell::Detector.detect("les enfants sont dans une école avec des amis pour jouer")
  end

  def test_spanish
    assert_equal "es", Tell::Detector.detect("los niños están en una escuela con sus amigos para jugar")
  end

  # --- Edge cases ---

  def test_nil_input
    assert_nil Tell::Detector.detect(nil)
  end

  def test_empty_string
    assert_nil Tell::Detector.detect("")
  end

  def test_too_short
    assert_nil Tell::Detector.detect("hi")
  end

  def test_numbers_only
    assert_nil Tell::Detector.detect("12345 67890")
  end

  def test_mixed_script_japanese_wins
    # Japanese text with some ASCII — CJK should dominate
    assert_equal "ja", Tell::Detector.detect("今日はRubyのテストです hello")
  end

  # --- Characteristic character detection ---

  def test_characteristic_chars_slovenian
    assert Tell::Detector.has_characteristic_chars?("živjo", "sl")
    assert Tell::Detector.has_characteristic_chars?("škrati", "sl")
    assert Tell::Detector.has_characteristic_chars?("človek", "sl")
  end

  def test_characteristic_chars_not_english
    refute Tell::Detector.has_characteristic_chars?("hello world", "sl")
    refute Tell::Detector.has_characteristic_chars?("hello world", "de")
  end

  def test_characteristic_chars_german
    assert Tell::Detector.has_characteristic_chars?("Straße", "de")
    assert Tell::Detector.has_characteristic_chars?("über", "de")
  end

  def test_characteristic_chars_unknown_language
    refute Tell::Detector.has_characteristic_chars?("hello", "xx")
  end

  # --- Additional edge cases ---

  def test_exactly_five_chars_detected
    # Exactly 5 chars — should attempt detection (boundary)
    assert_equal "ja", Tell::Detector.detect("こんにちは")
  end

  def test_punctuation_only
    assert_nil Tell::Detector.detect("!!! ... ???")
  end

  def test_latin_fewer_than_three_words
    assert_nil Tell::Detector.detect("hello world")
  end

  def test_latin_exactly_three_words_no_stop_words
    # 3 words but none are stop words → nil
    assert_nil Tell::Detector.detect("banana mango kiwi")
  end

  def test_whitespace_only
    assert_nil Tell::Detector.detect("     ")
  end

  def test_mixed_cyrillic_with_ukrainian_chars
    # Ukrainian-specific chars present → "uk" even with mostly Russian chars
    assert_equal "uk", Tell::Detector.detect("Привіт як ти живеш сьогодні")
  end

  def test_cjk_without_kana_is_chinese
    assert_equal "zh", Tell::Detector.detect("今天是美好的一天我很开心")
  end

  # --- English stop-word coverage ---

  def test_english_short_common_words
    # Relies on newly-added stop words: a, and, in, for, of, to, not, but, it
    assert_equal "en", Tell::Detector.detect("a cat and a dog in a park for all of them")
  end

  def test_english_conjunctions_and_prepositions
    # Uses: but, not, if, so, or, by, on, at — all added in the expanded list
    assert_equal "en", Tell::Detector.detect("not by chance but if so then on or at noon")
  end

  def test_english_verb_forms
    # Uses: do, does, did, am, had, will, can — mix of old and new stop words
    assert_equal "en", Tell::Detector.detect("do you think it will work if we can try and did")
  end

  def test_english_vs_slovenian_disambiguation
    # Short English text should not be confused with Slovenian
    assert_equal "en", Tell::Detector.detect("it is not a problem but an opportunity for all of us")
  end

  # --- Latin double-counting guard ---

  def test_non_latin_script_chars_not_double_counted
    # Pure Cyrillic text — :latin count should be 0
    counts = Tell::Detector.dominant_script("Привет мир")
    assert_equal :cyrillic, counts
  end

  def test_mixed_cyrillic_latin_counts_correctly
    # Mostly Cyrillic with one Latin word — Cyrillic should dominate
    assert_equal "ru", Tell::Detector.detect("Привет мир сегодня hello тест")
  end

  # --- explanation? ---

  def test_explanation_latin_3x_triggers
    refute Tell::Detector.explanation?("hello", "dober dan")           # 2x
    assert Tell::Detector.explanation?("hello", "a" * 16)             # 3.2x
  end

  def test_explanation_cjk_uses_higher_threshold
    ja = "日本語テスト"  # 6 chars
    # 4x expansion is normal for CJK → Latin, should NOT be flagged
    refute Tell::Detector.explanation?(ja, "a" * 24)                  # 4x
    refute Tell::Detector.explanation?(ja, "a" * 48)                  # 8x
    assert Tell::Detector.explanation?(ja, "a" * 49)                  # >8x
  end

  def test_explanation_korean_uses_higher_threshold
    ko = "안녕하세요"  # 5 chars
    refute Tell::Detector.explanation?(ko, "a" * 40)                  # 8x
    assert Tell::Detector.explanation?(ko, "a" * 41)                  # >8x
  end
end
