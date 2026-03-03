# frozen_string_literal: true

require_relative "../test_helper"
require "tell/config"

class TestTellConfig < Minitest::Test
  def setup
    @original_env = ENV.to_h.slice("ELEVENLABS_API_KEY", "DEEPL_AUTH_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GOOGLE_API_KEY")
    ENV["ELEVENLABS_API_KEY"] = "test_eleven_key"
    ENV["DEEPL_AUTH_KEY"] = "test_deepl_key"

    @tmpfile = File.join(Dir.tmpdir, "tell_test_#{Process.pid}.yml")
    stub_config_path(@tmpfile)
  end

  def teardown
    File.delete(@tmpfile) if File.exist?(@tmpfile)
    @original_env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    restore_config_path
  end

  def test_loads_valid_config
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => "deepl"
    )

    config = Tell::Config.new
    assert_equal "en", config.original_language
    assert_equal "sl", config.target_language
    assert_equal "abc123", config.voice_id
    assert_equal "deepl", config.translation_engine
    assert_equal "test_deepl_key", config.engine_api_key
  end

  def test_defaults_engine_to_deepl
    write_config(
      "original_language" => "en",
      "target_language" => "ja",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal "deepl", config.translation_engine
  end

  def test_defaults_model_and_format
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal "eleven_multilingual_v2", config.model_id
    assert_equal "mp3_44100_128", config.output_format
  end

  def test_missing_config_file_raises
    File.delete(@tmpfile) if File.exist?(@tmpfile)
    stub_config_path("/tmp/nonexistent_tell_#{Process.pid}.yml")

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/Config file not found/, err.message)
    assert_match(/~\/\.tell\.yml/, err.message)
  end

  def test_missing_required_keys_raises
    write_config("original_language" => "en")

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/Missing required config keys/, err.message)
    assert_match(/target_language/, err.message)
    assert_match(/voice_id/, err.message)
  end

  def test_invalid_engine_raises
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => "google"
    )

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/Invalid translation_engine/, err.message)
  end

  def test_missing_engine_api_key_raises
    ENV.delete("DEEPL_AUTH_KEY")
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => "deepl"
    )

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/DEEPL_AUTH_KEY/, err.message)
  end

  def test_engine_api_key_from_config_file
    ENV.delete("DEEPL_AUTH_KEY")
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => "deepl",
      "deepl_auth_key" => "from_config"
    )

    config = Tell::Config.new
    assert_equal "from_config", config.engine_api_key
  end

  def test_claude_engine_uses_anthropic_key
    ENV["ANTHROPIC_API_KEY"] = "test_claude_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => "claude"
    )

    config = Tell::Config.new
    assert_equal "claude", config.translation_engine
    assert_equal "test_claude_key", config.engine_api_key
  end

  def test_override_from_language
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new(overrides: { from: "de" })
    assert_equal "de", config.original_language
    assert_equal "sl", config.target_language
  end

  def test_override_to_language
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "en", config.original_language
    assert_equal "ja", config.target_language
  end

  def test_override_voice
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new(overrides: { voice: "xyz789" })
    assert_equal "xyz789", config.voice_id
  end

  # --- TTS engine ---

  def test_defaults_tts_engine_to_elevenlabs
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal "elevenlabs", config.tts_engine
    assert_equal "test_eleven_key", config.api_key
  end

  def test_google_tts_engine
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Wavenet-A",
      "tts_engine" => "google"
    )

    config = Tell::Config.new
    assert_equal "google", config.tts_engine
    assert_equal "test_google_key", config.tts_api_key
    assert_equal "sl-SI", config.google_language_code
  end

  def test_google_tts_explicit_language_code
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Wavenet-A",
      "tts_engine" => "google",
      "google_language_code" => "sl-SI"
    )

    config = Tell::Config.new
    assert_equal "sl-SI", config.google_language_code
  end

  def test_google_tts_missing_api_key_raises
    ENV.delete("GOOGLE_API_KEY")
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Wavenet-A",
      "tts_engine" => "google"
    )

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/GOOGLE_API_KEY/, err.message)
  end

  def test_invalid_tts_engine_raises
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "tts_engine" => "azure"
    )

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/Invalid tts_engine/, err.message)
  end

  def test_openai_engine_uses_openai_key
    ENV["OPENAI_API_KEY"] = "test_openai_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => "openai"
    )

    config = Tell::Config.new
    assert_equal "openai", config.translation_engine
    assert_equal "test_openai_key", config.engine_api_key
  end

  private

  def write_config(data)
    require "yaml"
    File.write(@tmpfile, YAML.dump(data))
  end

  def stub_config_path(path)
    @original_config_path = Tell::Config::CONFIG_PATH
    Tell::Config.send(:remove_const, :CONFIG_PATH)
    Tell::Config.const_set(:CONFIG_PATH, path)
  end

  def restore_config_path
    Tell::Config.send(:remove_const, :CONFIG_PATH)
    Tell::Config.const_set(:CONFIG_PATH, @original_config_path)
  end
end
