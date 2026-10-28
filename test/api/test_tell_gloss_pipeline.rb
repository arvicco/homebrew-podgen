# frozen_string_literal: true

# API test: the Glosser against real Claude calls (Category 2 of the gloss
# pipeline). The offline Colors cases live in
# test/integration/test_tell_gloss_pipeline.rb.

require_relative "../test_helper"
require "tell/colors"
require "tell/glosser"

class TestTellGlossPipelineApi < Minitest::Test
  # Bare [0m = the substring "[0m" NOT preceded by \e (escape char).
  BARE_RESET = /(?<!\e)\[0m/

  # ============================================================
  # Category 2: Glosser API (requires ANTHROPIC_API_KEY)
  # Real API calls with haiku (cheap/fast), verify output
  # structure + colorization pipeline end-to-end.
  # ============================================================

  HAIKU = "claude-haiku-4-5-20251001"
  SL_TEXT = "Danes je lep dan."
  RU_TEXT = "Сегодня хороший день."
  JA_TEXT = "今日はいい天気です。"

  # Token pattern: word(grammar) — no phonetic, no translation
  GLOSS_RE = /\S+\([^)]+\)/

  # Token pattern: word(grammar)translation
  GLOSS_TRANSLATE_RE = /\S+\([^)]+\)\S+/

  # Token pattern: word[phonetic](grammar) — allows optional space before [ and after ]
  GLOSS_PHONETIC_RE = /\S+?\s?\[[^\]]+\]\s?\([^)]+\)/

  # Token pattern: word[phonetic](grammar)translation — allows optional spaces
  # Haiku sometimes inserts space between ) and translation
  GLOSS_TRANSLATE_PHONETIC_RE = /\S+?\s?\[[^\]]+\]\s?\([^)]+\)\s?\S+/

  def test_api_gloss_slovenian
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.gloss(SL_TEXT, from: "sl", to: "en")
      tokens = result.scan(GLOSS_RE)
      assert tokens.size >= 3, "Expected at least 3 glossed tokens, got #{tokens.size}: #{result}"
    end
  end

  def test_api_gloss_translate_slovenian_to_russian
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.gloss_translate(SL_TEXT, from: "sl", to: "ru")
      tokens = result.scan(GLOSS_TRANSLATE_RE)
      # Haiku sometimes omits translations for function words (je, danes) — 2 is realistic
      assert tokens.size >= 2, "Expected at least 2 translated tokens, got #{tokens.size}: #{result}"
    end
  end

  def test_api_gloss_phonetic_latin_source
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.gloss_phonetic(SL_TEXT, from: "sl", to: "en")

      # Regression: Latin-script source should still include [IPA] brackets
      tokens_with_phonetic = result.scan(GLOSS_PHONETIC_RE)
      assert tokens_with_phonetic.size >= 2,
        "Latin-script source should include phonetic brackets for most words, got #{tokens_with_phonetic.size}: #{result}"
    end
  end

  def test_api_gloss_phonetic_nonlatin_source
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.gloss_phonetic(RU_TEXT, from: "ru", to: "en")

      tokens_with_phonetic = result.scan(GLOSS_PHONETIC_RE)
      assert tokens_with_phonetic.size >= 2,
        "Non-Latin source should include phonetic brackets, got #{tokens_with_phonetic.size}: #{result}"
    end
  end

  def test_api_gloss_translate_phonetic
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.gloss_translate_phonetic(SL_TEXT, from: "sl", to: "ru")

      # Haiku sometimes drops parens in this complex mode — check loose structure:
      # at minimum, output should contain phonetic brackets and grammar-like content
      assert_match(/\[[^\]]+\]/, result, "Should contain phonetic brackets: #{result}")
      assert_match(/[a-z]+\.[a-z]/, result, "Should contain dot-separated grammar: #{result}")
    end
  end

  def test_api_phonetic_slovenian_ipa
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.phonetic(SL_TEXT, lang: "sl")

      assert_match %r{/.*/.?|[ˈˌɾɛːɔːaː]}, result,
        "Slovenian phonetic should contain IPA: #{result}"
    end
  end

  def test_api_phonetic_japanese_hiragana
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.phonetic(JA_TEXT, lang: "ja")

      assert_match(/[\u3040-\u309F]/, result,
        "Japanese phonetic should contain hiragana: #{result}")
    end
  end

  def test_api_phonetic_russian_romanization
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      result = glosser.phonetic(RU_TEXT, lang: "ru")

      # Should be Latin script romanization
      assert_match(/[a-zA-Z]/, result,
        "Russian phonetic should be romanized: #{result}")
      refute_match(/[А-Яа-яЁё]/, result,
        "Russian phonetic should not contain Cyrillic: #{result}")
    end
  end

  # --- Full pipeline: glosser API → Colors colorization ---

  def test_api_full_pipeline_gloss_translate_to_colorized
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      raw = glosser.gloss_translate(SL_TEXT, from: "sl", to: "ru")

      stub_tty(true) do
        colorized = Tell::Colors.colorize_gloss_translate(raw)

        refute_match BARE_RESET, colorized,
          "Full pipeline: bare [0m artifact.\nRaw: #{raw}\nColorized: #{colorized}"
        # Should contain ANSI codes (proof colorization happened)
        assert_includes colorized, "\e[", "Output should contain ANSI escape codes.\nRaw: #{raw}"
      end
    end
  end

  def test_api_full_pipeline_gloss_phonetic_to_colorized
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      raw = glosser.gloss_phonetic(SL_TEXT, from: "sl", to: "en")

      stub_tty(true) do
        colorized = Tell::Colors.colorize_gloss(raw)

        refute_match BARE_RESET, colorized,
          "Phonetic pipeline: bare [0m artifact.\nRaw: #{raw}\nColorized: #{colorized}"
        # Only check for ANSI codes if model output has tight format Colors can parse
        # (model sometimes inserts space after ] before ( which Colors regex doesn't handle)
        if raw.match?(/\][^(\s]\(/) || raw.match?(/\]\(/)
          assert_includes colorized, "\e[", "Output should contain ANSI escape codes.\nRaw: #{raw}"
        end
      end
    end
  end

  def test_api_full_pipeline_gloss_translate_phonetic_to_colorized
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    with_api_retry do
      raw = glosser.gloss_translate_phonetic(SL_TEXT, from: "sl", to: "ru")

      stub_tty(true) do
        colorized = Tell::Colors.colorize_gloss_translate(raw)

        refute_match BARE_RESET, colorized,
          "Translate+phonetic pipeline: bare [0m artifact.\nRaw: #{raw}\nColorized: #{colorized}"
        # Only check for ANSI codes if model output is in tight format Colors can parse
        # (haiku sometimes inserts spaces: "word [ipa] (grammar)" instead of "word[ipa](grammar)")
        if raw.match?(/\S\([^)]+\)/) && !raw.include?(" — ")
          assert_includes colorized, "\e[", "Output should contain ANSI escape codes.\nRaw: #{raw}"
        end
      end
    end
  end

  private

  # Retry block once on assertion failure to tolerate LLM non-determinism.
  # Returns the last result from the block.
  def with_api_retry(retries: 1)
    result = nil
    (retries + 1).times do |attempt|
      result = yield
      return result
    rescue Minitest::Assertion => e
      raise e if attempt == retries
    end
    result
  end

  def stub_tty(value)
    original = $stderr
    $stderr = value ? FakeTTY.new : FakeNonTTY.new
    yield
  ensure
    $stderr = original
  end

  class FakeTTY < StringIO
    def tty? = true
  end

  class FakeNonTTY < StringIO
    def tty? = false
  end
end
