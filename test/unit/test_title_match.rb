# frozen_string_literal: true

require_relative "../test_helper"
require "title_match"

class TestTitleMatch < Minitest::Test
  def test_stem_drops_subtitle_after_first_separator
    assert_equal "il lupo e il pastore", TitleMatch.stem("Il lupo e il pastore. Una favola di Esopo")
    assert_equal "il lupo e il pastore", TitleMatch.stem("Il lupo e il pastore — e altre favole")
    assert_equal "il lupo e il pastore", TitleMatch.stem("Il lupo e il pastore – e altre favole")
    assert_equal "il lupo e il pastore", TitleMatch.stem("Il lupo e il pastore - e altre favole")
    assert_equal "il lupo e il pastore", TitleMatch.stem("Il lupo e il pastore: e altre favole")
    assert_equal "il lupo e il pastore", TitleMatch.stem("Il lupo e il pastore | Esopo")
  end

  def test_stem_cuts_at_first_separator_of_any_kind
    assert_equal "la volpe", TitleMatch.stem("La volpe: e il corvo. Esopo")
  end

  def test_stem_folds_case_diacritics_and_punctuation
    assert_equal "la cigarra y la hormiga", TitleMatch.stem("¡La Cigarra y la Hormiga!")
    assert_equal "zlata ribica", TitleMatch.stem("Zlatá ribica")
  end

  def test_stem_short_stem_falls_back_to_whole_title
    assert_equal "zec 1 kornjaca", TitleMatch.stem("Zec - 1 kornjača")
  end

  def test_match_subtitle_extension_matches
    assert TitleMatch.match?("Il lupo e il pastore", "Il lupo e il pastore. Una favola di Esopo")
  end

  def test_match_different_story_same_opening_does_not_match
    refute TitleMatch.match?("Il lupo e il pastore", "Il lupo e i sette capretti")
  end

  def test_match_prefix_with_shorter_at_least_twelve_chars_matches
    assert TitleMatch.match?("Il lupo e il pastore", "Il lupo e il pastore e altre favole di Esopo")
  end

  def test_match_prefix_shorter_than_twelve_chars_does_not_match
    refute TitleMatch.match?("Il lupo e", "Il lupo e il cane dei vicini")
  end

  def test_match_token_set_jaccard_matches_reordered_title
    assert TitleMatch.match?("La volpe e l'uva — favola", "L'uva e la volpe")
  end

  def test_match_blank_titles_never_match
    refute TitleMatch.match?("", "")
    refute TitleMatch.match?(nil, "Il lupo e il pastore")
  end
end
