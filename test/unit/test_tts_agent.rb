# frozen_string_literal: true

require_relative "../test_helper"

ENV["ELEVENLABS_API_KEY"] ||= "test-key"
ENV["ELEVENLABS_VOICE_ID"] ||= "test-voice"
require "agents/tts_agent"

class TestTTSAgent < Minitest::Test
  # --- Constants ---

  def test_trim_threshold_constant
    assert_equal 0.5, TTSAgent::TRIM_THRESHOLD
  end

  def test_max_chars_constant
    assert_equal 9_500, TTSAgent::DEFAULT_MAX_CHARS
  end

  def test_max_retries_constant
    assert_equal 3, TTSAgent::MAX_RETRIES
  end

  # --- model selection + per-model max_chars ---

  def test_default_model_is_multilingual_v2
    agent = TTSAgent.new
    assert_equal "eleven_multilingual_v2", agent.instance_variable_get(:@model_id)
  end

  def test_model_id_override_takes_precedence_over_env
    ENV["ELEVENLABS_MODEL_ID"] = "eleven_turbo_v2_5"
    agent = TTSAgent.new(model_id_override: "eleven_v3")
    assert_equal "eleven_v3", agent.instance_variable_get(:@model_id)
  ensure
    ENV.delete("ELEVENLABS_MODEL_ID")
  end

  def test_v3_uses_smaller_max_chars
    agent = TTSAgent.new(model_id_override: "eleven_v3")
    splitter = agent.instance_variable_get(:@splitter)
    assert_equal 4_500, splitter.instance_variable_get(:@max_chars)
  end

  def test_v3_omits_previous_request_ids_in_request_body
    require "tempfile"
    require "base64"
    fake = fake_tts_response
    captured = nil
    HTTParty.stub :post, ->(_url, opts) { captured = JSON.parse(opts[:body]); fake } do
      Tempfile.create(["t", ".mp3"]) do |f|
        TTSAgent.new(model_id_override: "eleven_v3").send(
          :synthesize_chunk, text: "hi", path: f.path, previous_request_ids: ["a", "b"]
        )
      end
    end
    refute captured.key?("previous_request_ids"),
           "v3 must not receive previous_request_ids (API returns 400 unsupported_model)"
  end

  def test_v2_includes_previous_request_ids_when_provided
    require "tempfile"
    require "base64"
    fake = fake_tts_response
    captured = nil
    HTTParty.stub :post, ->(_url, opts) { captured = JSON.parse(opts[:body]); fake } do
      Tempfile.create(["t", ".mp3"]) do |f|
        TTSAgent.new(model_id_override: "eleven_multilingual_v2").send(
          :synthesize_chunk, text: "hi", path: f.path, previous_request_ids: ["a", "b"]
        )
      end
    end
    assert_equal ["a", "b"], captured["previous_request_ids"]
  end

  def test_unknown_model_falls_back_to_default_max_chars
    agent = TTSAgent.new(model_id_override: "eleven_future_model")
    splitter = agent.instance_variable_get(:@splitter)
    assert_equal 9_500, splitter.instance_variable_get(:@max_chars)
  end

  # --- load_dict_cache ---

  def test_load_dict_cache_returns_nil_for_missing_file
    agent = build_agent
    result = agent.send(:load_dict_cache, "/nonexistent/path/dict.yml")
    assert_nil result
  end

  def test_load_dict_cache_returns_nil_for_invalid_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dict.yml")
      File.write(path, "not: valid: yaml: [")

      agent = build_agent
      result = agent.send(:load_dict_cache, path)
      assert_nil result
    end
  end

  def test_load_dict_cache_returns_nil_for_hash_missing_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dict.yml")
      File.write(path, YAML.dump({ "dictionary_id" => "abc" }))

      agent = build_agent
      result = agent.send(:load_dict_cache, path)
      assert_nil result
    end
  end

  def test_load_dict_cache_returns_hash_for_valid_cache
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dict.yml")
      File.write(path, YAML.dump({
        "dictionary_id" => "dict-123",
        "version_id" => "ver-456",
        "file_sha256" => "abc123"
      }))

      agent = build_agent
      result = agent.send(:load_dict_cache, path)
      assert_equal({ dictionary_id: "dict-123", version_id: "ver-456", file_sha256: "abc123" }, result)
    end
  end

  # --- save_dict_cache ---

  def test_save_dict_cache_writes_valid_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dict.yml")
      agent = build_agent

      agent.send(:save_dict_cache, path, "dict-abc", "ver-def", "sha-ghi")

      data = YAML.load_file(path)
      assert_equal "dict-abc", data["dictionary_id"]
      assert_equal "ver-def", data["version_id"]
      assert_equal "sha-ghi", data["file_sha256"]
    end
  end

  def test_save_dict_cache_roundtrips_with_load
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dict.yml")
      agent = build_agent

      agent.send(:save_dict_cache, path, "d1", "v1", "s1")
      result = agent.send(:load_dict_cache, path)

      assert_equal({ dictionary_id: "d1", version_id: "v1", file_sha256: "s1" }, result)
    end
  end

  # --- resolve_pronunciation_dictionary ---

  def test_resolve_pronunciation_dictionary_returns_empty_when_path_nil
    agent = build_agent
    result = agent.send(:resolve_pronunciation_dictionary, nil)
    assert_equal [], result
  end

  def test_resolve_pronunciation_dictionary_returns_empty_when_file_missing
    agent = build_agent
    result = agent.send(:resolve_pronunciation_dictionary, "/nonexistent/pronunciation.pls")
    assert_equal [], result
  end

  def test_resolve_pronunciation_dictionary_uses_cache_when_sha_matches
    Dir.mktmpdir do |dir|
      pls_path = File.join(dir, "pronunciation.pls")
      cache_path = File.join(dir, "pronunciation.yml")

      File.write(pls_path, "<lexicon>test</lexicon>")
      file_sha = Digest::SHA256.file(pls_path).hexdigest

      File.write(cache_path, YAML.dump({
        "dictionary_id" => "cached-dict-id",
        "version_id" => "cached-ver-id",
        "file_sha256" => file_sha
      }))

      agent = build_agent
      result = agent.send(:resolve_pronunciation_dictionary, pls_path)

      expected = [{ pronunciation_dictionary_id: "cached-dict-id", version_id: "cached-ver-id" }]
      assert_equal expected, result
    end
  end

  def test_resolve_pronunciation_dictionary_ignores_stale_cache
    Dir.mktmpdir do |dir|
      pls_path = File.join(dir, "pronunciation.pls")
      cache_path = File.join(dir, "pronunciation.yml")

      File.write(pls_path, "<lexicon>test</lexicon>")

      File.write(cache_path, YAML.dump({
        "dictionary_id" => "old-dict",
        "version_id" => "old-ver",
        "file_sha256" => "stale-sha-that-doesnt-match"
      }))

      agent = build_agent
      # Stub upload to avoid HTTP call
      upload_called = false
      agent.define_singleton_method(:upload_pronunciation_dictionary) do |_path|
        upload_called = true
        { dictionary_id: "new-dict", version_id: "new-ver" }
      end

      result = agent.send(:resolve_pronunciation_dictionary, pls_path)

      assert upload_called, "Expected upload to be called for stale cache"
      expected = [{ pronunciation_dictionary_id: "new-dict", version_id: "new-ver" }]
      assert_equal expected, result
    end
  end

  # --- trim_trailing_audio ---

  def test_trim_trailing_audio_skips_when_no_end_times
    agent = build_agent
    # Should return without error when end_times is nil
    agent.send(:trim_trailing_audio, "/fake/path.mp3", { "character_end_times_seconds" => nil })
    agent.send(:trim_trailing_audio, "/fake/path.mp3", { "character_end_times_seconds" => [] })
  end

  def test_trim_trailing_audio_skips_when_trailing_below_threshold
    agent = build_agent
    # Stub probe_duration to return a value just barely above speech end
    agent.define_singleton_method(:probe_duration) { |_| 10.3 }

    # trailing = 10.3 - 10.0 = 0.3, which is < TRIM_THRESHOLD (0.5)
    # Should not attempt ffmpeg
    agent.send(:trim_trailing_audio, "/fake/path.mp3", { "character_end_times_seconds" => [5.0, 10.0] })
  end

  def test_trim_trailing_audio_skips_when_alignment_appears_truncated
    # Regression: ElevenLabs eleven_v3 sometimes returns
    # character_end_times_seconds that under-reports the actual speech end
    # by tens of seconds for long chunks. Trusting it silences real speech.
    # Anything above MAX_TRIM_SECONDS is treated as bad alignment data.
    agent = build_agent
    agent.define_singleton_method(:probe_duration) { |_| 171.92 }

    # Force a failure if ffmpeg is invoked (it shouldn't be).
    ffmpeg_called = false
    Open3.stub :capture3, ->(*_args) { ffmpeg_called = true; ["", "", Struct.new(:success?).new(true)] } do
      agent.send(:trim_trailing_audio, "/fake/path.mp3",
                 { "character_end_times_seconds" => [10.0, 96.03] })
    end

    refute ffmpeg_called, "Trim must NOT silence audio when alignment claims >5s trailing — alignment is incomplete"
  end

  # --- pronunciation dictionary upload content-type ---

  def test_upload_pronunciation_dictionary_sends_octet_stream_not_pls_xml
    # Regression: MiniMime maps .pls → "application/pls+xml" which ElevenLabs'
    # /add-from-file parser rejects with HTTP 400 "Lexicon file formatted
    # incorrectly". Curl sends application/octet-stream and the API accepts
    # the same file. Wrap the File so HTTParty uses our content-type.
    require "tempfile"
    Tempfile.create(["test_dict", ".pls"]) do |f|
      f.write('<?xml version="1.0"?><lexicon/>')
      f.flush
      agent = build_agent

      captured_body = nil
      fake_response = Object.new
      fake_response.define_singleton_method(:code) { 200 }
      fake_response.define_singleton_method(:body) { '{"id":"d1","version_id":"v1"}' }

      HTTParty.stub :post, ->(_url, opts) { captured_body = opts[:body]; fake_response } do
        agent.send(:upload_pronunciation_dictionary, f.path)
      end

      file_value = captured_body[:file]
      assert_respond_to file_value, :content_type,
        "wrapped file must expose content_type so HTTParty doesn't fall back to MiniMime"
      assert_equal "application/octet-stream", file_value.content_type,
        "ElevenLabs rejects application/pls+xml — must send octet-stream"
    end
  end

  def test_trim_trailing_audio_does_trim_small_legitimate_tail
    # Sub-MAX-TRIM trailing (e.g. 0.89s of TTS artifact) should still be trimmed.
    agent = build_agent
    agent.define_singleton_method(:probe_duration) { |_| 132.32 }

    ffmpeg_called = false
    Open3.stub :capture3, ->(*_args) { ffmpeg_called = true; ["", "", Struct.new(:success?).new(true)] } do
      FileUtils.stub :mv, ->(_src, _dst) { } do
        agent.send(:trim_trailing_audio, "/fake/path.mp3",
                   { "character_end_times_seconds" => [10.0, 131.43] })
      end
    end

    assert ffmpeg_called, "Small legitimate tail (0.89s) should still be trimmed"
  end

  def test_trim_trailing_audio_skips_entirely_for_eleven_v3
    # Regression: eleven_v3 routinely under-reports character_end_times_seconds
    # by 0.5–1.5s for full episodes. The MAX_TRIM_SECONDS guard only catches
    # gross under-reports (10s+); subtle ones slip through and silence real
    # speech (last sentences of segments). Observed in fulgur_news 2026-05-03:
    # Opening Brief silenced 1.01s, AI Music Piracy silenced 1.13s.
    # For v3 specifically, skip the trim entirely — the alignment data is
    # too unreliable to base any silencing on.
    agent = build_agent
    agent.instance_variable_set(:@model_id, "eleven_v3")
    agent.define_singleton_method(:probe_duration) { |_| 132.32 }

    ffmpeg_called = false
    Open3.stub :capture3, ->(*_args) { ffmpeg_called = true; ["", "", Struct.new(:success?).new(true)] } do
      FileUtils.stub :mv, ->(_src, _dst) { } do
        # Same alignment shape as the v2 "legitimate tail" test: 0.89s trailing.
        # Under v2 it WOULD trim. Under v3 it must NOT.
        agent.send(:trim_trailing_audio, "/fake/path.mp3",
                   { "character_end_times_seconds" => [10.0, 131.43] })
      end
    end

    refute ffmpeg_called,
      "Trim must NOT run for eleven_v3 — its alignment is unreliable and silences real speech"
  end

  private

  def fake_tts_response
    response = Object.new
    body = JSON.generate("audio_base64" => Base64.strict_encode64(""))
    response.define_singleton_method(:code) { 200 }
    response.define_singleton_method(:body) { body }
    response.define_singleton_method(:headers) { { "request-id" => "test-rid" } }
    response
  end

  def build_agent
    agent = TTSAgent.allocate
    agent.instance_variable_set(:@api_key, "test-key")
    agent.instance_variable_set(:@voice_id, "test-voice")
    agent.instance_variable_set(:@model_id, "eleven_multilingual_v2")
    agent.instance_variable_set(:@output_format, "mp3_44100_128")
    agent.instance_variable_set(:@pronunciation_locators, [])
    agent.instance_variable_set(:@splitter, TextSplitter.new(max_chars: TTSAgent::MAX_CHARS))
    agent.instance_variable_set(:@logger, nil)
    agent
  end
end
