# frozen_string_literal: true

# Sinatra needs stdlib Logger, but lib/logger.rb shadows it via -Ilib.
# Load the gem's logger by resolving its install path directly.
spec = Gem::Specification.find_by_name("logger")
require File.join(spec.gem_dir, "lib", "logger")

require_relative "../test_helper"
require "rack/test"
require "tell/web"

# One-time class-level configuration
Tell::Web.set :environment, :test
Tell::Web.set :logging, false
Tell::Web.set :tell_config, Struct.new(:original_language, :target_language, keyword_init: true)
  .new(original_language: "en", target_language: "sl")
  .tap { |c| c.define_singleton_method(:for_language) { |_| self } }

class TestTellWeb < Minitest::Test
  include Rack::Test::Methods

  def app = Tell::Web

  def setup
    Tell::Web.set :auth_token, nil
    Tell::Web.set :rate_limiter, Tell::Web::RateLimiter.new(9999)
  end

  # --- /systems endpoint ---

  def test_systems_returns_json_for_known_language
    get "/systems", lang: "ja"

    assert_equal 200, last_response.status
    systems = JSON.parse(last_response.body)
    keys = systems.map { |s| s["key"] }
    assert_equal %w[hiragana hepburn kunrei ipa], keys
    assert_equal "Hiragana", systems.first["label"]
    assert_equal "・", systems.first["separator"]
  end

  def test_systems_returns_defaults_for_unknown_language
    get "/systems", lang: "xx"

    systems = JSON.parse(last_response.body)
    keys = systems.map { |s| s["key"] }
    assert_equal %w[ipa simple], keys
  end

  def test_systems_returns_cyrillic_for_russian
    get "/systems", lang: "ru"

    systems = JSON.parse(last_response.body)
    keys = systems.map { |s| s["key"] }
    assert_equal %w[scholarly simple ipa], keys
  end

  def test_systems_requires_lang_param
    get "/systems"

    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "lang required", body["error"]
  end

  # --- /speak validation ---

  def test_speak_requires_text
    get "/speak"

    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "Text required", body["error"]
  end

  def test_speak_rejects_empty_text
    get "/speak", text: "   "

    assert_equal 400, last_response.status
  end

  def test_speak_rejects_long_text
    get "/speak", text: "a" * 501

    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body["error"], "max 500"
  end

  # --- Auth ---

  def test_auth_rejects_without_token
    Tell::Web.set :auth_token, "secret123"

    get "/systems", lang: "ja"

    assert_equal 401, last_response.status
  end

  def test_auth_accepts_query_token
    Tell::Web.set :auth_token, "secret123"

    get "/systems", lang: "ja", token: "secret123"

    assert_equal 200, last_response.status
  end

  def test_auth_accepts_bearer_token
    Tell::Web.set :auth_token, "secret123"

    header "Authorization", "Bearer secret123"
    get "/systems", lang: "ja"

    assert_equal 200, last_response.status
  end

  def test_no_auth_when_token_not_configured
    get "/systems", lang: "ja"

    assert_equal 200, last_response.status
  end

  # --- Rate limiting ---

  def test_rate_limit_blocks_excessive_requests
    limiter = Tell::Web::RateLimiter.new(2)

    assert limiter.allow?("127.0.0.1")
    assert limiter.allow?("127.0.0.1")
    refute limiter.allow?("127.0.0.1")
  end

  def test_rate_limiter_independent_per_ip
    limiter = Tell::Web::RateLimiter.new(1)

    assert limiter.allow?("1.1.1.1")
    refute limiter.allow?("1.1.1.1")
    assert limiter.allow?("2.2.2.2")
  end

  # --- explanation detection ---

  def test_explanation_skips_tts_and_addons
    # When translation is an explanation (3x+ longer), emit translation + done
    # only — no audio, phonetic, gloss, or reverse events.
    explanation = "This is a long explanation of the word " * 10
    fake_translator = Object.new
    fake_translator.define_singleton_method(:translate) { |*_args, **_kw| explanation }

    config = Struct.new(:original_language, :target_language,
                        :translation_engines, :engine_api_keys,
                        :translation_timeout, :tts_engine,
                        :voice_male, :voice_female,
                        keyword_init: true).new(
      original_language: "en", target_language: "sl",
      translation_engines: ["deepl"], engine_api_keys: {},
      translation_timeout: 8, tts_engine: "google",
      voice_male: nil, voice_female: nil
    ).tap { |c| c.define_singleton_method(:for_language) { |_| self } }
    Tell::Web.set :tell_config, config

    Tell.stub(:build_translator_chain, fake_translator) do
      Tell::Detector.stub(:detect, "ja") do
        Tell::Espeak.stub(:supports?, false) do
          get "/speak", text: "日本語", from: "auto", to: "sl",
              phonetic: "true", gloss: "true", reverse: "true"
        end
      end
    end

    body = last_response.body
    assert_includes body, "event: error"
    assert_includes body, "explanation instead of"
    assert_includes body, "event: translation"
    assert_includes body, "event: done"
    refute_includes body, "event: audio"
    refute_includes body, "event: phonetic"
    refute_includes body, "event: gloss"
    refute_includes body, "event: reverse"
  ensure
    # Restore minimal config for other tests
    Tell::Web.set :tell_config, Struct.new(:original_language, :target_language, keyword_init: true)
      .new(original_language: "en", target_language: "sl")
      .tap { |c| c.define_singleton_method(:for_language) { |_| self } }
  end

  # --- for_language integration ---

  def test_speak_uses_per_language_config_for_tts
    # Base config: Google TTS for Slovenian
    base_config = Struct.new(:original_language, :target_language,
                             :translation_engines, :engine_api_keys,
                             :translation_timeout, :tts_engine,
                             :voice_id, :voice_male, :voice_female,
                             :api_key, :tts_model_id, :output_format,
                             keyword_init: true)

    sl_config = base_config.new(
      original_language: "en", target_language: "sl",
      translation_engines: ["deepl"], engine_api_keys: {},
      translation_timeout: 8, tts_engine: "google",
      voice_id: "sl-SI-Chirp3-HD-Kore", voice_male: nil, voice_female: nil,
      api_key: nil, tts_model_id: nil, output_format: nil
    )

    # Per-language config: ElevenLabs for Japanese
    ja_config = base_config.new(
      original_language: "en", target_language: "ja",
      translation_engines: ["deepl"], engine_api_keys: {},
      translation_timeout: 8, tts_engine: "elevenlabs",
      voice_id: "ja_eleven_voice", voice_male: nil, voice_female: nil,
      api_key: "test_key", tts_model_id: "eleven_multilingual_v2",
      output_format: "mp3_44100_128"
    )

    # for_language returns ja_config when target is "ja", self otherwise
    sl_config.define_singleton_method(:for_language) do |lang|
      lang == "ja" ? ja_config : self
    end

    Tell::Web.set :tell_config, sl_config

    # Track which tts_engine was used
    captured_engine = nil
    fake_tts = Object.new
    fake_tts.define_singleton_method(:synthesize) { |*_| "fake_audio" }

    original_build_tts = Tell.method(:build_tts)
    Tell.define_singleton_method(:build_tts) do |engine, config|
      captured_engine = engine
      fake_tts
    end

    Tell::Detector.stub(:detect, "en") do
      Tell.stub(:build_translator_chain, Object.new.tap { |t|
        t.define_singleton_method(:translate) { |*_args, **_kw| "日本語テキスト" }
      }) do
        get "/speak", text: "hello", from: "en", to: "ja"
      end
    end

    assert_equal "elevenlabs", captured_engine
    assert_includes last_response.body, "event: audio"
  ensure
    Tell.define_singleton_method(:build_tts, original_build_tts) if original_build_tts
    Tell::Web.set :tell_config, Struct.new(:original_language, :target_language, keyword_init: true)
      .new(original_language: "en", target_language: "sl")
      .tap { |c| c.define_singleton_method(:for_language) { |_| self } }
  end

  # --- /speak SSE stream ---

  def test_speak_happy_path_returns_sse_stream
    fake_translator = Object.new
    fake_translator.define_singleton_method(:translate) { |*_args, **_kw| "translated" }

    config = Struct.new(:original_language, :target_language,
                        :translation_engines, :engine_api_keys,
                        :translation_timeout, :tts_engine,
                        :voice_male, :voice_female,
                        keyword_init: true).new(
      original_language: "en", target_language: "sl",
      translation_engines: ["deepl"], engine_api_keys: {},
      translation_timeout: 8, tts_engine: "google",
      voice_male: nil, voice_female: nil
    ).tap { |c| c.define_singleton_method(:for_language) { |_| self } }
    Tell::Web.set :tell_config, config

    fake_tts = Object.new
    fake_tts.define_singleton_method(:synthesize) { |*_| "fake_audio" }

    Tell.stub(:build_translator_chain, fake_translator) do
      Tell.stub(:build_tts, fake_tts) do
        Tell::Detector.stub(:detect, "en") do
          Tell::Espeak.stub(:supports?, false) do
            get "/speak", text: "hello", from: "auto", to: "sl"
          end
        end
      end
    end

    assert_equal 200, last_response.status
    assert_includes last_response.body, "event: translation"
    assert_includes last_response.body, "event: audio"
    assert_includes last_response.body, "event: done"
  ensure
    Tell::Web.set :tell_config, Struct.new(:original_language, :target_language, keyword_init: true)
      .new(original_language: "en", target_language: "sl")
      .tap { |c| c.define_singleton_method(:for_language) { |_| self } }
  end

  def test_speak_no_tts_flag_skips_audio_and_translation
    # no_tts skips both translation and TTS — only emits done
    config = Struct.new(:original_language, :target_language,
                        :translation_engines, :engine_api_keys,
                        :translation_timeout, :tts_engine,
                        :voice_male, :voice_female,
                        keyword_init: true).new(
      original_language: "en", target_language: "sl",
      translation_engines: ["deepl"], engine_api_keys: {},
      translation_timeout: 8, tts_engine: "google",
      voice_male: nil, voice_female: nil
    ).tap { |c| c.define_singleton_method(:for_language) { |_| self } }
    Tell::Web.set :tell_config, config

    Tell::Detector.stub(:detect, "en") do
      Tell::Espeak.stub(:supports?, false) do
        get "/speak", text: "hello", from: "auto", to: "sl", no_tts: "true"
      end
    end

    refute_includes last_response.body, "event: audio"
    assert_includes last_response.body, "event: done"
  ensure
    Tell::Web.set :tell_config, Struct.new(:original_language, :target_language, keyword_init: true)
      .new(original_language: "en", target_language: "sl")
      .tap { |c| c.define_singleton_method(:for_language) { |_| self } }
  end

  def test_speak_sse_format_has_data_prefix
    fake_translator = Object.new
    fake_translator.define_singleton_method(:translate) { |*_args, **_kw| "translated" }

    config = Struct.new(:original_language, :target_language,
                        :translation_engines, :engine_api_keys,
                        :translation_timeout, :tts_engine,
                        :voice_male, :voice_female,
                        keyword_init: true).new(
      original_language: "en", target_language: "sl",
      translation_engines: ["deepl"], engine_api_keys: {},
      translation_timeout: 8, tts_engine: "google",
      voice_male: nil, voice_female: nil
    ).tap { |c| c.define_singleton_method(:for_language) { |_| self } }
    Tell::Web.set :tell_config, config

    fake_tts = Object.new
    fake_tts.define_singleton_method(:synthesize) { |*_| "fake_audio" }

    Tell.stub(:build_translator_chain, fake_translator) do
      Tell.stub(:build_tts, fake_tts) do
        Tell::Detector.stub(:detect, "en") do
          Tell::Espeak.stub(:supports?, false) do
            get "/speak", text: "hello", from: "auto", to: "sl"
          end
        end
      end
    end

    # SSE format: "event: ...\ndata: ...\n\n"
    assert_match(/event: translation\ndata: /, last_response.body)
    assert_match(/event: done\ndata: /, last_response.body)
  ensure
    Tell::Web.set :tell_config, Struct.new(:original_language, :target_language, keyword_init: true)
      .new(original_language: "en", target_language: "sl")
      .tap { |c| c.define_singleton_method(:for_language) { |_| self } }
  end

  # --- / (index) ---

  def test_index_returns_html
    get "/"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "<title>Tell</title>"
    assert_includes last_response.body, "speak()"
  end
end
