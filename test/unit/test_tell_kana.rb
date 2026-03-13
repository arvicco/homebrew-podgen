# frozen_string_literal: true

require_relative "../test_helper"
require "tell/kana"

class TestTellKana < Minitest::Test
  # --- availability ---

  def test_available
    assert Tell::Kana.available?
  end

  def test_supports_japanese
    assert Tell::Kana.supports?("ja")
    assert Tell::Kana.supports?("ja", "hepburn")
    assert Tell::Kana.supports?("ja", "kunrei")
  end

  def test_does_not_support_other_languages
    refute Tell::Kana.supports?("zh")
    refute Tell::Kana.supports?("ko")
    refute Tell::Kana.supports?("en")
  end

  def test_does_not_support_unknown_system
    refute Tell::Kana.supports?("ja", "pinyin")
    refute Tell::Kana.supports?("ja", "bogus")
  end

  # --- basic Hepburn ---

  def test_hepburn_vowels
    assert_equal "aiueo", Tell::Kana.to_hepburn("あいうえお")
  end

  def test_hepburn_ka_row
    assert_equal "kakikukeko", Tell::Kana.to_hepburn("かきくけこ")
  end

  def test_hepburn_shi
    assert_equal "shi", Tell::Kana.to_hepburn("し")
  end

  def test_hepburn_chi
    assert_equal "chi", Tell::Kana.to_hepburn("ち")
  end

  def test_hepburn_tsu
    assert_equal "tsu", Tell::Kana.to_hepburn("つ")
  end

  def test_hepburn_fu
    assert_equal "fu", Tell::Kana.to_hepburn("ふ")
  end

  def test_hepburn_ji
    assert_equal "ji", Tell::Kana.to_hepburn("じ")
  end

  # --- basic Kunrei ---

  def test_kunrei_si
    assert_equal "si", Tell::Kana.to_kunrei("し")
  end

  def test_kunrei_ti
    assert_equal "ti", Tell::Kana.to_kunrei("ち")
  end

  def test_kunrei_tu
    assert_equal "tu", Tell::Kana.to_kunrei("つ")
  end

  def test_kunrei_hu
    assert_equal "hu", Tell::Kana.to_kunrei("ふ")
  end

  def test_kunrei_zi
    assert_equal "zi", Tell::Kana.to_kunrei("じ")
  end

  # --- digraphs ---

  def test_hepburn_sha
    assert_equal "sha", Tell::Kana.to_hepburn("しゃ")
  end

  def test_hepburn_cha
    assert_equal "cha", Tell::Kana.to_hepburn("ちゃ")
  end

  def test_hepburn_ja
    assert_equal "ja", Tell::Kana.to_hepburn("じゃ")
  end

  def test_kunrei_sya
    assert_equal "sya", Tell::Kana.to_kunrei("しゃ")
  end

  def test_kunrei_tya
    assert_equal "tya", Tell::Kana.to_kunrei("ちゃ")
  end

  def test_kunrei_zya
    assert_equal "zya", Tell::Kana.to_kunrei("じゃ")
  end

  def test_common_digraph_kyo
    assert_equal "kyo", Tell::Kana.to_hepburn("きょ")
    assert_equal "kyo", Tell::Kana.to_kunrei("きょ")
  end

  # --- gemination (っ) ---

  def test_hepburn_gemination_kitte
    assert_equal "kitte", Tell::Kana.to_hepburn("きって")
  end

  def test_hepburn_gemination_zasshi
    assert_equal "zasshi", Tell::Kana.to_hepburn("ざっし")
  end

  def test_kunrei_gemination_zassi
    assert_equal "zassi", Tell::Kana.to_kunrei("ざっし")
  end

  def test_gemination_before_chi
    assert_equal "macchi", Tell::Kana.to_hepburn("まっち")
  end

  # --- syllabic n before labials ---

  def test_hepburn_n_before_labial_shimbun
    assert_equal "shimbun", Tell::Kana.to_hepburn("しんぶん")
  end

  def test_kunrei_n_before_labial_sinbun
    assert_equal "sinbun", Tell::Kana.to_kunrei("しんぶん")
  end

  def test_hepburn_n_before_pa
    assert_equal "shimpa", Tell::Kana.to_hepburn("しんぱ")
  end

  def test_n_before_non_labial_stays_n
    assert_equal "kanto", Tell::Kana.to_hepburn("かんと")
  end

  # --- katakana ---

  def test_katakana_conversion
    assert_equal "koohii", Tell::Kana.to_hepburn("コーヒー")
  end

  def test_katakana_terebi
    assert_equal "terebi", Tell::Kana.to_hepburn("テレビ")
  end

  def test_katakana_anaunsaa
    assert_equal "anaunsaa", Tell::Kana.to_hepburn("アナウンサー")
  end

  # --- long vowels (ー) ---

  def test_choonpu_extends_vowel
    assert_equal "kaa", Tell::Kana.to_hepburn("カー")
  end

  def test_choonpu_after_o
    assert_equal "too", Tell::Kana.to_hepburn("トー")
  end

  # --- mixed/preserved content ---

  def test_spaces_preserved
    assert_equal "kyou ha ii tenki desu", Tell::Kana.to_hepburn("きょう は いい てんき です")
  end

  def test_punctuation_preserved
    assert_equal "hai。iie！", Tell::Kana.to_hepburn("はい。いいえ！")
  end

  def test_latin_preserved
    assert_equal "hello kyou", Tell::Kana.to_hepburn("hello きょう")
  end

  # --- full phrases ---

  def test_hepburn_konnichiwa
    assert_equal "konnichiha", Tell::Kana.to_hepburn("こんにちは")
  end

  def test_hepburn_ohayou
    assert_equal "ohayougozaimasu", Tell::Kana.to_hepburn("おはようございます")
  end

  def test_hepburn_arigatou
    assert_equal "arigatou", Tell::Kana.to_hepburn("ありがとう")
  end

  # --- foreign sounds (V-row, F-row, etc.) ---

  def test_hepburn_va
    assert_equal "va", Tell::Kana.to_hepburn("ゔぁ")
  end

  def test_hepburn_vi_ve_vo
    assert_equal "vi", Tell::Kana.to_hepburn("ゔぃ")
    assert_equal "ve", Tell::Kana.to_hepburn("ゔぇ")
    assert_equal "vo", Tell::Kana.to_hepburn("ゔぉ")
  end

  def test_hepburn_vu_standalone
    assert_equal "vu", Tell::Kana.to_hepburn("ゔ")
  end

  def test_hepburn_fa_fi_fe_fo
    assert_equal "fa", Tell::Kana.to_hepburn("ふぁ")
    assert_equal "fi", Tell::Kana.to_hepburn("ふぃ")
    assert_equal "fe", Tell::Kana.to_hepburn("ふぇ")
    assert_equal "fo", Tell::Kana.to_hepburn("ふぉ")
  end

  def test_hepburn_ti_di
    assert_equal "ti", Tell::Kana.to_hepburn("てぃ")
    assert_equal "di", Tell::Kana.to_hepburn("でぃ")
  end

  def test_hepburn_she_je_che
    assert_equal "she", Tell::Kana.to_hepburn("しぇ")
    assert_equal "je", Tell::Kana.to_hepburn("じぇ")
    assert_equal "che", Tell::Kana.to_hepburn("ちぇ")
  end

  def test_hepburn_wi_we_wo_foreign
    assert_equal "wi", Tell::Kana.to_hepburn("うぃ")
    assert_equal "we", Tell::Kana.to_hepburn("うぇ")
    assert_equal "wo", Tell::Kana.to_hepburn("うぉ")
  end

  def test_katakana_vu_va
    assert_equal "va", Tell::Kana.to_hepburn("ヴァ")
    assert_equal "vu", Tell::Kana.to_hepburn("ヴ")
  end

  def test_katakana_fa
    assert_equal "fa", Tell::Kana.to_hepburn("ファ")
  end

  def test_foreign_name_jiva
    assert_equal "jiva", Tell::Kana.to_hepburn("じゔぁ")
  end

  # --- basic IPA ---

  def test_supports_ipa
    assert Tell::Kana.supports?("ja", "ipa")
  end

  def test_ipa_vowels
    assert_equal "aiɯeo", Tell::Kana.to_ipa("あいうえお")
  end

  def test_ipa_ka_row
    assert_equal "kakikɯkeko", Tell::Kana.to_ipa("かきくけこ")
  end

  def test_ipa_special_consonants
    assert_equal "ɕi", Tell::Kana.to_ipa("し")
    assert_equal "tɕi", Tell::Kana.to_ipa("ち")
    assert_equal "tsɯ", Tell::Kana.to_ipa("つ")
    assert_equal "ɸɯ", Tell::Kana.to_ipa("ふ")
    assert_equal "çi", Tell::Kana.to_ipa("ひ")
  end

  def test_ipa_voiced_special
    assert_equal "dʑi", Tell::Kana.to_ipa("じ")
    assert_equal "dʑi", Tell::Kana.to_ipa("ぢ")
    assert_equal "dzɯ", Tell::Kana.to_ipa("づ")
  end

  def test_ipa_r_row
    assert_equal "ɾa", Tell::Kana.to_ipa("ら")
    assert_equal "ɾi", Tell::Kana.to_ipa("り")
    assert_equal "ɾɯ", Tell::Kana.to_ipa("る")
    assert_equal "ɾe", Tell::Kana.to_ipa("れ")
    assert_equal "ɾo", Tell::Kana.to_ipa("ろ")
  end

  def test_ipa_y_row
    assert_equal "ja", Tell::Kana.to_ipa("や")
    assert_equal "jɯ", Tell::Kana.to_ipa("ゆ")
    assert_equal "jo", Tell::Kana.to_ipa("よ")
  end

  def test_ipa_g_row
    assert_equal "ɡa", Tell::Kana.to_ipa("が")
    assert_equal "ɡi", Tell::Kana.to_ipa("ぎ")
    assert_equal "ɡɯ", Tell::Kana.to_ipa("ぐ")
    assert_equal "ɡe", Tell::Kana.to_ipa("げ")
    assert_equal "ɡo", Tell::Kana.to_ipa("ご")
  end

  def test_ipa_syllabic_n
    assert_equal "ɴ", Tell::Kana.to_ipa("ん")
  end

  def test_ipa_wo
    assert_equal "o", Tell::Kana.to_ipa("を")
  end

  # --- IPA digraphs ---

  def test_ipa_sibilant_digraphs
    assert_equal "ɕa", Tell::Kana.to_ipa("しゃ")
    assert_equal "tɕa", Tell::Kana.to_ipa("ちゃ")
    assert_equal "dʑa", Tell::Kana.to_ipa("じゃ")
  end

  def test_ipa_palatal_digraphs
    assert_equal "ɲa", Tell::Kana.to_ipa("にゃ")
    assert_equal "ça", Tell::Kana.to_ipa("ひゃ")
    assert_equal "ɾja", Tell::Kana.to_ipa("りゃ")
    assert_equal "kjo", Tell::Kana.to_ipa("きょ")
  end

  def test_ipa_fu_row_foreign
    assert_equal "ɸa", Tell::Kana.to_ipa("ふぁ")
    assert_equal "ɸi", Tell::Kana.to_ipa("ふぃ")
  end

  # --- IPA gemination ---

  def test_ipa_gemination
    assert_equal "kitte", Tell::Kana.to_ipa("きって")
  end

  def test_ipa_gemination_sibilant
    assert_equal "ɕɕi", Tell::Kana.to_ipa("っし")
  end

  # --- IPA syllabic N: no labial assimilation ---

  def test_ipa_n_before_labial_no_assimilation
    assert_equal "ɕiɴbɯɴ", Tell::Kana.to_ipa("しんぶん")
  end

  # --- IPA chōonpu (ー) → ː ---

  def test_ipa_choonpu_length_mark
    assert_equal "koːçiː", Tell::Kana.to_ipa("コーヒー")
  end

  def test_ipa_choonpu_raamen
    assert_equal "ɾaːmeɴ", Tell::Kana.to_ipa("ラーメン")
  end

  # --- IPA katakana ---

  def test_ipa_katakana
    assert_equal "teɾebi", Tell::Kana.to_ipa("テレビ")
  end

  # --- IPA full phrase ---

  def test_ipa_phrase_with_spaces
    assert_equal "kjoɯ wa ii teɴki desɯ", Tell::Kana.to_ipa("きょう わ いい てんき です")
  end

  # --- to_romaji with system param ---

  def test_to_romaji_hepburn
    assert_equal "shi", Tell::Kana.to_romaji("し", system: "hepburn")
  end

  def test_to_romaji_kunrei
    assert_equal "si", Tell::Kana.to_romaji("し", system: "kunrei")
  end

  def test_to_romaji_ipa
    assert_equal "ɕi", Tell::Kana.to_romaji("し", system: "ipa")
  end

  def test_to_romaji_unknown_system_raises
    assert_raises(ArgumentError) { Tell::Kana.to_romaji("し", system: "bogus") }
  end
end
