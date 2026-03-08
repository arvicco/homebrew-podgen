# frozen_string_literal: true

require_relative "../test_helper"
require "tell/hints"

class TestTellHints < Minitest::Test
  # --- parse ---

  def test_no_hints
    r = Tell::Hints.parse("hello world")
    assert_equal "hello world", r.text
    assert_nil r.formality
    assert_nil r.gender
    refute r.hints?
  end

  def test_polite_male
    r = Tell::Hints.parse("hello /pm")
    assert_equal "hello", r.text
    assert_equal :polite, r.formality
    assert_equal :male, r.gender
    assert r.hints?
  end

  def test_casual_female
    r = Tell::Hints.parse("hello /cf")
    assert_equal "hello", r.text
    assert_equal :casual, r.formality
    assert_equal :female, r.gender
  end

  def test_very_formal
    r = Tell::Hints.parse("hello /v")
    assert_equal "hello", r.text
    assert_equal :very_formal, r.formality
    assert_nil r.gender
  end

  def test_humble_female
    r = Tell::Hints.parse("hello /hf")
    assert_equal "hello", r.text
    assert_equal :humble, r.formality
    assert_equal :female, r.gender
  end

  def test_gender_only
    r = Tell::Hints.parse("hello /m")
    assert_equal "hello", r.text
    assert_nil r.formality
    assert_equal :male, r.gender
    assert r.hints?
  end

  def test_flag_order_independent
    r1 = Tell::Hints.parse("hello /mp")
    r2 = Tell::Hints.parse("hello /pm")
    assert_equal r1.formality, r2.formality
    assert_equal r1.gender, r2.gender
  end

  def test_invalid_flags_no_match
    r = Tell::Hints.parse("hello /xyz")
    assert_equal "hello /xyz", r.text
    refute r.hints?
  end

  def test_mixed_valid_invalid_no_match
    r = Tell::Hints.parse("hello /pd")
    assert_equal "hello /pd", r.text
    refute r.hints?
  end

  def test_no_space_before_slash_still_matches
    r = Tell::Hints.parse("hello/pm")
    assert_equal "hello", r.text
    assert_equal :polite, r.formality
    assert_equal :male, r.gender
  end

  def test_punctuation_before_slash_matches
    r = Tell::Hints.parse("dal gol./f")
    assert_equal "dal gol.", r.text
    assert_nil r.formality
    assert_equal :female, r.gender
  end

  def test_hint_only_returns_empty_text
    r = Tell::Hints.parse("/pm")
    assert_equal "", r.text
    assert_equal :polite, r.formality
    assert_equal :male, r.gender
  end

  def test_multiword_text
    r = Tell::Hints.parse("how are you today /cf")
    assert_equal "how are you today", r.text
    assert_equal :casual, r.formality
    assert_equal :female, r.gender
  end

  def test_url_not_matched
    r = Tell::Hints.parse("check http://example.com/pm")
    assert_equal "check http://example.com/pm", r.text
    refute r.hints?
  end

  def test_polite_neuter
    r = Tell::Hints.parse("hello /pn")
    assert_equal "hello", r.text
    assert_equal :polite, r.formality
    assert_equal :neuter, r.gender
  end

  def test_neuter_only
    r = Tell::Hints.parse("hello /n")
    assert_equal "hello", r.text
    assert_nil r.formality
    assert_equal :neuter, r.gender
    assert r.hints?
  end

  def test_first_formality_wins
    # /pc has both polite and casual — first match wins
    r = Tell::Hints.parse("hello /pc")
    assert_equal :polite, r.formality
  end

  def test_first_gender_wins
    # /mf has both male and female — first match wins
    r = Tell::Hints.parse("hello /mf")
    assert_equal :male, r.gender
  end

  # --- parse: Unicode scripts ---

  def test_cyrillic_male
    r = Tell::Hints.parse("позорище ты эдакое/m")
    assert_equal "позорище ты эдакое", r.text
    assert_equal :male, r.gender
  end

  def test_cyrillic_polite_female
    r = Tell::Hints.parse("Да что ты понимаешь/pf")
    assert_equal "Да что ты понимаешь", r.text
    assert_equal :polite, r.formality
    assert_equal :female, r.gender
  end

  def test_japanese_polite_female
    r = Tell::Hints.parse("こんにちは/pf")
    assert_equal "こんにちは", r.text
    assert_equal :polite, r.formality
    assert_equal :female, r.gender
  end

  def test_korean_casual
    r = Tell::Hints.parse("안녕하세요/c")
    assert_equal "안녕하세요", r.text
    assert_equal :casual, r.formality
  end

  def test_chinese_male
    r = Tell::Hints.parse("你好世界/m")
    assert_equal "你好世界", r.text
    assert_equal :male, r.gender
  end

  def test_arabic_female
    r = Tell::Hints.parse("مرحبا/f")
    assert_equal "مرحبا", r.text
    assert_equal :female, r.gender
  end

  def test_hebrew_male
    r = Tell::Hints.parse("שלום/m")
    assert_equal "שלום", r.text
    assert_equal :male, r.gender
  end

  def test_devanagari_polite
    r = Tell::Hints.parse("नमस्ते/p")
    assert_equal "नमस्ते", r.text
    assert_equal :polite, r.formality
  end

  def test_thai_casual
    r = Tell::Hints.parse("สวัสดี/c")
    assert_equal "สวัสดี", r.text
    assert_equal :casual, r.formality
  end

  def test_cyrillic_with_space_before_hint
    r = Tell::Hints.parse("привет мир /pm")
    assert_equal "привет мир", r.text
    assert_equal :polite, r.formality
    assert_equal :male, r.gender
  end

  # --- to_instruction ---

  def test_instruction_polite_male
    hints = Tell::Hints::Result.new(text: "", formality: :polite, gender: :male)
    inst = Tell::Hints.to_instruction(hints)
    assert_includes inst, "polite/formal register"
    assert_includes inst, "vikanje"
    assert_includes inst, "speaker is male"
    assert_includes inst, "masculine grammatical gender"
    assert_includes inst, "do NOT invent gendered forms"
  end

  def test_instruction_casual_female
    hints = Tell::Hints::Result.new(text: "", formality: :casual, gender: :female)
    inst = Tell::Hints.to_instruction(hints)
    assert_includes inst, "casual/informal register"
    assert_includes inst, "tikanje"
    assert_includes inst, "speaker is female"
    assert_includes inst, "feminine grammatical gender"
    assert_includes inst, "do NOT invent gendered forms"
  end

  def test_instruction_very_formal
    hints = Tell::Hints::Result.new(text: "", formality: :very_formal, gender: nil)
    inst = Tell::Hints.to_instruction(hints)
    assert_includes inst, "very formal/honorific register"
    assert_includes inst, "sonkeigo"
  end

  def test_instruction_humble
    hints = Tell::Hints::Result.new(text: "", formality: :humble, gender: nil)
    inst = Tell::Hints.to_instruction(hints)
    assert_includes inst, "humble/deferential register"
    assert_includes inst, "kenjōgo"
  end

  def test_instruction_gender_only_female
    hints = Tell::Hints::Result.new(text: "", formality: nil, gender: :female)
    inst = Tell::Hints.to_instruction(hints)
    assert_includes inst, "feminine grammatical gender"
  end

  def test_instruction_gender_only_male
    hints = Tell::Hints::Result.new(text: "", formality: nil, gender: :male)
    inst = Tell::Hints.to_instruction(hints)
    assert_includes inst, "masculine grammatical gender"
  end

  def test_instruction_gender_only_neuter
    hints = Tell::Hints::Result.new(text: "", formality: nil, gender: :neuter)
    inst = Tell::Hints.to_instruction(hints)
    assert_includes inst, "neuter grammatical gender"
  end

  def test_instruction_nil_hints
    assert_nil Tell::Hints.to_instruction(nil)
  end

  def test_instruction_no_hints
    hints = Tell::Hints::Result.new(text: "", formality: nil, gender: nil)
    assert_nil Tell::Hints.to_instruction(hints)
  end

  # --- deepl_formality ---

  def test_deepl_polite
    hints = Tell::Hints::Result.new(text: "", formality: :polite, gender: nil)
    assert_equal "prefer_more", Tell::Hints.deepl_formality(hints)
  end

  def test_deepl_very_formal
    hints = Tell::Hints::Result.new(text: "", formality: :very_formal, gender: nil)
    assert_equal "prefer_more", Tell::Hints.deepl_formality(hints)
  end

  def test_deepl_casual
    hints = Tell::Hints::Result.new(text: "", formality: :casual, gender: nil)
    assert_equal "prefer_less", Tell::Hints.deepl_formality(hints)
  end

  def test_deepl_humble_unmappable
    hints = Tell::Hints::Result.new(text: "", formality: :humble, gender: nil)
    assert_nil Tell::Hints.deepl_formality(hints)
  end

  def test_deepl_nil_hints
    assert_nil Tell::Hints.deepl_formality(nil)
  end

  def test_deepl_no_formality
    hints = Tell::Hints::Result.new(text: "", formality: nil, gender: :male)
    assert_nil Tell::Hints.deepl_formality(hints)
  end
end
