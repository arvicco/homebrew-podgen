# frozen_string_literal: true

require_relative "../test_helper"
require "tell/tts"

class TestTellTts < Minitest::Test
  def test_build_elevenlabs
    config = mock_config(api_key: "key", voice_id: "v1", tts_model_id: "m1", output_format: "mp3_44100_128")
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

  # --- ElevenLabs synthesize ---

  def test_elevenlabs_success
    tts = build_elevenlabs
    stub_post(200, "audio_bytes") do
      result = tts.synthesize("hello")
      assert_equal "audio_bytes", result
    end
  end

  def test_elevenlabs_uses_voice_override
    tts = build_elevenlabs
    called_url = nil
    stub = ->(*args, **kwargs) {
      called_url = args[0]
      MockHTTPResponse.new(200, "audio")
    }
    HTTParty.stub(:post, stub) do
      tts.synthesize("hello", voice: "override_voice")
    end
    assert_includes called_url, "/override_voice?"
  end

  def test_elevenlabs_non_retriable_error_raises_immediately
    tts = build_elevenlabs
    stub_post(400, '{"detail":"Bad request"}') do
      err = assert_raises(RuntimeError) { tts.synthesize("hello") }
      assert_match(/ElevenLabs TTS failed: HTTP 400/, err.message)
    end
  end

  def test_elevenlabs_retriable_429_retries_then_succeeds
    tts = build_elevenlabs
    call_count = 0
    stub = ->(*args, **kwargs) {
      call_count += 1
      if call_count == 1
        MockHTTPResponse.new(429, '{"detail":"rate limited"}')
      else
        MockHTTPResponse.new(200, "audio_data")
      end
    }
    tts.stub(:sleep, nil) do
      result = capture_stderr { HTTParty.stub(:post, stub) { tts.synthesize("hello") } }
      assert_equal "audio_data", result
      assert_equal 2, call_count
    end
  end

  def test_elevenlabs_retriable_503_retries_then_succeeds
    tts = build_elevenlabs
    call_count = 0
    stub = ->(*args, **kwargs) {
      call_count += 1
      if call_count <= 2
        MockHTTPResponse.new(503, '{"detail":"Service unavailable"}')
      else
        MockHTTPResponse.new(200, "audio_data")
      end
    }
    tts.stub(:sleep, nil) do
      result = capture_stderr { HTTParty.stub(:post, stub) { tts.synthesize("hello") } }
      assert_equal "audio_data", result
      assert_equal 3, call_count
    end
  end

  def test_elevenlabs_exhausts_retries_raises
    tts = build_elevenlabs
    stub = ->(*args, **kwargs) { MockHTTPResponse.new(429, '{"detail":"rate limited"}') }
    tts.stub(:sleep, nil) do
      err = assert_raises(RuntimeError) do
        capture_stderr { HTTParty.stub(:post, stub) { tts.synthesize("hello") } }
      end
      assert_match(/after \d+ attempts/, err.message)
    end
  end

  def test_elevenlabs_net_timeout_retries
    tts = build_elevenlabs
    call_count = 0
    stub = ->(*args, **kwargs) {
      call_count += 1
      raise Net::ReadTimeout if call_count == 1
      MockHTTPResponse.new(200, "audio_data")
    }
    tts.stub(:sleep, nil) do
      result = capture_stderr { HTTParty.stub(:post, stub) { tts.synthesize("hello") } }
      assert_equal "audio_data", result
    end
  end

  # --- Google TTS synthesize ---

  def test_google_success
    tts = build_google
    audio_b64 = Base64.encode64("google_audio")
    body = { "audioContent" => audio_b64 }.to_json
    stub_post(200, body) do
      result = tts.synthesize("hello")
      assert_equal "google_audio", result
    end
  end

  def test_google_sends_api_key_in_header_not_url
    tts = build_google
    called_url = nil
    called_headers = nil
    stub = ->(*args, **kwargs) {
      called_url = args[0]
      called_headers = kwargs[:headers]
      audio_b64 = Base64.encode64("audio")
      MockHTTPResponse.new(200, { "audioContent" => audio_b64 }.to_json)
    }
    HTTParty.stub(:post, stub) do
      tts.synthesize("hello")
    end
    refute_includes called_url, "key=", "API key should not be in URL"
    assert_equal "test_key", called_headers["x-goog-api-key"]
  end

  def test_google_uses_voice_override
    tts = build_google
    called_body = nil
    stub = ->(*args, **kwargs) {
      called_body = JSON.parse(kwargs[:body])
      audio_b64 = Base64.encode64("audio")
      MockHTTPResponse.new(200, { "audioContent" => audio_b64 }.to_json)
    }
    HTTParty.stub(:post, stub) do
      tts.synthesize("hello", voice: "custom-voice")
    end
    assert_equal "custom-voice", called_body.dig("voice", "name")
  end

  def test_google_non_retriable_error_raises
    tts = build_google
    stub_post(400, '{"error":{"code":400,"message":"Invalid request"}}') do
      err = assert_raises(RuntimeError) { tts.synthesize("hello") }
      assert_match(/Google TTS failed: HTTP 400/, err.message)
    end
  end

  def test_google_retriable_retries_then_succeeds
    tts = build_google
    call_count = 0
    audio_b64 = Base64.encode64("audio_data")
    stub = ->(*args, **kwargs) {
      call_count += 1
      if call_count == 1
        MockHTTPResponse.new(503, '{"error":{"code":503,"message":"Unavailable"}}')
      else
        MockHTTPResponse.new(200, { "audioContent" => audio_b64 }.to_json)
      end
    }
    tts.stub(:sleep, nil) do
      result = capture_stderr { HTTParty.stub(:post, stub) { tts.synthesize("hello") } }
      assert_equal "audio_data", result
    end
  end

  def test_google_exhausts_retries_raises
    tts = build_google
    stub = ->(*args, **kwargs) { MockHTTPResponse.new(429, '{"error":{"code":429,"message":"Quota"}}') }
    tts.stub(:sleep, nil) do
      err = assert_raises(RuntimeError) do
        capture_stderr { HTTParty.stub(:post, stub) { tts.synthesize("hello") } }
      end
      assert_match(/after \d+ attempts/, err.message)
    end
  end

  private

  MockConfig = Struct.new(
    :api_key, :tts_api_key, :voice_id, :tts_model_id, :output_format, :google_language_code,
    keyword_init: true
  )

  def mock_config(**kwargs)
    MockConfig.new(**kwargs)
  end

  def build_elevenlabs
    config = mock_config(api_key: "test_key", voice_id: "test_voice", tts_model_id: "eleven_multilingual_v2", output_format: "mp3_44100_128")
    Tell::ElevenlabsTts.new(config)
  end

  def build_google
    config = mock_config(tts_api_key: "test_key", voice_id: "sl-SI-Wavenet-A", google_language_code: "sl-SI")
    Tell::GoogleTts.new(config)
  end

  class MockHTTPResponse
    attr_reader :code, :body

    def initialize(code, body)
      @code = code
      @body = body
    end
  end

  def stub_post(code, body, &block)
    response = MockHTTPResponse.new(code, body)
    HTTParty.stub(:post, response, &block)
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    result = yield
    $stderr = old
    result
  rescue => e
    $stderr = old
    raise e
  end
end
