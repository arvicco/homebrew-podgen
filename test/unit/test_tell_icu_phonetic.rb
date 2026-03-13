# frozen_string_literal: true

require_relative "../test_helper"
require "tell/icu_phonetic"

class TestTellIcuPhonetic < Minitest::Test
  # --- availability ---

  def test_available_when_ffi_icu_installed
    assert Tell::IcuPhonetic.available?
  end

  # --- supports? ---

  def test_supports_russian_scholarly
    assert Tell::IcuPhonetic.supports?("ru", "scholarly")
  end

  def test_supports_russian_simple
    assert Tell::IcuPhonetic.supports?("ru", "simple")
  end

  def test_supports_ukrainian_scholarly
    assert Tell::IcuPhonetic.supports?("uk", "scholarly")
  end

  def test_supports_greek_elot
    assert Tell::IcuPhonetic.supports?("el", "elot")
  end

  def test_supports_korean_revised
    assert Tell::IcuPhonetic.supports?("ko", "rr")
  end

  def test_does_not_support_unknown_language
    refute Tell::IcuPhonetic.supports?("xx", "scholarly")
  end

  def test_does_not_support_unknown_system
    refute Tell::IcuPhonetic.supports?("ru", "ipa")
  end

  def test_does_not_support_japanese
    refute Tell::IcuPhonetic.supports?("ja", "hiragana")
  end

  # --- Cyrillic scholarly ---

  def test_russian_scholarly
    result = Tell::IcuPhonetic.transliterate("Привет, как дела?", lang: "ru", system: "scholarly")
    assert_equal "Privet, kak dela?", result
  end

  def test_ukrainian_scholarly
    result = Tell::IcuPhonetic.transliterate("Привіт, як справи?", lang: "uk", system: "scholarly")
    assert_equal "Pryvit, yak spravy?", result
  end

  def test_bulgarian_scholarly
    result = Tell::IcuPhonetic.transliterate("Здравейте", lang: "bg", system: "scholarly")
    assert_includes result, "Zdrave"
  end

  def test_serbian_scholarly
    result = Tell::IcuPhonetic.transliterate("Здраво, како сте?", lang: "sr", system: "scholarly")
    assert_includes result, "Zdravo"
  end

  def test_macedonian_scholarly
    result = Tell::IcuPhonetic.transliterate("Здраво", lang: "mk", system: "scholarly")
    assert_includes result, "Zdravo"
  end

  def test_belarusian_scholarly
    result = Tell::IcuPhonetic.transliterate("Добры дзень", lang: "be", system: "scholarly")
    assert_includes result, "Dobry"
  end

  # --- Cyrillic simple (no diacritics) ---

  def test_russian_simple
    result = Tell::IcuPhonetic.transliterate("Привет, как дела?", lang: "ru", system: "simple")
    assert_equal "Privet, kak dela?", result
    # Simple should have no diacritics
    refute_match(/[ĭĬěĚ]/, result)
  end

  def test_ukrainian_simple_strips_diacritics
    scholarly = Tell::IcuPhonetic.transliterate("Привіт", lang: "uk", system: "scholarly")
    simple = Tell::IcuPhonetic.transliterate("Привіт", lang: "uk", system: "simple")
    # Simple should be ASCII-only
    assert simple.bytes.all? { |b| b < 128 }, "Expected ASCII-only, got: #{simple}"
    assert_equal simple.length, simple.bytes.size
  end

  # --- Greek ---

  def test_greek_elot
    result = Tell::IcuPhonetic.transliterate("Καλημέρα, τι κάνεις;", lang: "el", system: "elot")
    assert_includes result, "méra"
    assert_includes result, "káneis"
  end

  # --- Korean ---

  def test_korean_revised
    result = Tell::IcuPhonetic.transliterate("안녕하세요", lang: "ko", system: "rr")
    assert_equal "annyeonghaseyo", result
  end

  def test_korean_revised_gamsahamnida
    result = Tell::IcuPhonetic.transliterate("감사합니다", lang: "ko", system: "rr")
    assert_equal "gamsahabnida", result
  end

  # --- edge cases ---

  def test_empty_text_returns_nil
    assert_nil Tell::IcuPhonetic.transliterate("", lang: "ru", system: "scholarly")
  end

  def test_whitespace_only_returns_nil
    assert_nil Tell::IcuPhonetic.transliterate("   ", lang: "ru", system: "scholarly")
  end

  def test_unsupported_pair_returns_nil
    assert_nil Tell::IcuPhonetic.transliterate("hello", lang: "en", system: "simple")
  end

  def test_punctuation_preserved
    result = Tell::IcuPhonetic.transliterate("Привет! Как дела? Хорошо.", lang: "ru", system: "scholarly")
    assert_includes result, "!"
    assert_includes result, "?"
    assert_includes result, "."
  end
end
