# frozen_string_literal: true

# Integration test: verifies the Tell /speak pipeline chain.
# Engine → Translator → Glosser → Phonetic
# Offline: language detection. The real-API cases live in
# test/api/test_tell_speak_pipeline.rb.

require_relative "../test_helper"
require_relative "../tell_mocks"
require "tell/engine"

class TestTellSpeakPipeline < Minitest::Test
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
