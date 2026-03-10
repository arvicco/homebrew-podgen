# frozen_string_literal: true

require_relative "../test_helper"
require "tell/glosser"

class TestTellGlosser < Minitest::Test
  def test_gloss_sends_prompt_with_grammar_abbreviations
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("danes(adv)today je(v.aux.3p.pres.sg)is lep(adj.m.N.sg)beautiful dan(n.m.N.sg)day")
    glosser.instance_variable_set(:@client, client)

    result = glosser.gloss("danes je lep dan", from: "sl", to: "en")

    assert_equal "danes(adv)today je(v.aux.3p.pres.sg)is lep(adj.m.N.sg)beautiful dan(n.m.N.sg)day", result
    assert_equal 1, client.calls.size
    assert_includes client.calls.first[:content], "interlinear gloss"
    assert_includes client.calls.first[:content], "Agrammatical forms"
  end

  def test_gloss_translate_sends_prompt_with_translations
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("danes(adv)today je(v.aux.3p.pres.sg)is")
    glosser.instance_variable_set(:@client, client)

    result = glosser.gloss_translate("danes je", from: "sl", to: "en")

    assert_equal "danes(adv)today je(v.aux.3p.pres.sg)is", result
    assert_includes client.calls.first[:content], "translations"
    assert_includes client.calls.first[:content], "Agrammatical forms"
  end

  def test_reconcile_sends_all_model_outputs
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("reconciled(adj.m.N.sg) result(n.m.N.sg)")
    glosser.instance_variable_set(:@client, client)

    glosses = {
      "claude-opus-4-6"   => "*restavraciju*restavracijo(n.f.A.sg) opus(n.m.N.sg)",
      "claude-sonnet-4-6" => "restavraciju(n.f.A.sg) sonnet(n.m.N.sg)"
    }

    result = glosser.reconcile(glosses, "restavraciju", from: "sl", to: "en", mode: :gloss)

    assert_equal "reconciled(adj.m.N.sg) result(n.m.N.sg)", result
    prompt = client.calls.first[:content]
    assert_includes prompt, "=== claude-opus-4-6 ==="
    assert_includes prompt, "=== claude-sonnet-4-6 ==="
    assert_includes prompt, "reconciliation expert"
    assert_includes prompt, "multiple models agree"
  end

  def test_reconcile_gloss_translate_mode_includes_translation_format
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("word(n.m.N.sg)translation")
    glosser.instance_variable_set(:@client, client)

    glosses = { "model1" => "a(n)x", "model2" => "a(n)y" }
    glosser.reconcile(glosses, "a", from: "sl", to: "en", mode: :gloss_translate)

    prompt = client.calls.first[:content]
    assert_includes prompt, "word(grammar)translation"
  end

  def test_reconcile_gloss_mode_uses_plain_format
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("word(n.m.N.sg)")
    glosser.instance_variable_set(:@client, client)

    glosses = { "model1" => "a(n)", "model2" => "a(n)" }
    glosser.reconcile(glosses, "a", from: "sl", to: "en", mode: :gloss)

    prompt = client.calls.first[:content]
    assert_includes prompt, "word(grammar)"
    refute_includes prompt, "word(grammar)translation"
  end

  # --- Model param ---

  def test_gloss_uses_configured_model
    glosser = Tell::Glosser.new("fake_key", model: "claude-sonnet-4-6")
    client = MockAnthropicClient.new("result(n)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss("test", from: "sl", to: "en")

    assert_equal "claude-sonnet-4-6", client.calls.first[:model]
  end

  def test_gloss_translate_uses_configured_model
    glosser = Tell::Glosser.new("fake_key", model: "claude-haiku-4-5-20251001")
    client = MockAnthropicClient.new("result(n)word")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_translate("test", from: "sl", to: "en")

    assert_equal "claude-haiku-4-5-20251001", client.calls.first[:model]
  end

  def test_reconcile_uses_configured_model
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("reconciled(n)")
    glosser.instance_variable_set(:@client, client)

    glosser.reconcile({ "m1" => "a(n)" }, "a", from: "sl", to: "en", mode: :gloss)

    assert_equal "claude-opus-4-6", client.calls.first[:model]
  end

  # --- Language name resolution ---

  def test_gloss_uses_language_names_for_known_codes
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("result(n)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss("test", from: "sl", to: "en")

    assert_includes client.calls.first[:content], "Slovenian"
  end

  def test_gloss_falls_back_to_code_for_unknown_language
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("result(n)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss("test", from: "xx", to: "yy")

    assert_includes client.calls.first[:content], "xx"
  end

  # --- Phonetic omission for Latin vs non-Latin scripts ---

  def test_gloss_phonetic_latin_source_omits_latin_script_rule
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("word[ˈwɜːrd](n.m.N.sg)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_phonetic("dober dan", from: "sl", to: "en")

    prompt = client.calls.first[:content]
    refute_includes prompt, "Latin-script words"
  end

  def test_gloss_phonetic_non_latin_source_includes_latin_script_rule
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("слово[ˈsɫovə](n.n.N.sg)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_phonetic("слово", from: "ru", to: "en")

    prompt = client.calls.first[:content]
    assert_includes prompt, "Latin-script words"
  end

  def test_gloss_translate_phonetic_latin_source_omits_latin_script_rule
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("word[ˈwɜːrd](n.m.N.sg)translation")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_translate_phonetic("dober dan", from: "sl", to: "ru")

    prompt = client.calls.first[:content]
    refute_includes prompt, "Latin-script words"
  end

  def test_gloss_translate_phonetic_non_latin_source_includes_latin_script_rule
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("слово[ˈsɫovə](n.n.N.sg)word")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_translate_phonetic("слово", from: "ru", to: "en")

    prompt = client.calls.first[:content]
    assert_includes prompt, "Latin-script words"
  end

  # --- Phonetic reference in gloss prompt ---

  def test_gloss_phonetic_with_ref_includes_reference_in_prompt
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("dober[ˈdɔːbər](adj.m.N.sg) dan[dan](n.m.N.sg)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_phonetic("dober dan", from: "sl", to: "en", phonetic_ref: "/ˈdɔːbər dan/")

    prompt = client.calls.first[:content]
    assert_includes prompt, "pre-computed phonetic transcription"
    assert_includes prompt, "/ˈdɔːbər dan/"
  end

  def test_gloss_translate_phonetic_with_ref_includes_reference_in_prompt
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("dober[ˈdɔːbər](adj.m.N.sg)good dan[dan](n.m.N.sg)day")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_translate_phonetic("dober dan", from: "sl", to: "en", phonetic_ref: "/ˈdɔːbər dan/")

    prompt = client.calls.first[:content]
    assert_includes prompt, "pre-computed phonetic transcription"
  end

  def test_gloss_phonetic_without_ref_omits_reference
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("dober[ˈdɔːbər](adj.m.N.sg)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_phonetic("dober", from: "sl", to: "en")

    prompt = client.calls.first[:content]
    refute_includes prompt, "pre-computed phonetic transcription"
  end

  # --- Phonetic splitting ---

  def test_split_phonetic_ipa_with_slashes
    readings = Tell::Glosser.split_phonetic("/ˈdɔːbər dan/", lang: "sl")
    assert_equal %w[ˈdɔːbər dan], readings
  end

  def test_split_phonetic_ipa_without_slashes
    readings = Tell::Glosser.split_phonetic("ˈdɔːbər dan", lang: "sl")
    assert_equal %w[ˈdɔːbər dan], readings
  end

  def test_split_phonetic_japanese_middle_dots
    readings = Tell::Glosser.split_phonetic("こんにちは・せかい・げんき", lang: "ja")
    assert_equal %w[こんにちは せかい げんき], readings
  end

  def test_split_phonetic_japanese_with_spaces_around_dots
    readings = Tell::Glosser.split_phonetic("こんにちは ・ せかい", lang: "ja")
    assert_equal %w[こんにちは せかい], readings
  end

  def test_split_phonetic_chinese_pinyin
    readings = Tell::Glosser.split_phonetic("nǐ hǎo shì jiè", lang: "zh")
    assert_equal %w[nǐ hǎo shì jiè], readings
  end

  def test_split_phonetic_korean_romanization
    readings = Tell::Glosser.split_phonetic("annyeong sesang", lang: "ko")
    assert_equal %w[annyeong sesang], readings
  end

  def test_split_phonetic_russian_romanization
    readings = Tell::Glosser.split_phonetic("privet mir", lang: "ru")
    assert_equal %w[privet mir], readings
  end

  # --- Mechanical merge ---

  def test_merge_phonetic_basic_gloss
    gloss = "Po(pr) odmoru(n.m.L.sg)"
    phonetic = "/pɔ ɔdˈmɔːru/"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "sl")
    assert_equal "Po[pɔ](pr) odmoru[ɔdˈmɔːru](n.m.L.sg)", result
  end

  def test_merge_phonetic_gloss_translate
    gloss = "Po(pr)after odmoru(n.m.L.sg)break"
    phonetic = "/pɔ ɔdˈmɔːru/"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "sl")
    assert_equal "Po[pɔ](pr)after odmoru[ɔdˈmɔːru](n.m.L.sg)break", result
  end

  def test_merge_phonetic_with_punctuation
    gloss = 'Po(pr)after , odmoru(n.m.L.sg)break .'
    phonetic = "/pɔ ɔdˈmɔːru/"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "sl")
    assert_equal 'Po[pɔ](pr)after , odmoru[ɔdˈmɔːru](n.m.L.sg)break .', result
  end

  def test_merge_phonetic_with_agrammatical
    gloss = "*napačno*pravilno(adj.m.N.sg)correct besedo(n.f.A.sg)word"
    phonetic = "/praˈviːlnɔ bɛˈsɛːdɔ/"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "sl")
    assert_equal "*napačno*pravilno[praˈviːlnɔ](adj.m.N.sg)correct besedo[bɛˈsɛːdɔ](n.f.A.sg)word", result
  end

  def test_merge_phonetic_japanese
    gloss = "今日は(n.sg)today 世界(n.sg)world"
    phonetic = "きょうは・せかい"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "ja")
    assert_equal "今日は[きょうは](n.sg)today 世界[せかい](n.sg)world", result
  end

  def test_merge_phonetic_chinese
    gloss = "你(pron.2p.sg) 好(adj)"
    phonetic = "nǐ hǎo"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "zh")
    assert_equal "你[nǐ](pron.2p.sg) 好[hǎo](adj)", result
  end

  def test_merge_phonetic_count_mismatch_returns_nil
    gloss = "Po(pr) odmoru(n.m.L.sg) med(pr)"
    phonetic = "/pɔ ɔdˈmɔːru/"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "sl")
    assert_nil result
  end

  def test_merge_phonetic_empty_phonetic_returns_nil
    gloss = "Po(pr)"
    phonetic = "  "
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "sl")
    assert_nil result
  end

  def test_merge_phonetic_no_gloss_words_returns_nil
    gloss = ", . !"
    phonetic = "/pɔ/"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "sl")
    assert_nil result
  end

  # --- Phonetic uses configured model ---

  def test_phonetic_uses_configured_model
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("/ˈdɔbɛr ˈdan/")
    glosser.instance_variable_set(:@client, client)

    glosser.phonetic("dober dan", lang: "sl")

    assert_equal "claude-opus-4-6", client.calls.first[:model]
  end

  # --- Response stripping ---

  def test_gloss_strips_whitespace_from_response
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("  result(n.m.N.sg)  \n")
    glosser.instance_variable_set(:@client, client)

    result = glosser.gloss("test", from: "sl", to: "en")

    assert_equal "result(n.m.N.sg)", result
  end

  # --- Phonetic systems lookup ---

  def test_systems_for_known_language
    systems = Tell::Glosser.systems_for("ja")
    assert_equal %w[hiragana hepburn ipa], systems.keys
  end

  def test_systems_for_unknown_language_returns_default
    systems = Tell::Glosser.systems_for("xx")
    assert_equal %w[ipa simple], systems.keys
  end

  def test_systems_for_shared_cyrillic
    %w[ru uk bg sr mk be].each do |lang|
      systems = Tell::Glosser.systems_for(lang)
      assert_equal %w[scholarly simple ipa], systems.keys, "Failed for #{lang}"
    end
  end

  def test_systems_for_shared_indic
    %w[hi sa ne mr].each do |lang|
      systems = Tell::Glosser.systems_for(lang)
      assert_equal %w[iast ipa], systems.keys, "Failed for #{lang}"
    end
  end

  def test_default_system_japanese
    assert_equal "hiragana", Tell::Glosser.default_system("ja")
  end

  def test_default_system_chinese
    assert_equal "pinyin", Tell::Glosser.default_system("zh")
  end

  def test_default_system_latin_language
    assert_equal "ipa", Tell::Glosser.default_system("sl")
  end

  def test_system_config_default_returns_first
    config = Tell::Glosser.system_config("ja")
    assert_equal "Hiragana", config[:label]
    assert_includes config[:standalone], "hiragana"
    assert_equal "・", config[:separator]
  end

  def test_system_config_specific_system
    config = Tell::Glosser.system_config("ja", system: "hepburn")
    assert_equal "Hepburn", config[:label]
    assert_includes config[:standalone], "Hepburn"
    assert_equal " ", config[:separator]
  end

  def test_system_config_invalid_falls_back_to_default
    config = Tell::Glosser.system_config("ja", system: "nonexistent")
    assert_equal "Hiragana", config[:label]
  end

  # --- Split/merge with explicit system ---

  def test_split_phonetic_japanese_hepburn_splits_by_space
    readings = Tell::Glosser.split_phonetic("konnichiwa sekai", lang: "ja", system: "hepburn")
    assert_equal %w[konnichiwa sekai], readings
  end

  def test_split_phonetic_japanese_ipa_strips_slashes
    readings = Tell::Glosser.split_phonetic("/koɴɲitɕiwa sekai/", lang: "ja", system: "ipa")
    assert_equal %w[koɴɲitɕiwa sekai], readings
  end

  def test_split_phonetic_japanese_default_uses_middle_dots
    readings = Tell::Glosser.split_phonetic("こんにちは・せかい", lang: "ja")
    assert_equal %w[こんにちは せかい], readings
  end

  def test_merge_phonetic_japanese_hepburn
    gloss = "今日は(n.sg) 世界(n.sg)"
    phonetic = "konnichiwa sekai"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "ja", system: "hepburn")
    assert_equal "今日は[konnichiwa](n.sg) 世界[sekai](n.sg)", result
  end

  def test_merge_phonetic_chinese_zhuyin
    gloss = "你(pron.2p.sg) 好(adj)"
    phonetic = "ㄋㄧˇ ㄏㄠˇ"
    result = Tell::Glosser.merge_phonetic(gloss, phonetic, lang: "zh", system: "zhuyin")
    assert_equal "你[ㄋㄧˇ](pron.2p.sg) 好[ㄏㄠˇ](adj)", result
  end

  # --- Phonetic system in prompts ---

  def test_phonetic_standalone_uses_system
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("konnichiwa sekai")
    glosser.instance_variable_set(:@client, client)

    glosser.phonetic("こんにちは世界", lang: "ja", system: "hepburn")

    prompt = client.calls.first[:content]
    assert_includes prompt, "Hepburn"
  end

  def test_phonetic_standalone_default_matches_original
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("こんにちは・せかい")
    glosser.instance_variable_set(:@client, client)

    glosser.phonetic("こんにちは世界", lang: "ja")

    prompt = client.calls.first[:content]
    assert_includes prompt, "hiragana"
    assert_includes prompt, "middle dots"
  end

  def test_gloss_phonetic_with_system_uses_bracket_instruction
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("今日は[konnichiwa](n.sg)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_phonetic("今日は", from: "ja", to: "en", system: "hepburn")

    prompt = client.calls.first[:content]
    assert_includes prompt, "Hepburn romanization in brackets"
  end

  def test_gloss_phonetic_default_uses_default_bracket
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("今日は[きょうは](n.sg)")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_phonetic("今日は", from: "ja", to: "en")

    prompt = client.calls.first[:content]
    assert_includes prompt, "hiragana reading in brackets"
  end

  def test_gloss_translate_phonetic_with_system
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("слово[slovo](n.n.N.sg)word")
    glosser.instance_variable_set(:@client, client)

    glosser.gloss_translate_phonetic("слово", from: "ru", to: "en", system: "simple")

    prompt = client.calls.first[:content]
    assert_includes prompt, "simplified romanization"
  end

  def test_reconcile_with_system_uses_bracket_instruction
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("word[reading](n)")
    glosser.instance_variable_set(:@client, client)

    glosses = { "m1" => "a[x](n)", "m2" => "a[y](n)" }
    glosser.reconcile(glosses, "a", from: "ja", to: "en", mode: :gloss_phonetic, system: "hepburn")

    prompt = client.calls.first[:content]
    assert_includes prompt, "Hepburn romanization in brackets"
  end

  # --- Phonetic standalone prompts enforce single-line output ---

  def test_default_ipa_prompt_forbids_formatting
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("/ˈdɔːbər ˈdan/")
    glosser.instance_variable_set(:@client, client)

    glosser.phonetic("dober dan", lang: "sl")

    prompt = client.calls.first[:content]
    assert_includes prompt, "Output ONLY the IPA on a single line"
    assert_includes prompt, "no headers or formatting"
  end

  def test_default_simple_prompt_forbids_formatting
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("DOH-ber dahn")
    glosser.instance_variable_set(:@client, client)

    glosser.phonetic("dober dan", lang: "sl", system: "simple")

    prompt = client.calls.first[:content]
    assert_includes prompt, "Output ONLY the phonetic text on a single line"
    assert_includes prompt, "no headers or formatting"
  end

  def test_all_standalone_prompts_contain_output_only
    Tell::Glosser::PHONETIC_SYSTEMS.each do |lang, systems|
      systems.each do |key, config|
        prompt = config[:standalone]
        assert_includes prompt, "Output ONLY",
          "System #{lang}/#{key} standalone prompt missing 'Output ONLY' constraint"
      end
    end
  end

  # --- Reconcile includes original text ---

  def test_reconcile_includes_original_text_in_prompt
    glosser = Tell::Glosser.new("fake_key", model: "claude-opus-4-6")
    client = MockAnthropicClient.new("result(n)")
    glosser.instance_variable_set(:@client, client)

    glosser.reconcile({ "m1" => "a(n)" }, "Dvakrat v tednu", from: "sl", to: "en", mode: :gloss)

    assert_includes client.calls.first[:content], "Dvakrat v tednu"
  end

  private

  class MockAnthropicClient
    attr_reader :calls

    def initialize(response_text)
      @response_text = response_text
      @calls = []
    end

    def messages
      self
    end

    def create(model:, max_tokens:, messages:)
      @calls << { model: model, content: messages.first[:content] }
      MockResponse.new(@response_text)
    end
  end

  class MockResponse
    def initialize(text)
      @text = text
    end

    def content
      [MockContent.new(@text)]
    end
  end

  class MockContent
    def initialize(text)
      @text = text
    end

    def text
      @text
    end
  end
end
