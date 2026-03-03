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
      refute_nil Tell::LANGUAGE_NAMES[code], "Missing language name for #{code}"
    end
  end

  def test_language_names_frozen
    assert Tell::LANGUAGE_NAMES.frozen?
  end
end
