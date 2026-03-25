# frozen_string_literal: true

require_relative "../test_helper"
require "tell/japanese_brackets"
require "tell/kana"

class TestTellJapaneseBrackets < Minitest::Test
  include Tell::JapaneseBrackets

  # ===== fix_particle_readings =====

  def test_fix_particle_ha_standalone
    gloss = "は[は](part.top)TOP"
    assert_equal "は[わ](part.top)TOP", fix_particle_readings(gloss)
  end

  def test_fix_particle_dewa_compound
    gloss = "では[では](part.cop.top)COP.TOP"
    assert_equal "では[でわ](part.cop.top)COP.TOP", fix_particle_readings(gloss)
  end

  def test_fix_particle_niwa_compound
    gloss = "には[には](part)in.TOP"
    assert_equal "には[にわ](part)in.TOP", fix_particle_readings(gloss)
  end

  def test_fix_particle_he_directional
    gloss = "へ[へ](part)to"
    assert_equal "へ[え](part)to", fix_particle_readings(gloss)
  end

  def test_fix_particle_skips_non_particle
    gloss = "話[はなし](n.sg)story"
    assert_equal gloss, fix_particle_readings(gloss)
  end

  def test_fix_particle_skips_already_correct
    gloss = "は[わ](part.top)TOP"
    assert_equal gloss, fix_particle_readings(gloss)
  end

  # ===== strip_redundant_brackets =====

  def test_strip_redundant_brackets_removes_identical
    gloss = "ただ[ただ](adv)merely の[の](part)GEN"
    assert_equal "ただ(adv)merely の(part)GEN", strip_redundant_brackets(gloss)
  end

  def test_strip_redundant_brackets_keeps_different
    gloss = "は[わ](part)TOP お別れ[おわかれ](n)farewell"
    assert_equal gloss, strip_redundant_brackets(gloss)
  end

  def test_strip_redundant_brackets_mixed
    gloss = "これ[これ](pron)this は[わ](part)TOP 番組[ばんぐみ](n)program"
    assert_equal "これ(pron)this は[わ](part)TOP 番組[ばんぐみ](n)program", strip_redundant_brackets(gloss)
  end

  def test_strip_redundant_brackets_latin_script
    gloss = "hello[hello](n)hi world[wɜːrld](n)world"
    assert_equal "hello(n)hi world[wɜːrld](n)world", strip_redundant_brackets(gloss)
  end

  # ===== align_bracket_readings =====

  def test_align_preserves_hiragana_consumes_ph_position
    gloss = "これ[これ](pron.sg)this は[は](part)TOP 天気[てんき](n)weather"
    result = align_bracket_readings(gloss, "これ・わ・てんき")
    assert_includes result, "これ[これ]"
    assert_includes result, "は[は]"
    assert_includes result, "天気[てんき]"
  end

  def test_align_handles_different_segmentation
    gloss = "ただ[ただ](adv) の[の](part) 番組[ばんぐみ](n)"
    result = align_bracket_readings(gloss, "ただの・ばんぐみ")
    assert_includes result, "ただ[ただ]"
    assert_includes result, "の[の]"
    assert_includes result, "番組[ばんぐみ]"
  end

  def test_align_kanji_readings_correct_with_hiragana_gaps
    gloss = "お別れ[おわかれ](n) で[で](part) は[は](part) ありません[ありません](v)"
    result = align_bracket_readings(gloss, "おわかれ・でわ・ありません")
    assert_includes result, "お別れ[おわかれ]"
    assert_includes result, "で[で]"
    assert_includes result, "は[は]"
    assert_includes result, "ありません[ありません]"
  end

  def test_align_preserves_hiragana_words_from_ai_rewrite
    gloss = "お願い[おねがい](n) くださる[くださる](v)"
    result = align_bracket_readings(gloss, "おねがい・ください")
    assert_includes result, "お願い[おねがい]"
    assert_includes result, "くださる[くださる]"
    refute_includes result, "[ください]"
  end

  def test_align_replaces_kanji_readings_but_not_hiragana
    gloss = "今日[きょう](n) は[は](part) いい[いい](adj) 天気[てんき](n)"
    result = align_bracket_readings(gloss, "きょう・わ・いい・てんき")
    assert_includes result, "今日[きょう]"
    assert_includes result, "天気[てんき]"
    assert_includes result, "は[は]"
    assert_includes result, "いい[いい]"
  end

  def test_align_out_of_bounds_keeps_original
    gloss = "これ[これ](pron) は[は](part) 長い[ながい](adj)"
    result = align_bracket_readings(gloss, "これ・わ")
    assert_includes result, "は[は]"
    assert_includes result, "長い[ながい]"
  end

  # ===== ensure_all_brackets =====

  def test_ensure_all_brackets_inserts_for_hiragana_words
    gloss = "今日[きょう](today) は(part)TOP こと(n.sg)thing"
    assert_equal "今日[きょう](today) は[は](part)TOP こと[こと](n.sg)thing", ensure_all_brackets(gloss)
  end

  def test_ensure_all_brackets_skips_kanji_words
    gloss = "今日(today) 元気(healthy)"
    assert_equal gloss, ensure_all_brackets(gloss)
  end

  def test_ensure_all_brackets_preserves_existing_brackets
    gloss = "今日[きょう](today) は[わ](part)"
    assert_equal gloss, ensure_all_brackets(gloss)
  end

  def test_ensure_all_brackets_handles_correction_markers
    gloss = "*わたし*わたくし(pron.1p) は(part)TOP"
    assert_includes ensure_all_brackets(gloss), "は[は](part)"
  end

  # ===== build_gloss_bracket_cache =====

  def test_build_gloss_bracket_cache_extracts_and_converts
    gloss = "今日[きょう](today) は[わ](topic) 元気[げんき](healthy)"
    result = build_gloss_bracket_cache(gloss)
    assert_equal %w[きょう わ げんき], result["hiragana"]
    assert_equal 3, result["hepburn"].size
    assert_equal 3, result["kunrei"].size
    assert_equal 3, result["ipa"].size
    assert result["ipa"].all? { |r| !r.nil? && !r.empty? }
  end

  def test_build_gloss_bracket_cache_returns_nil_without_brackets
    result = build_gloss_bracket_cache("今日(today) です(copula)")
    assert_nil result
  end

  def test_build_gloss_bracket_cache_ipa_uses_kana_not_espeak
    gloss = "食[た]べ(v.inf)"
    result = build_gloss_bracket_cache(gloss)
    assert_equal ["ta"], result["ipa"]
  end

  # ===== convert_gloss_brackets =====

  def test_convert_gloss_brackets_to_hepburn
    gloss = "今日[きょう](today)"
    result = convert_gloss_brackets(gloss, "hepburn")
    assert_includes result, "[kyou]"
  end

  def test_convert_gloss_brackets_to_ipa
    gloss = "食[た]べ(v.inf)"
    result = convert_gloss_brackets(gloss, "ipa")
    assert_includes result, "[ta]"
  end
end
