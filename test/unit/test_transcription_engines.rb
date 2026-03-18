# frozen_string_literal: true

require_relative "../test_helper"
require "transcription/base_engine"
require "transcription/openai_engine"
require "transcription/groq_engine"
require "transcription/elevenlabs_engine"

# Ensure required API keys are set for constructor
ENV["OPENAI_API_KEY"] ||= "test-key"
ENV["GROQ_API_KEY"] ||= "test-key"
ENV["ELEVENLABS_API_KEY"] ||= "test-key"

# Lightweight struct that quacks like an HTTParty::Response
MockHTTPResponse = Struct.new(:code, :body, :success?, keyword_init: true)

# ── BaseEngine ──────────────────────────────────────────────────────────────

class TestBaseEngine < Minitest::Test
  def setup
    @engine = Transcription::BaseEngine.new(language: "en")
  end

  # transcribe / engine_name raise NotImplementedError

  def test_transcribe_raises_not_implemented
    err = assert_raises(NotImplementedError) { @engine.transcribe("/tmp/audio.mp3") }
    assert_match(/transcribe must be implemented/, err.message)
  end

  def test_engine_name_raises_not_implemented
    err = assert_raises(NotImplementedError) { @engine.engine_name }
    assert_match(/engine_name must be implemented/, err.message)
  end

  # validate_audio! (private, tested via send)

  def test_validate_audio_raises_for_missing_file
    err = assert_raises(RuntimeError) { @engine.send(:validate_audio!, "/nonexistent/audio.mp3") }
    assert_match(/Audio file not found/, err.message)
  end

  def test_validate_audio_accepts_existing_file
    Tempfile.create(["audio", ".mp3"]) do |f|
      assert_nil @engine.send(:validate_audio!, f.path) # should not raise
    end
  end

  # retryable? (private, tested via send)

  def test_retryable_for_429
    error = RuntimeError.new("HTTP 429 Too Many Requests")
    assert @engine.send(:retryable?, error)
  end

  def test_retryable_for_503
    error = RuntimeError.new("HTTP 503 Service Unavailable")
    assert @engine.send(:retryable?, error)
  end

  def test_retryable_for_net_open_timeout
    error = Net::OpenTimeout.new("execution expired")
    assert @engine.send(:retryable?, error)
  end

  def test_retryable_for_net_read_timeout
    error = Net::ReadTimeout.new("Net::ReadTimeout")
    assert @engine.send(:retryable?, error)
  end

  def test_retryable_for_etimedout
    error = Errno::ETIMEDOUT.new("Connection timed out")
    assert @engine.send(:retryable?, error)
  end

  def test_not_retryable_for_generic_error
    error = RuntimeError.new("Something unexpected")
    refute @engine.send(:retryable?, error)
  end

  def test_not_retryable_for_400
    error = RuntimeError.new("HTTP 400 Bad Request")
    refute @engine.send(:retryable?, error)
  end

  # Constants

  def test_max_retries
    assert_equal 3, Transcription::BaseEngine::MAX_RETRIES
  end

  def test_timeout
    assert_equal 300, Transcription::BaseEngine::TIMEOUT
  end

  # Default language

  def test_default_language
    engine = Transcription::BaseEngine.new
    assert_equal "sl", engine.instance_variable_get(:@language)
  end

  # parse_segments

  def test_parse_segments_maps_fields
    raw = [
      { "start" => 0.5, "end" => 2.3, "text" => "Hello.",
        "no_speech_prob" => 0.01, "compression_ratio" => 1.2, "avg_logprob" => -0.3 }
    ]
    result = @engine.send(:parse_segments, raw)
    assert_equal 1, result.length
    assert_equal 0.5, result[0][:start]
    assert_equal 2.3, result[0][:end]
    assert_equal "Hello.", result[0][:text]
    assert_in_delta 0.01, result[0][:no_speech_prob]
    assert_in_delta 1.2, result[0][:compression_ratio]
    assert_in_delta(-0.3, result[0][:avg_logprob])
  end

  def test_parse_segments_empty_array
    assert_empty @engine.send(:parse_segments, [])
  end

  def test_parse_segments_nil_input
    assert_empty @engine.send(:parse_segments, nil)
  end

  def test_parse_segments_coerces_nil_values
    raw = [{ "start" => nil, "end" => nil, "text" => nil,
             "no_speech_prob" => nil, "compression_ratio" => nil, "avg_logprob" => nil }]
    result = @engine.send(:parse_segments, raw)
    assert_equal 0.0, result[0][:start]
    assert_equal 0.0, result[0][:end]
    assert_equal "", result[0][:text]
    assert_equal 0.0, result[0][:no_speech_prob]
  end

  # speech_boundaries

  def test_speech_boundaries_from_segments
    segments = [{ start: 1.0 }, { end: 9.0 }]
    s, e = @engine.send(:speech_boundaries, segments, duration: 10.0)
    assert_equal 1.0, s
    assert_equal 9.0, e
  end

  def test_speech_boundaries_empty_with_duration
    s, e = @engine.send(:speech_boundaries, [], duration: 5.0)
    assert_equal 0.0, s
    assert_equal 5.0, e
  end

  def test_speech_boundaries_empty_nil_duration
    s, e = @engine.send(:speech_boundaries, [], duration: nil)
    assert_equal 0.0, s
    assert_equal 0.0, e
  end

  # with_engine_retries

  def test_with_engine_retries_yields_block
    result = @engine.send(:with_engine_retries) { 42 }
    assert_equal 42, result
  end

  def test_with_engine_retries_raises_after_max_retries
    call_count = 0
    @engine.stub(:sleep, nil) do
      err = assert_raises(RuntimeError) do
        @engine.send(:with_engine_retries) do
          call_count += 1
          raise "HTTP 429 Too Many Requests"
        end
      end
      assert_match(/BaseEngine failed after 4 attempts/, err.message)
      assert_equal 4, call_count # 1 initial + 3 retries
    end
  end

  def test_with_engine_retries_does_not_retry_non_retryable
    call_count = 0
    err = assert_raises(RuntimeError) do
      @engine.send(:with_engine_retries) do
        call_count += 1
        raise "HTTP 400 Bad Request"
      end
    end
    assert_match(/BaseEngine failed after 1 attempts/, err.message)
    assert_equal 1, call_count
  end
end

# ── OpenaiEngine ────────────────────────────────────────────────────────────

class TestOpenaiEngine < Minitest::Test
  def setup
    @engine = Transcription::OpenaiEngine.new(language: "sl")
    @audio = Tempfile.new(["test", ".mp3"])
    @audio.write("fake audio data")
    @audio.flush
  end

  def teardown
    @audio.close!
  end

  def test_engine_name
    assert_equal "open", @engine.engine_name
  end

  def test_verbose_models_constant
    assert_includes Transcription::OpenaiEngine::VERBOSE_MODELS, "whisper-1"
    refute_includes Transcription::OpenaiEngine::VERBOSE_MODELS, "gpt-4o-mini-transcribe"
  end

  # parse_verbose_result (private)

  def test_parse_verbose_result_with_segments
    result = {
      "text" => "Hello world. How are you?",
      "duration" => 12.345,
      "segments" => [
        {
          "start" => 0.5, "end" => 2.3, "text" => " Hello world.",
          "no_speech_prob" => 0.01, "compression_ratio" => 1.2, "avg_logprob" => -0.3
        },
        {
          "start" => 2.5, "end" => 5.0, "text" => " How are you?",
          "no_speech_prob" => 0.02, "compression_ratio" => 1.1, "avg_logprob" => -0.25
        }
      ]
    }

    parsed = @engine.send(:parse_verbose_result, result, result["text"], 1.5)

    assert_equal result["text"], parsed[:text]
    assert_equal 0.5, parsed[:speech_start]
    assert_equal 5.0, parsed[:speech_end]
    assert_equal 2, parsed[:segments].length

    seg = parsed[:segments].first
    assert_equal 0.5, seg[:start]
    assert_equal 2.3, seg[:end]
    assert_equal " Hello world.", seg[:text]
    assert_in_delta 0.01, seg[:no_speech_prob]
    assert_in_delta 1.2, seg[:compression_ratio]
    assert_in_delta(-0.3, seg[:avg_logprob])
  end

  def test_parse_verbose_result_with_no_segments
    result = { "text" => "Hello", "duration" => 3.0, "segments" => [] }

    parsed = @engine.send(:parse_verbose_result, result, "Hello", 0.8)

    assert_equal 0.0, parsed[:speech_start]
    assert_equal 3.0, parsed[:speech_end]
    assert_empty parsed[:segments]
  end

  def test_parse_verbose_result_with_nil_segments
    result = { "text" => "Hello", "duration" => 3.0 }

    parsed = @engine.send(:parse_verbose_result, result, "Hello", 0.8)

    assert_equal 0.0, parsed[:speech_start]
    assert_equal 3.0, parsed[:speech_end]
    assert_empty parsed[:segments]
  end

  def test_parse_verbose_result_nil_duration_no_segments
    result = { "text" => "Hello", "duration" => nil, "segments" => [] }

    parsed = @engine.send(:parse_verbose_result, result, "Hello", 0.5)

    assert_equal 0.0, parsed[:speech_end]
  end

  # transcribe with mocked HTTParty — non-verbose model (default)

  def test_transcribe_non_verbose_model
    response_body = { "text" => "Transcribed text" }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = @engine.transcribe(@audio.path)

      assert_equal "Transcribed text", result[:text]
      assert_equal 0.0, result[:speech_start]
      assert_equal 0.0, result[:speech_end]
      assert_empty result[:segments]
    end
  end

  # transcribe with mocked HTTParty — verbose model (whisper-1)

  def test_transcribe_verbose_model
    original_model = ENV["WHISPER_MODEL"]
    ENV["WHISPER_MODEL"] = "whisper-1"
    engine = Transcription::OpenaiEngine.new(language: "sl")

    response_body = {
      "text" => "Hello world.",
      "duration" => 5.0,
      "segments" => [
        { "start" => 0.2, "end" => 4.8, "text" => " Hello world.",
          "no_speech_prob" => 0.01, "compression_ratio" => 1.0, "avg_logprob" => -0.2 }
      ]
    }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = engine.transcribe(@audio.path)

      assert_equal "Hello world.", result[:text]
      assert_equal 0.2, result[:speech_start]
      assert_equal 4.8, result[:speech_end]
      assert_equal 1, result[:segments].length
    end
  ensure
    if original_model
      ENV["WHISPER_MODEL"] = original_model
    else
      ENV.delete("WHISPER_MODEL")
    end
  end

  # transcribe raises on API error

  def test_transcribe_raises_on_api_error
    mock_response = MockHTTPResponse.new(code: 500, body: "Internal Server Error", "success?": false)

    HTTParty.stub(:post, mock_response) do
      err = assert_raises(RuntimeError) { @engine.transcribe(@audio.path) }
      assert_match(/OpenaiEngine failed/, err.message)
    end
  end

  # transcribe raises for missing file

  def test_transcribe_raises_for_missing_file
    err = assert_raises(RuntimeError) { @engine.transcribe("/nonexistent.mp3") }
    assert_match(/Audio file not found/, err.message)
  end
end

# ── GroqEngine ──────────────────────────────────────────────────────────────

class TestGroqEngine < Minitest::Test
  def setup
    @engine = Transcription::GroqEngine.new(language: "sl")
    @audio = Tempfile.new(["test", ".mp3"])
    @audio.write("fake audio data")
    @audio.flush
  end

  def teardown
    @audio.close!
  end

  def test_engine_name
    assert_equal "groq", @engine.engine_name
  end

  def test_max_file_size
    assert_equal 25 * 1024 * 1024, Transcription::GroqEngine::MAX_FILE_SIZE
  end

  # compute_target_bitrate (private)

  def test_compute_target_bitrate_normal
    # For 600s audio: target_bits = 24 * 1024 * 1024 * 8 = 201_326_592
    # bitrate = 201_326_592 / 600 / 1000 = 335 → clamp to 128
    bitrate = @engine.send(:compute_target_bitrate, 600)
    assert_equal 128, bitrate
  end

  def test_compute_target_bitrate_very_long_audio
    # For 10000s: 201_326_592 / 10000 / 1000 = 20.1 → clamp to 32
    bitrate = @engine.send(:compute_target_bitrate, 10_000)
    assert_equal 32, bitrate
  end

  def test_compute_target_bitrate_medium_audio
    # For 3000s: 201_326_592 / 3000 / 1000 = 67.1 → floor = 67
    bitrate = @engine.send(:compute_target_bitrate, 3000)
    assert_equal 67, bitrate
  end

  def test_compute_target_bitrate_short_audio
    # For 100s: 201_326_592 / 100 / 1000 = 2013 → clamp to 128
    bitrate = @engine.send(:compute_target_bitrate, 100)
    assert_equal 128, bitrate
  end

  def test_compute_target_bitrate_at_boundary
    # Exactly at the boundary where bitrate would be 32 before floor
    # target_bits / duration / 1000 = 32 => duration = target_bits / 32000
    target_bits = 24.0 * 1024 * 1024 * 8
    boundary_duration = target_bits / 32_000
    bitrate = @engine.send(:compute_target_bitrate, boundary_duration)
    assert_equal 32, bitrate

    # Just past the boundary (longer duration) should still clamp to 32
    bitrate = @engine.send(:compute_target_bitrate, boundary_duration + 100)
    assert_equal 32, bitrate
  end

  # transcribe with mocked HTTParty — normal (under 25MB)

  def test_transcribe_parses_response_with_words
    response_body = {
      "text" => "Dober dan.",
      "duration" => 3.5,
      "segments" => [
        { "start" => 0.0, "end" => 3.0, "text" => " Dober dan.",
          "no_speech_prob" => 0.05, "compression_ratio" => 1.1, "avg_logprob" => -0.4 }
      ],
      "words" => [
        { "word" => "Dober", "start" => 0.2, "end" => 0.8 },
        { "word" => "dan.", "start" => 0.9, "end" => 1.5 }
      ]
    }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = @engine.transcribe(@audio.path)

      assert_equal "Dober dan.", result[:text]
      assert_equal 0.0, result[:speech_start]
      assert_equal 3.0, result[:speech_end]
      assert_equal 1, result[:segments].length
      assert_equal 2, result[:words].length
      assert_equal "Dober", result[:words][0][:word]
      assert_in_delta 0.2, result[:words][0][:start]
      assert_in_delta 0.8, result[:words][0][:end]
      assert_equal "dan.", result[:words][1][:word]
    end
  end

  def test_transcribe_handles_empty_words
    response_body = {
      "text" => "Hello.",
      "duration" => 2.0,
      "segments" => [
        { "start" => 0.0, "end" => 2.0, "text" => " Hello.",
          "no_speech_prob" => 0.0, "compression_ratio" => 1.0, "avg_logprob" => -0.1 }
      ]
    }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = @engine.transcribe(@audio.path)

      assert_equal "Hello.", result[:text]
      assert_empty result[:words]
    end
  end

  def test_transcribe_empty_text
    response_body = {
      "text" => nil,
      "duration" => 1.0,
      "segments" => [],
      "words" => []
    }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = @engine.transcribe(@audio.path)

      assert_equal "", result[:text]
      assert_equal 0.0, result[:speech_start]
      assert_equal 1.0, result[:speech_end]
    end
  end

  def test_transcribe_raises_on_api_error
    mock_response = MockHTTPResponse.new(code: 500, body: "Server Error", "success?": false)

    HTTParty.stub(:post, mock_response) do
      err = assert_raises(RuntimeError) { @engine.transcribe(@audio.path) }
      assert_match(/GroqEngine failed/, err.message)
    end
  end

  def test_transcribe_raises_for_missing_file
    err = assert_raises(RuntimeError) { @engine.transcribe("/nonexistent.mp3") }
    assert_match(/Audio file not found/, err.message)
  end

  # Speech boundaries from segments

  def test_speech_boundaries_from_multiple_segments
    response_body = {
      "text" => "First. Second.",
      "duration" => 10.0,
      "segments" => [
        { "start" => 1.0, "end" => 4.0, "text" => " First.",
          "no_speech_prob" => 0.0, "compression_ratio" => 1.0, "avg_logprob" => -0.1 },
        { "start" => 5.0, "end" => 9.0, "text" => " Second.",
          "no_speech_prob" => 0.0, "compression_ratio" => 1.0, "avg_logprob" => -0.1 }
      ],
      "words" => []
    }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = @engine.transcribe(@audio.path)

      assert_equal 1.0, result[:speech_start]
      assert_equal 9.0, result[:speech_end]
    end
  end
end

# ── ElevenlabsEngine ────────────────────────────────────────────────────────

class TestElevenlabsEngine < Minitest::Test
  def setup
    @engine = Transcription::ElevenlabsEngine.new(language: "sl")
    @audio = Tempfile.new(["test", ".mp3"])
    @audio.write("fake audio data")
    @audio.flush
  end

  def teardown
    @audio.close!
  end

  def test_engine_name
    assert_equal "elab", @engine.engine_name
  end

  # build_segments_from_words (private)

  def test_build_segments_from_words_splits_on_period
    words = [
      { "text" => "Hello", "start" => 0.0, "end" => 0.5 },
      { "text" => "world.", "start" => 0.6, "end" => 1.0 },
      { "text" => "How", "start" => 1.2, "end" => 1.4 },
      { "text" => "are", "start" => 1.5, "end" => 1.7 },
      { "text" => "you?", "start" => 1.8, "end" => 2.2 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    assert_equal 2, segments.length

    assert_equal 0.0, segments[0][:start]
    assert_equal 1.0, segments[0][:end]
    assert_equal "Hello world.", segments[0][:text]

    assert_equal 1.2, segments[1][:start]
    assert_equal 2.2, segments[1][:end]
    assert_equal "How are you?", segments[1][:text]
  end

  def test_build_segments_from_words_splits_on_exclamation
    words = [
      { "text" => "Wow!", "start" => 0.0, "end" => 0.5 },
      { "text" => "That's", "start" => 0.6, "end" => 0.9 },
      { "text" => "great.", "start" => 1.0, "end" => 1.5 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    assert_equal 2, segments.length
    assert_equal "Wow!", segments[0][:text]
    assert_equal "That's great.", segments[1][:text]
  end

  def test_build_segments_from_words_splits_on_question_mark
    words = [
      { "text" => "What?", "start" => 0.0, "end" => 0.5 },
      { "text" => "Yes.", "start" => 0.6, "end" => 1.0 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    assert_equal 2, segments.length
    assert_equal "What?", segments[0][:text]
    assert_equal "Yes.", segments[1][:text]
  end

  def test_build_segments_from_words_flushes_remaining
    words = [
      { "text" => "Hello", "start" => 0.0, "end" => 0.5 },
      { "text" => "world", "start" => 0.6, "end" => 1.0 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    assert_equal 1, segments.length
    assert_equal "Hello world", segments[0][:text]
    assert_equal 0.0, segments[0][:start]
    assert_equal 1.0, segments[0][:end]
  end

  def test_build_segments_from_words_empty_input
    segments = @engine.send(:build_segments_from_words, [])
    assert_empty segments
  end

  def test_build_segments_from_words_single_sentence
    words = [
      { "text" => "One", "start" => 0.0, "end" => 0.3 },
      { "text" => "sentence.", "start" => 0.4, "end" => 0.8 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    assert_equal 1, segments.length
    assert_equal "One sentence.", segments[0][:text]
    assert_equal 0.0, segments[0][:start]
    assert_equal 0.8, segments[0][:end]
  end

  def test_build_segments_from_words_default_segment_fields
    words = [
      { "text" => "Hi.", "start" => 0.0, "end" => 0.5 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    seg = segments.first
    assert_equal 0.0, seg[:no_speech_prob]
    assert_equal 0.0, seg[:compression_ratio]
    assert_equal 0.0, seg[:avg_logprob]
  end

  def test_build_segments_from_words_uses_word_key_fallback
    # ElevenLabs may use "word" instead of "text"
    words = [
      { "word" => "Hello", "start" => 0.0, "end" => 0.5 },
      { "word" => "world.", "start" => 0.6, "end" => 1.0 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    assert_equal 1, segments.length
    assert_equal "Hello world.", segments[0][:text]
  end

  def test_build_segments_from_words_period_with_trailing_space
    words = [
      { "text" => "End. ", "start" => 0.0, "end" => 0.5 },
      { "text" => "Start.", "start" => 0.6, "end" => 1.0 }
    ]

    segments = @engine.send(:build_segments_from_words, words)

    assert_equal 2, segments.length
    assert_equal "End.", segments[0][:text]
    assert_equal "Start.", segments[1][:text]
  end

  # transcribe with mocked HTTParty

  def test_transcribe_success
    response_body = {
      "text" => "Dober dan. Kako si?",
      "words" => [
        { "text" => "Dober", "start" => 0.0, "end" => 0.5 },
        { "text" => "dan.", "start" => 0.6, "end" => 1.0 },
        { "text" => "Kako", "start" => 1.2, "end" => 1.5 },
        { "text" => "si?", "start" => 1.6, "end" => 2.0 }
      ]
    }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = @engine.transcribe(@audio.path)

      assert_equal "Dober dan. Kako si?", result[:text]
      assert_equal 0.0, result[:speech_start]
      assert_equal 2.0, result[:speech_end]
      assert_equal 2, result[:segments].length
      assert_equal "Dober dan.", result[:segments][0][:text]
      assert_equal "Kako si?", result[:segments][1][:text]
    end
  end

  def test_transcribe_no_words
    response_body = { "text" => "Hello", "words" => [] }.to_json
    mock_response = MockHTTPResponse.new(code: 200, body: response_body, "success?": true)

    HTTParty.stub(:post, mock_response) do
      result = @engine.transcribe(@audio.path)

      assert_equal "Hello", result[:text]
      assert_equal 0.0, result[:speech_start]
      assert_equal 0.0, result[:speech_end]
      assert_empty result[:segments]
    end
  end

  def test_transcribe_raises_on_api_error
    mock_response = MockHTTPResponse.new(code: 401, body: "Unauthorized", "success?": false)

    HTTParty.stub(:post, mock_response) do
      err = assert_raises(RuntimeError) { @engine.transcribe(@audio.path) }
      assert_match(/ElevenlabsEngine failed/, err.message)
    end
  end

  def test_transcribe_raises_for_missing_file
    err = assert_raises(RuntimeError) { @engine.transcribe("/nonexistent.mp3") }
    assert_match(/Audio file not found/, err.message)
  end
end
