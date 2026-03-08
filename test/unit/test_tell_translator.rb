# frozen_string_literal: true

require_relative "../test_helper"
require "tell/hints"
require "tell/translator"

class TestTellTranslator < Minitest::Test
  # --- Tell.translation_prompt ---

  def test_translation_prompt_without_hints
    prompt = Tell.translation_prompt("hello", to: "sl", hints: nil)
    assert_includes prompt, "Slovenian"
    assert_includes prompt, "hello"
    refute_includes prompt, "style"
  end

  def test_translation_prompt_with_hints
    hints = Tell::Hints::Result.new(text: "", formality: :polite, gender: nil)
    prompt = Tell.translation_prompt("hello", to: "sl", hints: hints)
    assert_includes prompt, "style"
    assert_includes prompt, "polite"
  end

  # --- build_translator ---

  def test_build_deepl_translator
    translator = Tell.build_translator("deepl", "fake_key")
    assert_instance_of Tell::DeeplTranslator, translator
  end

  def test_build_claude_translator
    translator = Tell.build_translator("claude", "fake_key")
    assert_instance_of Tell::ClaudeTranslator, translator
  end

  def test_build_openai_translator
    translator = Tell.build_translator("openai", "fake_key")
    assert_instance_of Tell::OpenaiTranslator, translator
  end

  def test_build_unknown_engine_raises
    assert_raises(RuntimeError) { Tell.build_translator("google", "fake_key") }
  end

  def test_language_names_includes_common_languages
    %w[en sl ja ko zh de fr es ru].each do |code|
      refute_nil LANGUAGE_NAMES[code], "Missing language name for #{code}"
    end
  end

  def test_language_names_frozen
    assert LANGUAGE_NAMES.frozen?
  end

  # --- extract_translation ---

  def test_extract_translation_with_tags
    assert_equal "Bonjour", Tell.extract_translation("<t>Bonjour</t>")
  end

  def test_extract_translation_strips_whitespace
    assert_equal "Bonjour", Tell.extract_translation("<t> Bonjour </t>")
  end

  def test_extract_translation_with_reasoning
    text = "Let me think about this.\n\n<t>Bonjour le monde</t>\n\nNote: this is formal."
    assert_equal "Bonjour le monde", Tell.extract_translation(text)
  end

  def test_extract_translation_multiline
    text = "<t>Line one\nLine two</t>"
    assert_equal "Line one\nLine two", Tell.extract_translation(text)
  end

  def test_extract_translation_no_tags_fallback
    assert_equal "Bonjour", Tell.extract_translation("Bonjour")
  end

  def test_extract_translation_no_tags_strips
    assert_equal "Bonjour", Tell.extract_translation("  Bonjour  ")
  end

  def test_prompt_includes_tag_instruction
    prompt = Tell.translation_prompt("hello", to: "sl", hints: nil)
    assert_includes prompt, "<t>"
    assert_includes prompt, "</t>"
  end

  # --- TranslatorChain ---

  def test_chain_single_engine_success
    mock = MockTranslator.new("hola")
    chain = Tell::TranslatorChain.new([["deepl", mock]], timeout: 5)

    result = chain.translate("hello", from: "en", to: "es")
    assert_equal "hola", result
  end

  def test_chain_failover_on_error
    failing = MockTranslator.new(error: "503 overloaded")
    working = MockTranslator.new("hola")
    chain = Tell::TranslatorChain.new([["deepl", failing], ["claude", working]], timeout: 5)

    result = capture_stderr { chain.translate("hello", from: "en", to: "es") }
    assert_equal "hola", result
  end

  def test_chain_failover_on_timeout
    slow = MockTranslator.new(sleep: 2)
    working = MockTranslator.new("hola")
    chain = Tell::TranslatorChain.new([["deepl", slow], ["claude", working]], timeout: 0.1)

    result = capture_stderr { chain.translate("hello", from: "en", to: "es") }
    assert_equal "hola", result
  end

  def test_chain_empty_raises_clear_error
    chain = Tell::TranslatorChain.new([], timeout: 5)
    err = assert_raises(RuntimeError) { chain.translate("hello", from: "en", to: "es") }
    assert_equal "No translation engines configured", err.message
  end

  def test_chain_all_fail_raises_last_error
    fail1 = MockTranslator.new(error: "first error")
    fail2 = MockTranslator.new(error: "second error")
    chain = Tell::TranslatorChain.new([["deepl", fail1], ["claude", fail2]], timeout: 5)

    err = assert_raises(RuntimeError) { capture_stderr { chain.translate("hello", from: "en", to: "es") } }
    assert_equal "second error", err.message
  end

  def test_chain_passes_hints_through
    mock = MockTranslator.new("hola")
    chain = Tell::TranslatorChain.new([["claude", mock]], timeout: 5)
    hints = Tell::Hints::Result.new(text: "", formality: :polite, gender: :male)

    chain.translate("hello", from: "en", to: "es", hints: hints)
    assert_equal hints, mock.last_hints
  end

  def test_chain_passes_nil_hints_by_default
    mock = MockTranslator.new("hola")
    chain = Tell::TranslatorChain.new([["claude", mock]], timeout: 5)

    chain.translate("hello", from: "en", to: "es")
    assert_nil mock.last_hints
  end

  def test_build_translator_chain_filters_nil_keys
    chain = Tell.build_translator_chain(
      ["deepl", "claude"],
      { "deepl" => "key1", "claude" => nil },
      timeout: 5
    )
    # Only deepl should be in the chain
    assert_instance_of Tell::TranslatorChain, chain
  end

  # --- TranslatorChain friendly_error ---

  def test_chain_friendly_error_overloaded
    chain = Tell::TranslatorChain.new([], timeout: 5)
    err = RuntimeError.new('{"type":"overloaded_error","message":"Overloaded"}')
    assert_equal "API overloaded (try again)", chain.send(:friendly_error, err)
  end

  def test_chain_friendly_error_status_529
    chain = Tell::TranslatorChain.new([], timeout: 5)
    err = RuntimeError.new("status: 529 overloaded")
    assert_equal "API overloaded (try again)", chain.send(:friendly_error, err)
  end

  def test_chain_friendly_error_rate_limit
    chain = Tell::TranslatorChain.new([], timeout: 5)
    err = RuntimeError.new('{"type":"rate_limit_error","message":"Too many"}')
    assert_equal "rate limited (try again)", chain.send(:friendly_error, err)
  end

  def test_chain_friendly_error_http_with_message
    chain = Tell::TranslatorChain.new([], timeout: 5)
    err = RuntimeError.new('status: 500, "message": "Internal error"')
    assert_equal "HTTP 500: Internal error", chain.send(:friendly_error, err)
  end

  def test_chain_friendly_error_truncates_long
    chain = Tell::TranslatorChain.new([], timeout: 5)
    err = RuntimeError.new("A" * 100)
    result = chain.send(:friendly_error, err)
    assert_equal 80, result.length
    assert result.end_with?("...")
  end

  def test_chain_friendly_error_short_passthrough
    chain = Tell::TranslatorChain.new([], timeout: 5)
    err = RuntimeError.new("connection refused")
    assert_equal "connection refused", chain.send(:friendly_error, err)
  end

  # --- Helpers ---

  class MockTranslator
    attr_reader :last_hints

    def initialize(result = nil, error: nil, sleep: nil)
      @result = result
      @error = error
      @sleep = sleep
      @last_hints = nil
    end

    def translate(text, from:, to:, hints: nil)
      @last_hints = hints
      Kernel.sleep(@sleep) if @sleep
      raise RuntimeError, @error if @error
      @result
    end
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
