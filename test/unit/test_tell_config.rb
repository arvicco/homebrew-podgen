# frozen_string_literal: true

require_relative "../test_helper"
require "tell/config"

class TestTellConfig < Minitest::Test
  def setup
    @original_env = ENV.to_h.slice("ELEVENLABS_API_KEY", "DEEPL_AUTH_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GOOGLE_API_KEY", "TELL_TRANSLATE_TIMEOUT", "TELL_GLOSS_MODEL", "TELL_PHONETIC_MODEL", "TELL_PHONETIC_SYSTEM")
    ENV["ELEVENLABS_API_KEY"] = "test_eleven_key"
    ENV["DEEPL_AUTH_KEY"] = "test_deepl_key"
    ENV.delete("TELL_TRANSLATE_TIMEOUT")
    ENV.delete("TELL_GLOSS_MODEL")
    ENV.delete("TELL_PHONETIC_MODEL")
    ENV.delete("TELL_PHONETIC_SYSTEM")

    @tmpfile = File.join(Dir.tmpdir, "tell_test_#{Process.pid}.yml")
    stub_config_path(@tmpfile)
  end

  def teardown
    File.delete(@tmpfile) if File.exist?(@tmpfile)
    @original_env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    ENV.delete("TELL_TRANSLATE_TIMEOUT")
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
    assert_equal "eleven_multilingual_v2", config.tts_model_id
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

  def test_google_tts_adapts_voice_on_language_override
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "tts_engine" => "google"
    )

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "ja-JP", config.google_language_code
    assert_equal "ja-JP-Chirp3-HD-Kore", config.voice_id
  end

  def test_google_tts_adapts_wavenet_voice
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Wavenet-A",
      "tts_engine" => "google"
    )

    config = Tell::Config.new(overrides: { to: "de" })
    assert_equal "de-DE", config.google_language_code
    assert_equal "de-DE-Wavenet-A", config.voice_id
  end

  def test_google_tts_no_adapt_when_language_matches
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "tts_engine" => "google"
    )

    config = Tell::Config.new
    assert_equal "sl-SI-Chirp3-HD-Kore", config.voice_id
  end

  def test_google_tts_adapts_gendered_voices_on_language_override
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "voice_male" => "sl-SI-Chirp3-HD-Puck",
      "voice_female" => "sl-SI-Chirp3-HD-Aoede",
      "tts_engine" => "google"
    )

    config = Tell::Config.new(overrides: { to: "ru" })
    assert_equal "ru-RU-Chirp3-HD-Kore", config.voice_id
    assert_equal "ru-RU-Chirp3-HD-Puck", config.voice_male
    assert_equal "ru-RU-Chirp3-HD-Aoede", config.voice_female
  end

  def test_google_tts_no_adapt_gendered_voices_when_language_matches
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "voice_male" => "sl-SI-Chirp3-HD-Puck",
      "voice_female" => "sl-SI-Chirp3-HD-Aoede",
      "tts_engine" => "google"
    )

    config = Tell::Config.new
    assert_equal "sl-SI-Chirp3-HD-Kore", config.voice_id
    assert_equal "sl-SI-Chirp3-HD-Puck", config.voice_male
    assert_equal "sl-SI-Chirp3-HD-Aoede", config.voice_female
  end

  def test_google_tts_adapts_with_nil_gendered_voices
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "tts_engine" => "google"
    )

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "ja-JP-Chirp3-HD-Kore", config.voice_id
    assert_nil config.voice_male
    assert_nil config.voice_female
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

  def test_reverse_translate_default_false
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    refute config.reverse_translate
  end

  def test_reverse_translate_from_config
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "reverse_translate" => true
    )

    config = Tell::Config.new
    assert config.reverse_translate
  end

  def test_reverse_translate_cli_override
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new(overrides: { reverse: true })
    assert config.reverse_translate
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

  # --- Engine failover ---

  def test_string_engine_becomes_single_element_array
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => "deepl"
    )

    config = Tell::Config.new
    assert_equal ["deepl"], config.translation_engines
  end

  def test_array_engines_preserved
    ENV["ANTHROPIC_API_KEY"] = "test_claude_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => ["deepl", "claude"]
    )

    config = Tell::Config.new
    assert_equal ["deepl", "claude"], config.translation_engines
  end

  def test_engine_api_keys_hash
    ENV["ANTHROPIC_API_KEY"] = "test_claude_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => ["deepl", "claude"]
    )

    config = Tell::Config.new
    assert_equal "test_deepl_key", config.engine_api_keys["deepl"]
    assert_equal "test_claude_key", config.engine_api_keys["claude"]
  end

  def test_missing_fallback_key_warns_and_skips
    ENV.delete("ANTHROPIC_API_KEY")
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => ["deepl", "claude"]
    )

    config, stderr_output = capture_stderr { Tell::Config.new }
    assert_match(/claude fallback skipped/, stderr_output)
  end

  def test_missing_fallback_key_removes_engine
    ENV.delete("ANTHROPIC_API_KEY")
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => ["deepl", "claude"]
    )

    config, _ = capture_stderr { Tell::Config.new }
    assert_equal ["deepl"], config.translation_engines
  end

  def test_missing_primary_key_raises
    ENV.delete("DEEPL_AUTH_KEY")
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => ["deepl", "claude"]
    )

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/DEEPL_AUTH_KEY/, err.message)
  end

  # --- Timeout ---

  def test_default_timeout
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal 8.0, config.translation_timeout
  end

  def test_custom_timeout_from_yaml
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_timeout" => 3
    )

    config = Tell::Config.new
    assert_equal 3.0, config.translation_timeout
  end

  def test_custom_timeout_from_env
    ENV["TELL_TRANSLATE_TIMEOUT"] = "5"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal 5.0, config.translation_timeout
  end

  # --- reverse_language ---

  def test_reverse_language_normal
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal "en", config.reverse_language
  end

  def test_reverse_language_auto
    write_config(
      "original_language" => "auto",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal "en", config.reverse_language
  end

  # --- gloss_model ---

  def test_gloss_model_scalar
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "gloss_model" => "sonnet"
    )

    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6"], config.gloss_model
    assert_equal "claude-sonnet-4-6", config.gloss_reconciler
  end

  def test_gloss_model_array
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "gloss_model" => ["opus", "sonnet"]
    )

    config = Tell::Config.new
    assert_equal ["claude-opus-4-6", "claude-sonnet-4-6"], config.gloss_model
    assert_equal "claude-opus-4-6", config.gloss_reconciler
  end

  def test_gloss_model_single_string
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "gloss_model" => "haiku"
    )

    config = Tell::Config.new
    assert_equal ["claude-haiku-4-5-20251001"], config.gloss_model
  end

  def test_gloss_model_default_to_opus
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_equal ["claude-opus-4-6"], config.gloss_model
  end

  def test_gloss_model_env_override
    ENV["TELL_GLOSS_MODEL"] = "haiku"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "gloss_model" => ["opus", "sonnet"]
    )

    config = Tell::Config.new
    assert_equal ["claude-haiku-4-5-20251001"], config.gloss_model
  end

  def test_gloss_model_full_model_id_scalar
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "gloss_model" => "claude-sonnet-4-6"
    )

    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6"], config.gloss_model
  end

  # --- phonetic_model ---

  def test_phonetic_model_defaults_to_first_gloss_model
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "gloss_model" => ["opus", "sonnet"]
    )

    config = Tell::Config.new
    assert_equal ["claude-opus-4-6"], config.phonetic_model
    assert_equal "claude-opus-4-6", config.phonetic_reconciler
  end

  def test_phonetic_model_explicit_scalar
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "phonetic_model" => "haiku"
    )

    config = Tell::Config.new
    assert_equal ["claude-haiku-4-5-20251001"], config.phonetic_model
    assert_equal "claude-haiku-4-5-20251001", config.phonetic_reconciler
  end

  def test_phonetic_model_explicit_array
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "phonetic_model" => ["sonnet", "haiku"]
    )

    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"], config.phonetic_model
    assert_equal "claude-sonnet-4-6", config.phonetic_reconciler
  end

  def test_phonetic_model_env_override
    ENV["TELL_PHONETIC_MODEL"] = "sonnet"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "phonetic_model" => "haiku"
    )

    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6"], config.phonetic_model
  end

  # --- Gendered voices ---

  def test_voice_male_female_from_config
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "default_voice",
      "voice_male" => "male_voice",
      "voice_female" => "female_voice"
    )

    config = Tell::Config.new
    assert_equal "default_voice", config.voice_id
    assert_equal "male_voice", config.voice_male
    assert_equal "female_voice", config.voice_female
  end

  def test_voice_male_female_default_nil
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "default_voice"
    )

    config = Tell::Config.new
    assert_nil config.voice_male
    assert_nil config.voice_female
  end

  # --- All settings accept both scalar and array ---

  def test_translation_engine_scalar_becomes_array
    write_config(base_config.merge("translation_engine" => "deepl"))
    config = Tell::Config.new
    assert_equal ["deepl"], config.translation_engines
    assert_equal "deepl", config.translation_engine
  end

  def test_translation_engine_array_preserved
    ENV["ANTHROPIC_API_KEY"] = "test_claude_key"
    write_config(base_config.merge("translation_engine" => ["deepl", "claude"]))
    config = Tell::Config.new
    assert_equal ["deepl", "claude"], config.translation_engines
    assert_equal "deepl", config.translation_engine # first = primary
  end

  def test_gloss_model_scalar_becomes_array
    write_config(base_config.merge("gloss_model" => "sonnet"))
    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6"], config.gloss_model
    assert_equal "claude-sonnet-4-6", config.gloss_reconciler
  end

  def test_gloss_model_array_preserved_for_consensus
    write_config(base_config.merge("gloss_model" => ["opus", "sonnet"]))
    config = Tell::Config.new
    assert_equal ["claude-opus-4-6", "claude-sonnet-4-6"], config.gloss_model
    assert_equal "claude-opus-4-6", config.gloss_reconciler # first = reconciler
  end

  def test_gloss_model_array_resolves_short_names
    write_config(base_config.merge("gloss_model" => ["sonnet", "haiku"]))
    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"], config.gloss_model
  end

  def test_gloss_model_array_passes_through_full_ids
    write_config(base_config.merge("gloss_model" => ["claude-opus-4-6", "claude-sonnet-4-6"]))
    config = Tell::Config.new
    assert_equal ["claude-opus-4-6", "claude-sonnet-4-6"], config.gloss_model
  end

  def test_phonetic_model_scalar_becomes_array
    write_config(base_config.merge("phonetic_model" => "haiku"))
    config = Tell::Config.new
    assert_equal ["claude-haiku-4-5-20251001"], config.phonetic_model
    assert_equal "claude-haiku-4-5-20251001", config.phonetic_reconciler
  end

  def test_phonetic_model_array_preserved_for_consensus
    write_config(base_config.merge("phonetic_model" => ["sonnet", "haiku"]))
    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"], config.phonetic_model
    assert_equal "claude-sonnet-4-6", config.phonetic_reconciler
  end

  def test_phonetic_model_array_passes_through_full_ids
    write_config(base_config.merge("phonetic_model" => ["claude-haiku-4-5-20251001", "claude-opus-4-6"]))
    config = Tell::Config.new
    assert_equal ["claude-haiku-4-5-20251001", "claude-opus-4-6"], config.phonetic_model
  end

  def test_phonetic_model_defaults_to_first_gloss_model_when_absent
    write_config(base_config.merge("gloss_model" => ["sonnet", "opus"]))
    config = Tell::Config.new
    assert_equal ["claude-sonnet-4-6"], config.phonetic_model
  end

  # --- Per-language overrides ---

  def test_language_override_switches_tts_engine
    write_config(base_config.merge(
      "tts_engine" => "elevenlabs",
      "languages" => {
        "ja" => { "tts_engine" => "elevenlabs", "voice_id" => "ja_voice" }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "elevenlabs", config.tts_engine
    assert_equal "ja_voice", config.voice_id
  end

  def test_language_override_switches_voice_only
    write_config(base_config.merge(
      "languages" => {
        "de" => { "voice_id" => "de_voice" }
      }
    ))

    config = Tell::Config.new(overrides: { to: "de" })
    assert_equal "de_voice", config.voice_id
    assert_equal "elevenlabs", config.tts_engine # unchanged default
  end

  def test_language_override_includes_gendered_voices
    write_config(base_config.merge(
      "languages" => {
        "ja" => {
          "voice_id" => "ja_default",
          "voice_male" => "ja_male",
          "voice_female" => "ja_female"
        }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "ja_default", config.voice_id
    assert_equal "ja_male", config.voice_male
    assert_equal "ja_female", config.voice_female
  end

  def test_language_override_no_match_uses_defaults
    write_config(base_config.merge(
      "languages" => {
        "ja" => { "voice_id" => "ja_voice" }
      }
    ))

    config = Tell::Config.new  # target=sl, no override for sl
    assert_equal "abc123", config.voice_id
  end

  def test_language_override_no_languages_block
    write_config(base_config)

    config = Tell::Config.new
    assert_equal "abc123", config.voice_id
  end

  def test_cli_tts_engine_override_skips_language_voices_when_engines_differ
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "voice_male" => "sl-SI-Chirp3-HD-Puck",
      "tts_engine" => "google",
      "languages" => {
        "ja" => {
          "tts_engine" => "elevenlabs",
          "voice_id" => "WQz3clzUdMqvBf0jswZQ",
          "voice_male" => "bYqmvVkXUBwLwYpGHGz3"
        }
      }
    )

    config = Tell::Config.new(overrides: { to: "ja", tts_engine: "google" })
    assert_equal "google", config.tts_engine
    # Base Google voices adapted for Japanese, NOT the ElevenLabs voices
    assert_equal "ja-JP-Chirp3-HD-Kore", config.voice_id
    assert_equal "ja-JP-Chirp3-HD-Puck", config.voice_male
  end

  def test_cli_tts_engine_override_keeps_language_voices_when_engines_match
    write_config(base_config.merge(
      "languages" => {
        "ja" => {
          "tts_engine" => "elevenlabs",
          "voice_id" => "ja_eleven_voice",
          "voice_male" => "ja_eleven_male"
        }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja", tts_engine: "elevenlabs" })
    assert_equal "elevenlabs", config.tts_engine
    assert_equal "ja_eleven_voice", config.voice_id
    assert_equal "ja_eleven_male", config.voice_male
  end

  def test_cli_tts_engine_override_keeps_non_voice_language_settings
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(base_config.merge(
      "tts_engine" => "google",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "languages" => {
        "ja" => {
          "tts_engine" => "elevenlabs",
          "voice_id" => "ja_eleven_voice",
          "phonetic_model" => "haiku"
        }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja", tts_engine: "google" })
    # Non-voice settings from language block still applied
    assert_equal ["claude-haiku-4-5-20251001"], config.phonetic_model
  end

  def test_no_cli_tts_engine_override_merges_language_voices_normally
    write_config(base_config.merge(
      "languages" => {
        "ja" => {
          "tts_engine" => "elevenlabs",
          "voice_id" => "ja_eleven_voice"
        }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "elevenlabs", config.tts_engine
    assert_equal "ja_eleven_voice", config.voice_id
  end

  def test_cli_override_takes_precedence_over_language_override
    write_config(base_config.merge(
      "languages" => {
        "ja" => { "voice_id" => "ja_voice" }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja", voice: "cli_voice" })
    assert_equal "cli_voice", config.voice_id
  end

  def test_language_override_elevenlabs_to_google
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(base_config.merge(
      "tts_engine" => "elevenlabs",
      "languages" => {
        "de" => {
          "tts_engine" => "google",
          "voice_id" => "de-DE-Chirp3-HD-Kore"
        }
      }
    ))

    config = Tell::Config.new(overrides: { to: "de" })
    assert_equal "google", config.tts_engine
    assert_equal "de-DE", config.google_language_code
    assert_equal "de-DE-Chirp3-HD-Kore", config.voice_id
  end

  def test_language_override_google_to_elevenlabs
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "tts_engine" => "google",
      "languages" => {
        "ja" => {
          "tts_engine" => "elevenlabs",
          "voice_id" => "ja_eleven_voice"
        }
      }
    )

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "elevenlabs", config.tts_engine
    assert_equal "ja_eleven_voice", config.voice_id
    assert_equal "test_eleven_key", config.api_key
  end

  def test_language_override_model_id_and_output_format
    write_config(base_config.merge(
      "languages" => {
        "ja" => {
          "voice_id" => "ja_voice",
          "tts_model_id" => "eleven_turbo_v2_5",
          "output_format" => "mp3_22050_32"
        }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "eleven_turbo_v2_5", config.tts_model_id
    assert_equal "mp3_22050_32", config.output_format
  end

  def test_language_override_phonetic_system
    write_config(base_config.merge(
      "phonetic_system" => "ipa",
      "languages" => {
        "ja" => { "phonetic_system" => "hepburn" }
      }
    ))

    config = Tell::Config.new(overrides: { to: "ja" })
    assert_equal "hepburn", config.phonetic_system
  end

  # --- Language normalization ---

  def test_auto_original_language_lowercase
    write_config(base_config.merge("original_language" => "auto"))
    config = Tell::Config.new
    assert_equal "auto", config.original_language
    assert_equal "en", config.reverse_language
  end

  def test_auto_original_language_capitalized
    write_config(base_config.merge("original_language" => "Auto"))
    config = Tell::Config.new
    assert_equal "auto", config.original_language
  end

  def test_uppercase_language_codes_normalized
    write_config(base_config.merge("original_language" => "EN", "target_language" => "SL"))
    config = Tell::Config.new
    assert_equal "en", config.original_language
    assert_equal "sl", config.target_language
  end

  # --- Edge cases ---

  def test_empty_string_required_keys_raises
    write_config(
      "original_language" => "en",
      "target_language" => "",
      "voice_id" => "abc123"
    )

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/Missing required config keys/, err.message)
    assert_match(/target_language/, err.message)
  end

  def test_google_voice_without_three_parts_unchanged
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "simple-voice",
      "tts_engine" => "google"
    )

    config = Tell::Config.new(overrides: { to: "de" })
    # Voice has only 2 parts, so adaptation is skipped
    assert_equal "simple-voice", config.voice_id
  end

  def test_gloss_defaults_and_overrides
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "gloss" => true,
      "gloss_reverse" => true
    )

    config = Tell::Config.new
    assert config.gloss
    assert config.gloss_reverse
  end

  def test_gloss_cli_override
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new(overrides: { gloss: true })
    assert config.gloss
  end

  def test_tts_engine_cli_override
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Wavenet-A",
      "tts_engine" => "elevenlabs"
    )

    ENV["GOOGLE_API_KEY"] = "test_google_key"
    config = Tell::Config.new(overrides: { tts_engine: "google" })
    assert_equal "google", config.tts_engine
  end

  def test_invalid_engine_in_array_raises
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123",
      "translation_engine" => ["deepl", "google"]
    )

    err = assert_raises(RuntimeError) { Tell::Config.new }
    assert_match(/Invalid translation_engine 'google'/, err.message)
  end

  # --- phonetic_system ---

  def test_phonetic_system_default_nil
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "abc123"
    )

    config = Tell::Config.new
    assert_nil config.phonetic_system
    assert_nil config.phonetic_system_for("ja")
  end

  def test_phonetic_system_string_from_config
    write_config(
      "original_language" => "en",
      "target_language" => "ja",
      "voice_id" => "abc123",
      "phonetic_system" => "hepburn"
    )

    config = Tell::Config.new
    assert_equal "hepburn", config.phonetic_system
    assert_equal "hepburn", config.phonetic_system_for("ja")
    assert_equal "hepburn", config.phonetic_system_for("zh")
  end

  def test_phonetic_system_hash_from_config
    write_config(
      "original_language" => "en",
      "target_language" => "ja",
      "voice_id" => "abc123",
      "phonetic_system" => { "ja" => "hepburn", "zh" => "zhuyin" }
    )

    config = Tell::Config.new
    assert_equal "hepburn", config.phonetic_system_for("ja")
    assert_equal "zhuyin", config.phonetic_system_for("zh")
    assert_nil config.phonetic_system_for("ko")
  end

  def test_phonetic_system_env_override
    ENV["TELL_PHONETIC_SYSTEM"] = "ipa"
    write_config(
      "original_language" => "en",
      "target_language" => "ja",
      "voice_id" => "abc123",
      "phonetic_system" => "hepburn"
    )

    config = Tell::Config.new
    assert_equal "ipa", config.phonetic_system
  end

  def test_phonetic_system_cli_override
    write_config(
      "original_language" => "en",
      "target_language" => "ja",
      "voice_id" => "abc123",
      "phonetic_system" => "hepburn"
    )

    config = Tell::Config.new(overrides: { phonetic_system: "ipa" })
    assert_equal "ipa", config.phonetic_system
  end

  # --- for_language ---

  def test_for_language_returns_self_when_matching_default
    write_config(base_config)
    config = Tell::Config.new
    assert_same config, config.for_language("sl")
  end

  def test_for_language_returns_self_for_normalized_alias
    write_config(base_config.merge("target_language" => "ja"))
    config = Tell::Config.new
    assert_same config, config.for_language("jp")  # jp → ja
  end

  def test_for_language_creates_new_config_for_different_language
    write_config(base_config)
    config = Tell::Config.new
    ja_config = config.for_language("ja")
    refute_same config, ja_config
    assert_equal "ja", ja_config.target_language
    assert_equal "en", ja_config.original_language
  end

  def test_for_language_caches_same_object
    write_config(base_config)
    config = Tell::Config.new
    assert_same config.for_language("ja"), config.for_language("ja")
  end

  def test_for_language_alias_and_canonical_same_cache
    write_config(base_config)
    config = Tell::Config.new
    assert_same config.for_language("jp"), config.for_language("ja")
  end

  def test_for_language_different_languages_different_objects
    write_config(base_config)
    config = Tell::Config.new
    refute_same config.for_language("ja"), config.for_language("de")
  end

  def test_for_language_applies_per_language_overrides
    write_config(base_config.merge(
      "languages" => {
        "ja" => {
          "tts_engine" => "elevenlabs",
          "voice_id" => "ja_voice",
          "voice_male" => "ja_male",
          "voice_female" => "ja_female",
          "phonetic_model" => "haiku"
        }
      }
    ))
    config = Tell::Config.new
    ja = config.for_language("ja")
    assert_equal "elevenlabs", ja.tts_engine
    assert_equal "ja_voice", ja.voice_id
    assert_equal "ja_male", ja.voice_male
    assert_equal "ja_female", ja.voice_female
    assert_equal ["claude-haiku-4-5-20251001"], ja.phonetic_model
  end

  def test_for_language_inherits_defaults_without_override
    write_config(base_config.merge(
      "languages" => {
        "ja" => { "voice_id" => "ja_voice" }
      }
    ))
    config = Tell::Config.new
    de = config.for_language("de")
    assert_equal "abc123", de.voice_id       # default voice
    assert_equal "elevenlabs", de.tts_engine  # default engine
  end

  def test_for_language_without_languages_block
    write_config(base_config)
    config = Tell::Config.new
    ja = config.for_language("ja")
    assert_equal "ja", ja.target_language
    assert_equal "abc123", ja.voice_id  # default voice carried over
  end

  def test_for_language_preserves_translation_settings
    ENV["ANTHROPIC_API_KEY"] = "test_claude_key"
    write_config(base_config.merge(
      "translation_engine" => ["deepl", "claude"],
      "translation_timeout" => 5.0
    ))
    config = Tell::Config.new
    ja = config.for_language("ja")
    assert_equal ["deepl", "claude"], ja.translation_engines
    assert_equal 5.0, ja.translation_timeout
  end

  def test_for_language_preserves_reverse_language
    write_config(base_config)
    config = Tell::Config.new
    ja = config.for_language("ja")
    assert_equal "en", ja.reverse_language
  end

  def test_for_language_no_file_reread
    write_config(base_config)
    config = Tell::Config.new
    # Overwrite config file — for_language should use cached raw data
    write_config(base_config.merge("voice_id" => "changed"))
    ja = config.for_language("ja")
    assert_equal "abc123", ja.voice_id  # from original load, not re-read
  end

  def test_for_language_google_voice_adaptation
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(base_config.merge(
      "tts_engine" => "google",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "voice_male" => "sl-SI-Chirp3-HD-Puck"
    ))
    config = Tell::Config.new
    de = config.for_language("de")
    assert_equal "de-DE-Chirp3-HD-Kore", de.voice_id
    assert_equal "de-DE-Chirp3-HD-Puck", de.voice_male
  end

  def test_for_language_switches_google_to_elevenlabs
    ENV["GOOGLE_API_KEY"] = "test_google_key"
    write_config(
      "original_language" => "en",
      "target_language" => "sl",
      "voice_id" => "sl-SI-Chirp3-HD-Kore",
      "tts_engine" => "google",
      "languages" => {
        "ja" => {
          "tts_engine" => "elevenlabs",
          "voice_id" => "ja_eleven_voice"
        }
      }
    )
    config = Tell::Config.new
    assert_equal "google", config.tts_engine

    ja = config.for_language("ja")
    assert_equal "elevenlabs", ja.tts_engine
    assert_equal "ja_eleven_voice", ja.voice_id
    assert_equal "test_eleven_key", ja.api_key
  end

  private

  def base_config
    { "original_language" => "en", "target_language" => "sl", "voice_id" => "abc123" }
  end

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

  def capture_stderr
    old_stderr = $stderr
    $stderr = StringIO.new
    result = yield
    output = $stderr.string
    $stderr = old_stderr
    [result, output]
  rescue => e
    $stderr = old_stderr
    raise e
  end
end
