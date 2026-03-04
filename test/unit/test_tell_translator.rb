# frozen_string_literal: true

require_relative "../test_helper"
require "tell/translator"

class TestTellTranslator < Minitest::Test
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

  def test_chain_all_fail_raises_last_error
    fail1 = MockTranslator.new(error: "first error")
    fail2 = MockTranslator.new(error: "second error")
    chain = Tell::TranslatorChain.new([["deepl", fail1], ["claude", fail2]], timeout: 5)

    err = assert_raises(RuntimeError) { capture_stderr { chain.translate("hello", from: "en", to: "es") } }
    assert_equal "second error", err.message
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

  # --- Helpers ---

  class MockTranslator
    def initialize(result = nil, error: nil, sleep: nil)
      @result = result
      @error = error
      @sleep = sleep
    end

    def translate(text, from:, to:)
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
