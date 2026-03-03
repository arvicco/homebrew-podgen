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
end
