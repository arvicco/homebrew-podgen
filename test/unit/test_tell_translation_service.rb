# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../tell_mocks"
require "tell/detector"
require "tell/hints"
require "tell/translation_service"

class TestTellTranslationService < Minitest::Test
  def setup
    @config = MockConfig.new(
      original_language: "en",
      target_language: "sl",
      translation_engines: ["deepl"],
      engine_api_keys: { "deepl" => "fake_key" },
      translation_timeout: 8.0
    )
    @translator = MockTranslator.new
  end

  # ===== resolve_source =====

  def test_resolve_source_explicit_lang_returns_it
    svc = build_service
    assert_equal "en", svc.resolve_source("hello", "en")
  end

  def test_resolve_source_auto_uses_detector
    svc = build_service
    Tell::Detector.stub(:detect, "fr") do
      assert_equal "fr", svc.resolve_source("bonjour le monde", "auto")
    end
  end

  def test_resolve_source_auto_nil_detect_with_characteristic_chars
    svc = build_service
    Tell::Detector.stub(:detect, nil) do
      Tell::Detector.stub(:has_characteristic_chars?, true) do
        assert_equal "sl", svc.resolve_source("Desetnica", "auto")
      end
    end
  end

  def test_resolve_source_auto_nil_detect_no_chars
    svc = build_service
    Tell::Detector.stub(:detect, nil) do
      Tell::Detector.stub(:has_characteristic_chars?, false) do
        assert_nil svc.resolve_source("xyz", "auto")
      end
    end
  end

  def test_resolve_source_explicit_target_lang_override
    svc = build_service
    Tell::Detector.stub(:detect, nil) do
      Tell::Detector.stub(:has_characteristic_chars?, true) do
        assert_equal "ja", svc.resolve_source("テスト", "auto", "ja")
      end
    end
  end

  # ===== forward_translate =====

  def test_forward_translate_success
    @translator.forward_result = "dober dan"
    svc = build_service
    result = svc.forward_translate("good morning", from: "en", to: "sl")
    assert_equal :translation, result[:type]
    assert_equal "dober dan", result[:text]
    assert_equal "sl", result[:lang]
  end

  def test_forward_translate_same_text
    svc = build_service
    result = svc.forward_translate("hello", from: "en", to: "sl")
    assert_equal :same_text, result[:type]
    assert_equal "hello", result[:text]
  end

  def test_forward_translate_explanation
    @translator.forward_result = "This is a very long explanation that is much longer than the original"
    svc = build_service
    result = svc.forward_translate("hi", from: "en", to: "sl")
    assert_equal :explanation, result[:type]
  end

  def test_forward_translate_error
    @translator.forward_error = RuntimeError.new("API timeout")
    svc = build_service
    result = svc.forward_translate("hello", from: "en", to: "sl")
    assert_equal :error, result[:type]
    assert_equal "API timeout", result[:error].message
  end

  def test_forward_translate_passes_hints
    @translator.forward_result = "dober dan"
    svc = build_service
    hints = Tell::Hints.parse("good morning /pm")
    svc.forward_translate("good morning", from: "en", to: "sl", hints: hints)
    assert_equal :polite, @translator.forward_hints.last.formality
  end

  def test_forward_translate_case_insensitive_same_text
    @translator.forward_result = "Hello"
    svc = build_service
    result = svc.forward_translate("hello", from: "en", to: "sl")
    assert_equal :same_text, result[:type]
  end

  # ===== reverse_translate =====

  def test_reverse_translate_success
    svc = build_service
    result = svc.reverse_translate("dober dan", from: "sl", to: "en")
    assert_equal :translation, result[:type]
    assert_equal "back_translation", result[:text]
  end

  def test_reverse_translate_same_text
    svc = build_service
    result = svc.reverse_translate("back_translation", from: "sl", to: "en")
    assert_equal :same_text, result[:type]
  end

  def test_reverse_translate_error
    @translator.forward_error = RuntimeError.new("timeout")
    svc = build_service
    result = svc.reverse_translate("dober dan", from: "sl", to: "en")
    assert_equal :error, result[:type]
  end

  private

  def build_service
    Tell::TranslationService.new(@config, translator: @translator)
  end
end
