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
