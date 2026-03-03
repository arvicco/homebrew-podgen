# frozen_string_literal: true

require_relative "../test_helper"
require "tell/config"
require "tell/detector"
require "tell/translator"
require "tell/tts"
require "tell/processor"

class TestTellProcessor < Minitest::Test
  def setup
    @config = MockConfig.new(
      original_language: "en",
      target_language: "sl",
      voice_id: "test_voice",
      translation_engine: "deepl",
      tts_engine: "elevenlabs",
      engine_api_key: "fake_key",
      api_key: "fake_eleven_key",
      model_id: "eleven_multilingual_v2",
      output_format: "mp3_44100_128"
    )
  end

  def test_process_skips_empty_text
    processor = Tell::Processor.new(@config)
    # Should return nil without making any API calls
    assert_nil processor.process("   ", output_path: nil, no_translate: true)
  end

  def test_process_skips_blank_text
    processor = Tell::Processor.new(@config)
    assert_nil processor.process("", output_path: nil, no_translate: true)
  end

  # --- MockConfig ---

  MockConfig = Struct.new(
    :original_language, :target_language, :voice_id,
    :translation_engine, :tts_engine, :engine_api_key,
    :api_key, :tts_api_key, :model_id, :output_format,
    :google_language_code,
    keyword_init: true
  )
end
