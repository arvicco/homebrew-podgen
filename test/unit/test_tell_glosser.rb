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
