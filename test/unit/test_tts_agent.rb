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
    assert_equal 9_500, TTSAgent::MAX_CHARS
  end

  def test_max_retries_constant
    assert_equal 3, TTSAgent::MAX_RETRIES
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

  private

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
