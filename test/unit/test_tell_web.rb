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
    assert_equal %w[hiragana hepburn ipa], keys
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

  # --- resolve_source ---

  def test_resolve_source_explicit_lang_returns_it
    web = Tell::Web.new!
    assert_equal "en", web.send(:resolve_source, "hello", "en", "sl")
  end

  def test_resolve_source_auto_uses_detector
    web = Tell::Web.new!
    Tell::Detector.stub(:detect, "fr") do
      assert_equal "fr", web.send(:resolve_source, "bonjour", "auto", "sl")
    end
  end

  def test_resolve_source_auto_nil_detect_with_characteristic_chars
    web = Tell::Web.new!
    Tell::Detector.stub(:detect, nil) do
      Tell::Detector.stub(:has_characteristic_chars?, true) do
        assert_equal "sl", web.send(:resolve_source, "dober", "auto", "sl")
      end
    end
  end

  def test_resolve_source_auto_nil_detect_no_chars
    web = Tell::Web.new!
    Tell::Detector.stub(:detect, nil) do
      Tell::Detector.stub(:has_characteristic_chars?, false) do
        assert_nil web.send(:resolve_source, "xyz", "auto", "sl")
      end
    end
  end

  # --- / (index) ---

  def test_index_returns_html
    get "/"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "<title>Tell</title>"
    assert_includes last_response.body, "speak()"
  end
end
