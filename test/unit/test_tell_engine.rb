# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../tell_mocks"
require "tell/config"
require "tell/detector"
require "tell/glosser"
require "tell/espeak"
require "tell/hints"
require "tell/engine"

class TestTellEngine < Minitest::Test
  def setup
    @config = MockConfig.new(
      original_language: "en",
      target_language: "sl",
      translation_engines: ["deepl"],
      engine_api_keys: { "deepl" => "fake_key" },
      translation_timeout: 8.0,
      reverse_translate: false,
      gloss: false,
      gloss_reverse: false,
      phonetic: false,
      gloss_model: ["claude-opus-4-6"],
      phonetic_model: ["claude-opus-4-6"]
    )
    @translator = MockTranslator.new
    @glosser = MockGlosser.new
    @events = []
    @callbacks = build_test_callbacks
  end

  # ===== Translation (delegates to TranslationService — full tests in test_tell_translation_service.rb) =====

  def test_resolve_source_delegates
    engine = build_engine
    assert_equal "en", engine.resolve_source("hello", "en")
  end

  def test_forward_translate_delegates
    @translator.forward_result = "dober dan"
    engine = build_engine
    result = engine.forward_translate("good morning", from: "en", to: "sl")
    assert_equal :translation, result[:type]
  end

  def test_reverse_translate_delegates
    engine = build_engine
    result = engine.reverse_translate("dober dan", from: "sl", to: "en")
    assert_equal :translation, result[:type]
  end

  # ===== run_gloss =====

  def test_run_gloss_basic
    engine = build_engine
    result = engine.run_gloss(:gloss, "dober dan", from: "sl", to: "en")
    assert_equal "word(n.m.N.sg)", result
    assert_equal [[:gloss, "dober dan"]], @glosser.calls
  end

  def test_run_gloss_translate
    engine = build_engine
    result = engine.run_gloss(:gloss_translate, "dober dan", from: "sl", to: "en")
    assert_equal "word(n.m.N.sg)translation", result
    assert_equal [[:gloss_translate, "dober dan"]], @glosser.calls
  end

  def test_run_gloss_phonetic
    engine = build_engine
    result = engine.run_gloss(:gloss_phonetic, "dober dan", from: "sl", to: "en")
    assert_equal "word[reading](n.m.N.sg)", result
    assert_equal [[:gloss_phonetic, "dober dan"]], @glosser.calls
  end

  def test_run_gloss_translate_phonetic
    engine = build_engine
    result = engine.run_gloss(:gloss_translate_phonetic, "dober dan", from: "sl", to: "en")
    assert_equal "word[reading](n.m.N.sg)translation", result
  end

  def test_run_gloss_multi_model_reconcile
    @config.gloss_model = ["claude-opus-4-6", "claude-sonnet-4-6"]
    glosser_opus = MockGlosser.new(gloss_result: "opus_gloss")
    glosser_sonnet = MockGlosser.new(gloss_result: "sonnet_gloss")
    glossers = { "claude-opus-4-6" => glosser_opus, "claude-sonnet-4-6" => glosser_sonnet }
    engine = Tell::Engine.new(@config, translator: @translator, glossers: glossers)

    result = engine.run_gloss(:gloss, "dober dan", from: "sl", to: "en")

    assert_equal [[:gloss, "dober dan"]], glosser_opus.calls
    assert_equal [[:gloss, "dober dan"]], glosser_sonnet.calls
    assert_equal 1, glosser_opus.reconcile_calls.size
    assert_equal :gloss, glosser_opus.reconcile_calls.first[:mode]
  end

  def test_run_gloss_single_model_no_reconcile
    engine = build_engine
    engine.run_gloss(:gloss, "dober dan", from: "sl", to: "en")
    assert_empty @glosser.reconcile_calls
  end

  def test_run_gloss_passes_system
    engine = build_engine
    engine.run_gloss(:gloss, "test", from: "sl", to: "en", system: "ipa")
    # Verify the glosser was called (system is passed through)
    assert_equal [[:gloss, "test"]], @glosser.calls
  end

  def test_run_gloss_phonetic_passes_phonetic_ref
    engine = build_engine
    engine.run_gloss(:gloss_phonetic, "test", from: "sl", to: "en", phonetic_ref: "ref")
    assert_equal [[:gloss_phonetic, "test"]], @glosser.calls
  end

  # ===== compute_phonetic =====

  def test_compute_phonetic_claude_fallback
    engine = build_engine
    stub_espeak_off do
      result = engine.compute_phonetic("dober dan", lang: "sl")
      assert_equal "reading", result[:primary]
      assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
    end
  end

  def test_compute_phonetic_espeak_ipa
    skip "espeak-ng not installed" unless Tell::Espeak.available?
    engine = build_engine
    result = engine.compute_phonetic("dober dan", lang: "sl", system: "ipa")
    assert result[:primary]
    assert_empty @glosser.phonetic_calls  # eSpeak handles it
  end

  def test_compute_phonetic_japanese_hiragana
    @config.target_language = "ja"
    @glosser = MockGlosser.new(phonetic_result: "おはよう・ございます")
    engine = build_engine
    result = engine.compute_phonetic("おはようございます", lang: "ja", system: "hiragana")
    assert_equal "おはよう・ございます", result[:primary]
    assert_equal "おはよう・ございます", result[:hiragana]
    assert result[:sisters]
    assert_equal 4, result[:sisters].size
  end

  def test_compute_phonetic_japanese_hepburn
    @glosser = MockGlosser.new(phonetic_result: "おはよう・ございます")
    engine = build_engine
    result = engine.compute_phonetic("おはようございます", lang: "ja", system: "hepburn")
    assert_equal "ohayou gozaimasu", result[:primary]
  end

  def test_compute_phonetic_japanese_kunrei
    @glosser = MockGlosser.new(phonetic_result: "おはよう・ございます")
    engine = build_engine
    result = engine.compute_phonetic("おはようございます", lang: "ja", system: "kunrei")
    assert_equal "ohayou gozaimasu", result[:primary]
  end

  def test_compute_phonetic_japanese_ipa_uses_kana_module
    @glosser = MockGlosser.new(phonetic_result: "おはよう・ございます")
    engine = build_engine
    result = engine.compute_phonetic("おはようございます", lang: "ja", system: "ipa")
    # IPA from Kana module — contains ɡ (IPA g) and ɯ (unrounded u)
    assert_match(/ɡozaimasɯ/, result[:primary])
    assert result[:primary].start_with?("/")
    assert result[:primary].end_with?("/")
  end

  def test_compute_phonetic_japanese_sister_ipa_via_kana
    @glosser = MockGlosser.new(phonetic_result: "てすと")
    engine = build_engine
    result = engine.compute_phonetic("テスト", lang: "ja", system: "hiragana")
    # Sister IPA should come from Kana module (broad IPA), not eSpeak
    ipa = result[:sisters]["ipa"]
    assert ipa, "IPA sister should always be present"
    assert_match(/sɯ/, ipa)  # Kana IPA for す
  end

  def test_compute_phonetic_japanese_caching
    @glosser = MockGlosser.new(phonetic_result: "こんにちは")
    engine = build_engine
    engine.compute_phonetic("こんにちは", lang: "ja", system: "hiragana")
    assert_equal 1, @glosser.phonetic_calls.size
    engine.compute_phonetic("こんにちは", lang: "ja", system: "hepburn")
    assert_equal 1, @glosser.phonetic_calls.size  # cached
  end

  # ===== voice_for_gender =====

  def test_voice_for_gender_male
    @config.voice_male = "male_voice"
    engine = build_engine
    assert_equal "male_voice", engine.voice_for_gender(:male)
  end

  def test_voice_for_gender_female
    @config.voice_female = "female_voice"
    engine = build_engine
    assert_equal "female_voice", engine.voice_for_gender(:female)
  end

  def test_voice_for_gender_nil
    engine = build_engine
    assert_nil engine.voice_for_gender(nil)
  end

  # ===== fire_addons =====

  def test_fire_addons_no_flags_returns_empty
    engine = build_engine
    threads = engine.fire_addons("test")
    assert_empty threads
  end

  def test_fire_addons_reverse
    engine = build_engine
    threads = engine.fire_addons("dober dan",
      reverse: true, target_lang: "sl", reverse_lang: "en")
    threads.each(&:join)
    assert_event :reverse, "back_translation"
  end

  def test_fire_addons_reverse_error
    @translator.forward_error = RuntimeError.new("timeout")
    engine = build_engine
    threads = engine.fire_addons("dober dan",
      reverse: true, target_lang: "sl", reverse_lang: "en")
    threads.each(&:join)
    assert_event_type :reverse_error
  end

  def test_fire_addons_gloss
    engine = build_engine
    stub_espeak_off do
      threads = engine.fire_addons("dober dan",
        gloss: true, target_lang: "sl", reverse_lang: "en")
      threads.each(&:join)
    end
    assert_event :gloss, "word(n.m.N.sg)"
  end

  def test_fire_addons_gloss_translate
    engine = build_engine
    stub_espeak_off do
      threads = engine.fire_addons("dober dan",
        gloss_translate: true, target_lang: "sl", reverse_lang: "en")
      threads.each(&:join)
    end
    assert_event :gloss_translate, "word(n.m.N.sg)translation"
  end

  def test_fire_addons_both_gloss_types
    engine = build_engine
    stub_espeak_off do
      threads = engine.fire_addons("dober dan",
        gloss: true, gloss_translate: true, target_lang: "sl", reverse_lang: "en")
      threads.each(&:join)
    end
    assert_event :gloss, "word(n.m.N.sg)"
    assert_event :gloss_translate, "word(n.m.N.sg)translation"
  end

  def test_fire_addons_phonetic_claude
    engine = build_engine
    stub_espeak_off do
      threads = engine.fire_addons("dober dan",
        phonetic: true, target_lang: "sl", reverse_lang: "en")
      threads.each(&:join)
    end
    assert_event :phonetic, "reading"
  end

  def test_fire_addons_gloss_with_phonetic
    engine = build_engine
    stub_espeak_off do
      threads = engine.fire_addons("dober dan",
        gloss: true, phonetic: true, gloss_phonetic: true,
        target_lang: "sl", reverse_lang: "en")
      threads.each(&:join)
    end
    assert_event :phonetic, "reading"
    # Gloss gets phonetic brackets
    assert_event :gloss, "word[reading](n.m.N.sg)"
  end

  def test_fire_addons_all_flags
    engine = build_engine
    stub_espeak_off do
      threads = engine.fire_addons("dober dan",
        reverse: true, gloss: true, gloss_translate: true,
        phonetic: true, gloss_phonetic: true,
        target_lang: "sl", reverse_lang: "en")
      threads.each(&:join)
    end
    assert_event_type :reverse
    assert_event_type :gloss
    assert_event_type :gloss_translate
    assert_event_type :phonetic
  end

  # ===== fire_addons: Japanese coordinated path =====

  def test_fire_addons_japanese_phonetic
    @config.target_language = "ja"
    @glosser = MockGlosser.new(phonetic_result: "てすと")
    engine = build_engine
    threads = engine.fire_addons("テスト",
      phonetic: true, target_lang: "ja", reverse_lang: "en")
    threads.each(&:join)
    assert_event_type :phonetic
    assert_event_type :phonetic_sisters
  end

  def test_fire_addons_japanese_gloss_aligns_brackets_from_phonetic
    @config.target_language = "ja"
    @glosser = MockGlosser.new(
      phonetic_result: "きょう・わ",
      gloss_translate_phonetic_result: "今日[きょう](n.sg)today は(part)TOP"
    )
    engine = build_engine
    threads = engine.fire_addons("今日は",
      phonetic: true, gloss_translate: true, gloss_phonetic: true,
      target_lang: "ja", reverse_lang: "en")
    threads.each(&:join)
    gloss_events = @events.select { |e| e[0] == :gloss_translate }
    refute_empty gloss_events, "Expected gloss_translate event"
    gloss_text = gloss_events.first[1]
    assert_includes gloss_text, "は[わ]", "Particle は should get phonetic reading わ"
  end

  def test_fire_addons_japanese_gloss_converts_brackets_to_requested_system
    @config.target_language = "ja"
    @glosser = MockGlosser.new(
      phonetic_result: "これ・は",
      gloss_translate_phonetic_result: "これ[これ](pron.sg)this は[は](part)TOP"
    )
    engine = build_engine
    threads = engine.fire_addons("これは",
      phonetic: true, gloss_translate: true, gloss_phonetic: true,
      target_lang: "ja", reverse_lang: "en", phonetic_system: "ipa")
    threads.each(&:join)
    gloss_events = @events.select { |e| e[0] == :gloss_translate }
    refute_empty gloss_events
    gloss_text = gloss_events.first[1]
    # Brackets should contain IPA (from Kana module), not hiragana
    assert_includes gloss_text, "[koɾe]"
    # Particle は gets fix_particle_readings (は→わ) before IPA conversion (わ→wa)
    assert_includes gloss_text, "[wa]"
    refute_includes gloss_text, "[これ]"
  end

  def test_fire_addons_japanese_gloss_strips_redundant_brackets
    @config.target_language = "ja"
    @glosser = MockGlosser.new(
      phonetic_result: "これ",
      gloss_phonetic_result: "これ[これ](pron.sg)this"
    )
    engine = build_engine
    threads = engine.fire_addons("これ",
      phonetic: true, gloss: true, gloss_phonetic: true,
      target_lang: "ja", reverse_lang: "en", phonetic_system: "hiragana")
    threads.each(&:join)
    gloss_events = @events.select { |e| e[0] == :gloss }
    refute_empty gloss_events
    # Redundant bracket stripped: これ[これ] → これ
    refute_includes gloss_events.first[1], "[これ]"
    assert_includes gloss_events.first[1], "これ(pron.sg)"
  end

  def test_fire_addons_japanese_emits_bracket_cache
    @config.target_language = "ja"
    @glosser = MockGlosser.new(
      phonetic_result: "きょう",
      gloss_phonetic_result: "今日[きょう](n.sg)"
    )
    engine = build_engine
    threads = engine.fire_addons("今日",
      gloss: true, gloss_phonetic: true, phonetic: true,
      target_lang: "ja", reverse_lang: "en")
    threads.each(&:join)
    cache_events = @events.select { |e| e[0] == :gloss_bracket_cache }
    refute_empty cache_events
    brackets = cache_events.first[1]
    assert_includes brackets.keys, "hepburn"
    assert_includes brackets.keys, "ipa"
  end

  # ===== japanese_hiragana =====

  def test_japanese_hiragana_cached
    @glosser = MockGlosser.new(phonetic_result: "てすと")
    engine = build_engine
    engine.japanese_hiragana("テスト")
    engine.japanese_hiragana("テスト")
    assert_equal 1, @glosser.phonetic_calls.size
  end

  def test_clear_cache
    @glosser = MockGlosser.new(phonetic_result: "てすと")
    engine = build_engine
    engine.japanese_hiragana("テスト")
    engine.clear_cache!
    engine.japanese_hiragana("テスト")
    assert_equal 2, @glosser.phonetic_calls.size
  end

  # ===== Bracket utilities (full tests in test_tell_japanese_brackets.rb) =====

  def test_bracket_methods_available_via_mixin
    engine = build_engine
    assert engine.respond_to?(:strip_redundant_brackets)
    assert engine.respond_to?(:fix_particle_readings)
    assert engine.respond_to?(:align_bracket_readings)
  end

  # ===== kana_words_to_romaji (via compute_phonetic) =====

  def test_japanese_ipa_kana_words
    @glosser = MockGlosser.new(phonetic_result: "てすと・です")
    engine = build_engine
    result = engine.compute_phonetic("テストです", lang: "ja", system: "ipa")
    # IPA from Kana module
    assert_match(/tesɯto desɯ/, result[:primary].delete("/"))
  end

  def test_japanese_hepburn_kana_words
    @glosser = MockGlosser.new(phonetic_result: "てすと・です")
    engine = build_engine
    result = engine.compute_phonetic("テストです", lang: "ja", system: "hepburn")
    assert_equal "tesuto desu", result[:primary]
  end

  def test_japanese_kunrei_kana_words
    @glosser = MockGlosser.new(phonetic_result: "しち・つき")
    engine = build_engine
    result = engine.compute_phonetic("七月", lang: "ja", system: "kunrei")
    assert_equal "siti tuki", result[:primary]
  end

  private

  # --- Test helpers ---

  def build_engine(config: @config, translator: @translator, glossers: nil, callbacks: @callbacks)
    glossers ||= build_glossers(@glosser)
    Tell::Engine.new(config, translator: translator, glossers: glossers, callbacks: callbacks)
  end

  def build_glossers(glosser)
    h = {}
    @config.gloss_model.each { |m| h[m] = glosser }
    @config.phonetic_model.each { |m| h[m] = glosser }
    h
  end

  def build_test_callbacks
    events = @events
    {
      on_reverse: ->(text:, lang:) { events << [:reverse, text, lang] },
      on_reverse_error: ->(error:) { events << [:reverse_error, error] },
      on_gloss: ->(text:) { events << [:gloss, text] },
      on_gloss_translate: ->(text:) { events << [:gloss_translate, text] },
      on_gloss_error: ->(error:) { events << [:gloss_error, error] },
      on_phonetic: ->(text:) { events << [:phonetic, text] },
      on_phonetic_sisters: ->(sisters:) { events << [:phonetic_sisters, sisters] },
      on_phonetic_error: ->(error:) { events << [:phonetic_error, error] },
      on_gloss_bracket_cache: ->(brackets:) { events << [:gloss_bracket_cache, brackets] },
    }
  end

  def assert_event(type, text)
    match = @events.find { |e| e[0] == type && e[1] == text }
    assert match, "Expected #{type} event with text '#{text}', got: #{@events.map(&:first)}"
  end

  def assert_event_type(type)
    match = @events.find { |e| e[0] == type }
    assert match, "Expected #{type} event, got: #{@events.map(&:first)}"
  end

  def stub_detect(result, &block)
    Tell::Detector.stub(:detect, result) do
      Tell::Detector.stub(:has_characteristic_chars?, false, &block)
    end
  end

  def stub_espeak_off(&block)
    Tell::Espeak.stub(:supports?, false, &block)
  end
end
