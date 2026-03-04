# frozen_string_literal: true

require_relative "../test_helper"
require "tell/colors"

class TestTellColors < Minitest::Test
  # --- TTY gating ---

  def test_wrap_returns_plain_text_when_not_tty
    stub_tty(false) do
      assert_equal "hello", Tell::Colors.wrap("hello", Tell::Colors::RED)
    end
  end

  def test_wrap_returns_colored_text_when_tty
    stub_tty(true) do
      assert_equal "\e[31mhello\e[0m", Tell::Colors.wrap("hello", Tell::Colors::RED)
    end
  end

  def test_wrap_combines_multiple_codes
    stub_tty(true) do
      assert_equal "\e[36m\e[1mhi\e[0m", Tell::Colors.wrap("hi", Tell::Colors::CYAN, Tell::Colors::BOLD)
    end
  end

  # --- Semantic helpers ---

  def test_tag_is_bold
    stub_tty(true) do
      assert_equal "\e[1mSL:\e[0m", Tell::Colors.tag("SL:")
    end
  end

  def test_forward_is_cyan
    stub_tty(true) do
      assert_equal "\e[36mdobro jutro\e[0m", Tell::Colors.forward("dobro jutro")
    end
  end

  def test_reverse_is_yellow
    stub_tty(true) do
      assert_equal "\e[33mgood morning\e[0m", Tell::Colors.reverse("good morning")
    end
  end

  def test_error_is_red
    stub_tty(true) do
      assert_equal "\e[31mfailed\e[0m", Tell::Colors.error("failed")
    end
  end

  def test_status_is_dark_gray
    stub_tty(true) do
      assert_equal "\e[90mSaved: out.mp3\e[0m", Tell::Colors.status("Saved: out.mp3")
    end
  end

  def test_warning_is_yellow
    stub_tty(true) do
      assert_equal "\e[33mwarn\e[0m", Tell::Colors.warning("warn")
    end
  end

  # --- POS extraction ---

  def test_extract_pos_noun
    assert_equal "n", Tell::Colors.extract_pos("n.m.N.sg")
  end

  def test_extract_pos_verb
    assert_equal "v", Tell::Colors.extract_pos("v.3p.pres")
  end

  def test_extract_pos_adjective
    assert_equal "adj", Tell::Colors.extract_pos("adj.m.sg.N")
  end

  def test_extract_pos_preposition
    assert_equal "pr", Tell::Colors.extract_pos("pr")
  end

  def test_extract_pos_auxiliary_first_match_is_verb
    # "v" matches before "aux" — first POS wins
    assert_equal "v", Tell::Colors.extract_pos("v.aux.3p.pres")
  end

  def test_extract_pos_standalone_auxiliary
    assert_equal "aux", Tell::Colors.extract_pos("aux.3p.pres")
  end

  def test_extract_pos_unknown_returns_nil
    assert_nil Tell::Colors.extract_pos("m.sg.N")
  end

  # --- Gloss colorization ---

  def test_colorize_gloss_basic
    stub_tty(true) do
      input = "svet(n.m.N.sg) je(v.aux.3p.pres)"
      result = Tell::Colors.colorize_gloss(input)

      # Noun should use red
      assert_includes result, "\e[31m\e[1msvet\e[0m"
      assert_includes result, "(n.m.N.sg)"
      # Verb should use cyan
      assert_includes result, "\e[36m\e[1mje\e[0m"
      assert_includes result, "(v.aux.3p.pres)"
    end
  end

  def test_colorize_gloss_passthrough_when_not_tty
    stub_tty(false) do
      input = "svet(n.m.N.sg)"
      assert_equal input, Tell::Colors.colorize_gloss(input)
    end
  end

  def test_colorize_gloss_translate_basic
    stub_tty(true) do
      input = "svet(n.m.N.sg)world je(v.aux.3p.pres)is"
      result = Tell::Colors.colorize_gloss_translate(input)

      assert_includes result, "\e[31m\e[1msvet\e[0m"
      assert_includes result, "\e[3mworld\e[0m"
      assert_includes result, "\e[36m\e[1mje\e[0m"
      assert_includes result, "\e[3mis\e[0m"
    end
  end

  def test_colorize_gloss_translate_passthrough_when_not_tty
    stub_tty(false) do
      input = "svet(n.m.N.sg)world"
      assert_equal input, Tell::Colors.colorize_gloss_translate(input)
    end
  end

  # --- Graceful degradation ---

  def test_colorize_gloss_leaves_unmatched_tokens
    stub_tty(true) do
      input = "hello svet(n.m.N.sg) world"
      result = Tell::Colors.colorize_gloss(input)

      # Unmatched tokens pass through
      assert_includes result, "hello "
      assert_includes result, " world"
      # Matched token is colored
      assert_includes result, "\e[1msvet\e[0m"
    end
  end

  def test_colorize_gloss_unknown_pos_still_formats
    stub_tty(true) do
      # Grammar with no recognized POS category
      input = "foo(m.sg.N)"
      result = Tell::Colors.colorize_gloss(input)

      # Should still apply bold to word (with empty color prefix)
      assert_includes result, "\e[1mfoo\e[0m"
      assert_includes result, "(m.sg.N)"
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
