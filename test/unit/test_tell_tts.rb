# frozen_string_literal: true

require_relative "../test_helper"
require "tell/tts"

class TestTellTts < Minitest::Test
  def test_build_elevenlabs
    config = mock_config(api_key: "key", voice_id: "v1", model_id: "m1", output_format: "mp3_44100_128")
    tts = Tell.build_tts("elevenlabs", config)
    assert_instance_of Tell::ElevenlabsTts, tts
  end

  def test_build_google
    config = mock_config(tts_api_key: "key", voice_id: "sl-SI-Wavenet-A", google_language_code: "sl-SI")
    tts = Tell.build_tts("google", config)
    assert_instance_of Tell::GoogleTts, tts
  end

  def test_build_unknown_raises
    assert_raises(RuntimeError) { Tell.build_tts("azure", mock_config) }
  end

  # --- Google language code mapping ---

  def test_google_language_code_slovenian
    assert_equal "sl-SI", Tell::GoogleTts::LANGUAGE_CODES["sl"]
  end

  def test_google_language_code_japanese
    assert_equal "ja-JP", Tell::GoogleTts::LANGUAGE_CODES["ja"]
  end

  def test_google_language_code_english
    assert_equal "en-US", Tell::GoogleTts::LANGUAGE_CODES["en"]
  end

  def test_google_language_codes_frozen
    assert Tell::GoogleTts::LANGUAGE_CODES.frozen?
  end

  private

  MockConfig = Struct.new(
    :api_key, :tts_api_key, :voice_id, :model_id, :output_format, :google_language_code,
    keyword_init: true
  )

  def mock_config(**kwargs)
    MockConfig.new(**kwargs)
  end
end
