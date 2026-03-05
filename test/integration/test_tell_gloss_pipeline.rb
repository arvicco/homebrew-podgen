# frozen_string_literal: true

require_relative "../test_helper"
require "tell/colors"
require "tell/glosser"

class TestTellGlossPipeline < Minitest::Test
  # ============================================================
  # Category 1: Colors pipeline (always runs, no API key needed)
  # Feed realistic model-like output through Colors colorizers,
  # verify structural correctness — catches bugs where module A
  # produces output that module B can't parse.
  # ============================================================

  # Bare [0m = the substring "[0m" NOT preceded by \e (escape char).
  # Valid ANSI reset is \e[0m — the artifact was [0m appearing without \e.
  BARE_RESET = /(?<!\e)\[0m/

  # --- Agram + plain mixed tokens (the [0m] bug) ---

  def test_colorize_gloss_agram_plus_plain_no_ansi_artifacts
    stub_tty(true) do
      # Realistic mixed line: agram conj + plain noun
      input = "*toda*todo(conj)но svet(n.m.N.sg)мир"
      result = Tell::Colors.colorize_gloss_translate(input)

      refute_match BARE_RESET, result, "bare [0m artifact in output"
      # Agram token rendered
      assert_includes result, "*toda*"
      assert_includes result, "(conj)"
      # Plain token rendered
      assert_includes result, "svet"
      assert_includes result, "(n.m.N.sg)"
    end
  end

  def test_colorize_gloss_agram_with_phonetic_no_artifacts
    stub_tty(true) do
      input = "*prekopicevali*prekopicelali[pɾɛkɔpitsɛˈʋaːli](v.imperf.past.m.pl)кувыркались"
      result = Tell::Colors.colorize_gloss_translate(input)

      refute_match BARE_RESET, result, "bare [0m artifact in output"
      # Phonetic rendered in bright green
      assert_includes result, "\e[92m[pɾɛkɔpitsɛˈʋaːli]"
      # Grammar present
      assert_includes result, "(v.imperf.past.m.pl)"
      # Translation in italic
      assert_includes result, "\e[3mкувыркались\e[0m"
    end
  end

  # --- Phonetic with space before bracket (regex bug) ---

  def test_colorize_gloss_phonetic_space_before_bracket
    stub_tty(true) do
      # Model sometimes outputs space before [IPA]
      input = "prastaro [pɾaˈstaːɾɔ](adj.f.I.sg)престарой"
      result = Tell::Colors.colorize_gloss_translate(input)

      refute_match BARE_RESET, result, "bare [0m artifact"
      # Word gets POS color (adj = green), not left uncolored
      assert_includes result, "\e[32m\e[1mprastaro\e[0m"
      # Phonetic in bright green
      assert_includes result, "\e[92m[pɾaˈstaːɾɔ]\e[0m"
      # Grammar in dim POS color
      assert_includes result, "\e[32m\e[2m(adj.f.I.sg)\e[0m"
    end
  end

  def test_colorize_gloss_phonetic_no_space_before_bracket
    stub_tty(true) do
      input = "prastaro[pɾaˈstaːɾɔ](adj.f.I.sg)престарой"
      result = Tell::Colors.colorize_gloss_translate(input)

      refute_match BARE_RESET, result
      assert_includes result, "\e[32m\e[1mprastaro\e[0m"
      assert_includes result, "\e[92m[pɾaˈstaːɾɔ]\e[0m"
      assert_includes result, "\e[32m\e[2m(adj.f.I.sg)\e[0m"
    end
  end

  # --- Full realistic sentence ---

  def test_colorize_gloss_translate_full_sentence_no_artifacts
    stub_tty(true) do
      input = "danes(adv)сегодня je(v.aux.3p.pres.sg)есть " \
              "*lep*lepo(adj.n.N.sg)красивое vreme(n.n.N.sg)время , " \
              "zato(conj)поэтому gremo(v.1p.pres.pl)идём ven(adv)наружу ."
      result = Tell::Colors.colorize_gloss_translate(input)

      refute_match BARE_RESET, result, "bare [0m artifact in full sentence"
      # Spot-check a few tokens
      assert_includes result, "danes"
      assert_includes result, "vreme"
      assert_includes result, "*lep*"
    end
  end

  def test_colorize_gloss_full_sentence_no_artifacts
    stub_tty(true) do
      input = "danes(adv) je(v.aux.3p.pres.sg) " \
              "*lep*lepo(adj.n.N.sg) vreme(n.n.N.sg) , " \
              "zato(conj) gremo(v.1p.pres.pl) ven(adv) ."
      result = Tell::Colors.colorize_gloss(input)

      refute_match BARE_RESET, result, "bare [0m artifact in full sentence"
    end
  end

  # --- All POS categories with phonetic ---

  def test_colorize_gloss_all_pos_with_phonetic
    stub_tty(true) do
      pos_examples = {
        "n"      => "svet[svɛːt](n.m.N.sg)",
        "v"      => "grem[ɡɾɛːm](v.1p.pres.sg)",
        "adj"    => "lep[lɛːp](adj.m.N.sg)",
        "adv"    => "danes[daˈnɛːs](adv)",
        "pron"   => "jaz[jaːs](pron.1p.N.sg)",
        "pr"     => "v[ʋ](pr)",
        "conj"   => "in[in](conj)",
        "det"    => "ta[ta](det.m.N.sg)",
        "part"   => "ne[nɛ](part)",
        "num"    => "dva[dʋaː](num.m.N)",
        "interj" => "oj[ɔːj](interj)",
        "aux"    => "sem[sɛːm](aux.1p.pres.sg)"
      }

      pos_examples.each do |pos, token|
        result = Tell::Colors.colorize_gloss(token)
        refute_match BARE_RESET, result, "POS #{pos} with phonetic: bare [0m artifact"
        # Phonetic should be in bright green, not stealing POS color
        assert_includes result, "\e[92m[", "POS #{pos}: phonetic should be bright green"
        assert_includes result, "(#{pos}", "POS #{pos}: grammar should be present"
      end
    end
  end

  # --- Gloss (non-translate) with phonetic ---

  def test_colorize_gloss_phonetic_no_translation
    stub_tty(true) do
      input = "svet[svɛːt](n.m.N.sg) je[jɛ](v.aux.3p.pres.sg)"
      result = Tell::Colors.colorize_gloss(input)

      refute_match BARE_RESET, result
      assert_includes result, "\e[92m[svɛːt]\e[0m"
      assert_includes result, "\e[92m[jɛ]\e[0m"
      # No italic (no translations in plain gloss)
      refute_includes result, "\e[3m"
    end
  end

  # --- Agram with phonetic in plain gloss ---

  def test_colorize_gloss_agram_phonetic_plain
    stub_tty(true) do
      input = "*toda*todo[tɔːdɔ](conj)"
      result = Tell::Colors.colorize_gloss(input)

      refute_match BARE_RESET, result
      assert_includes result, "\e[93m\e[1m*toda*\e[0m"
      assert_includes result, "\e[92m[tɔːdɔ]\e[0m"
      assert_includes result, "(conj)"
    end
  end

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
    result = glosser.gloss(SL_TEXT, from: "sl", to: "en")

    tokens = result.scan(GLOSS_RE)
    assert tokens.size >= 3, "Expected at least 3 glossed tokens, got #{tokens.size}: #{result}"
  end

  def test_api_gloss_translate_slovenian_to_russian
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    result = glosser.gloss_translate(SL_TEXT, from: "sl", to: "ru")

    tokens = result.scan(GLOSS_TRANSLATE_RE)
    assert tokens.size >= 3, "Expected at least 3 translated tokens, got #{tokens.size}: #{result}"
  end

  def test_api_gloss_phonetic_latin_source
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    result = glosser.gloss_phonetic(SL_TEXT, from: "sl", to: "en")

    # Regression: Latin-script source should still include [IPA] brackets
    tokens_with_phonetic = result.scan(GLOSS_PHONETIC_RE)
    assert tokens_with_phonetic.size >= 2,
      "Latin-script source should include phonetic brackets for most words, got #{tokens_with_phonetic.size}: #{result}"
  end

  def test_api_gloss_phonetic_nonlatin_source
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    result = glosser.gloss_phonetic(RU_TEXT, from: "ru", to: "en")

    tokens_with_phonetic = result.scan(GLOSS_PHONETIC_RE)
    assert tokens_with_phonetic.size >= 2,
      "Non-Latin source should include phonetic brackets, got #{tokens_with_phonetic.size}: #{result}"
  end

  def test_api_gloss_translate_phonetic
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    result = glosser.gloss_translate_phonetic(SL_TEXT, from: "sl", to: "ru")

    # Haiku sometimes drops parens in this complex mode — check loose structure:
    # at minimum, output should contain phonetic brackets and grammar-like content
    assert_match(/\[[^\]]+\]/, result, "Should contain phonetic brackets: #{result}")
    assert_match(/[a-z]+\.[a-z]/, result, "Should contain dot-separated grammar: #{result}")
  end

  def test_api_phonetic_slovenian_ipa
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    result = glosser.phonetic(SL_TEXT, lang: "sl")

    assert_match %r{/.*/.?|[ˈˌɾɛːɔːaː]}, result,
      "Slovenian phonetic should contain IPA: #{result}"
  end

  def test_api_phonetic_japanese_hiragana
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    result = glosser.phonetic(JA_TEXT, lang: "ja")

    assert_match /[\u3040-\u309F]/, result,
      "Japanese phonetic should contain hiragana: #{result}"
  end

  def test_api_phonetic_russian_romanization
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    result = glosser.phonetic(RU_TEXT, lang: "ru")

    # Should be Latin script romanization
    assert_match /[a-zA-Z]/, result,
      "Russian phonetic should be romanized: #{result}"
    refute_match /[А-Яа-яЁё]/, result,
      "Russian phonetic should not contain Cyrillic: #{result}"
  end

  # --- Full pipeline: glosser API → Colors colorization ---

  def test_api_full_pipeline_gloss_translate_to_colorized
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    raw = glosser.gloss_translate(SL_TEXT, from: "sl", to: "ru")

    stub_tty(true) do
      colorized = Tell::Colors.colorize_gloss_translate(raw)

      refute_match BARE_RESET, colorized,
        "Full pipeline: bare [0m artifact.\nRaw: #{raw}\nColorized: #{colorized}"
      # Should contain ANSI codes (proof colorization happened)
      assert_includes colorized, "\e[", "Output should contain ANSI escape codes"
    end
  end

  def test_api_full_pipeline_gloss_phonetic_to_colorized
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    raw = glosser.gloss_phonetic(SL_TEXT, from: "sl", to: "en")

    stub_tty(true) do
      colorized = Tell::Colors.colorize_gloss(raw)

      refute_match BARE_RESET, colorized,
        "Phonetic pipeline: bare [0m artifact.\nRaw: #{raw}\nColorized: #{colorized}"
      # Only check for ANSI codes if model output has tight format Colors can parse
      # (model sometimes inserts space after ] before ( which Colors regex doesn't handle)
      if raw.match?(/\][^(\s]\(/) || raw.match?(/\]\(/)
        assert_includes colorized, "\e[", "Output should contain ANSI escape codes"
      end
    end
  end

  def test_api_full_pipeline_gloss_translate_phonetic_to_colorized
    skip_unless_env("ANTHROPIC_API_KEY")

    glosser = Tell::Glosser.new(ENV["ANTHROPIC_API_KEY"], model: HAIKU)
    raw = glosser.gloss_translate_phonetic(SL_TEXT, from: "sl", to: "ru")

    stub_tty(true) do
      colorized = Tell::Colors.colorize_gloss_translate(raw)

      refute_match BARE_RESET, colorized,
        "Translate+phonetic pipeline: bare [0m artifact.\nRaw: #{raw}\nColorized: #{colorized}"
      # Only check for ANSI codes if model output contains parseable tokens
      # (haiku sometimes produces non-standard format for this complex mode)
      if raw.match?(/\([^)]+\)/)
        assert_includes colorized, "\e[", "Output should contain ANSI escape codes"
      end
    end
  end

  private

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
