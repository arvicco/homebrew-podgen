# frozen_string_literal: true

# Integration test: verifies the Tell /speak pipeline chain.
# Engine → Translator → Glosser → Phonetic
# Tests real API calls (Claude for translation/glossing).

require_relative "../test_helper"
require_relative "../tell_mocks"
require "tell/engine"

class TestTellSpeakPipeline < Minitest::Test
  def setup
    skip_unless_env("ANTHROPIC_API_KEY")
  end

  def test_forward_translation_with_real_api
    config = build_config(translation_engines: ["claude"])
    engine = Tell::Engine.new(config)

    result = engine.forward_translate("Hello, how are you?", from: "en", to: "es")

    assert_equal :translation, result[:type], "Should return a translation (not error/explanation)"
    assert_kind_of String, result[:text]
    refute_empty result[:text]
    refute_equal "Hello, how are you?", result[:text], "Translation should differ from input"
  end

  def test_reverse_translation_with_real_api
    config = build_config(translation_engines: ["claude"])
    engine = Tell::Engine.new(config)

    result = engine.reverse_translate("Hola, ¿cómo estás?", from: "es", to: "en")

    assert_includes [:translation, :same_text], result[:type]
    assert_kind_of String, result[:text]
    refute_empty result[:text]
  end

  def test_gloss_with_real_api
    config = build_config(
      gloss_model: ["claude-opus-4-6"],
      phonetic_model: ["claude-opus-4-6"]
    )
    engine = Tell::Engine.new(config)

    result = engine.run_gloss(:gloss, "Grem domov", from: "sl", to: "en")

    assert_kind_of String, result
    refute_empty result
    # Should contain grammatical annotations in parens
    assert_match(/\(/, result, "Gloss should contain grammatical annotations")
  end

  def test_language_detection
    config = build_config
    engine = Tell::Engine.new(config)

    # Auto-detect should identify Japanese text
    source = engine.resolve_source("こんにちは世界", "auto", "ja")
    assert_equal "ja", source, "Should detect Japanese"

    # Non-auto should pass through
    source = engine.resolve_source("Hello", "en", "sl")
    assert_equal "en", source
  end

  def test_fire_addons_reverse_with_real_api
    events = {}
    callbacks = {
      on_reverse: ->(text:, lang:) { events[:reverse] = { text: text, lang: lang } },
      on_reverse_error: ->(error:) { events[:error] = error.message }
    }

    config = build_config(translation_engines: ["claude"])
    engine = Tell::Engine.new(config, callbacks: callbacks)

    threads = engine.fire_addons(
      "Hola mundo",
      reverse: true,
      gloss: false,
      gloss_translate: false,
      phonetic: false,
      gloss_phonetic: false,
      target_lang: "es",
      reverse_lang: "en"
    )
    threads.each(&:join)

    assert events.key?(:reverse), "Should emit reverse translation event"
    assert_kind_of String, events[:reverse][:text]
    refute_empty events[:reverse][:text]
    assert_equal "en", events[:reverse][:lang]
  end

  private

  def build_config(overrides = {})
    api_key = ENV["ANTHROPIC_API_KEY"]

    defaults = {
      original_language: "en",
      target_language: "sl",
      voice_id: "test_voice",
      voice_male: nil,
      voice_female: nil,
      translation_engines: ["claude"],
      tts_engine: "elevenlabs",
      engine_api_keys: { "claude" => api_key },
      api_key: nil,
      tts_api_key: nil,
      tts_model_id: nil,
      output_format: nil,
      google_language_code: nil,
      reverse_translate: false,
      gloss: false,
      gloss_reverse: false,
      phonetic: false,
      gloss_model: ["claude-opus-4-6"],
      phonetic_model: ["claude-opus-4-6"],
      phonetic_system: nil,
      translation_timeout: 15.0
    }

    MockConfig.new(**defaults.merge(overrides))
  end
end
