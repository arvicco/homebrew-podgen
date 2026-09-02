# frozen_string_literal: true

require_relative "../test_helper"
require "text_splitter"

class TestTextSplitter < Minitest::Test
  def setup
    @splitter = TextSplitter.new(max_chars: 100)
  end

  def test_short_text_single_chunk
    result = @splitter.split("Hello world")
    assert_equal ["Hello world"], result
  end

  def test_splits_at_paragraph_boundary
    text = "First paragraph." + " " * 50 + "\n\n" + "Second paragraph." + " " * 50
    result = @splitter.split(text)
    assert_equal 2, result.length
    assert_includes result[0], "First paragraph."
    assert_includes result[1], "Second paragraph."
  end

  def test_splits_at_sentence_boundary
    # No paragraph break, but has sentence endings
    text = "First sentence. " + "A" * 80 + ". " + "B" * 20
    result = @splitter.split(text)
    assert result.length >= 2
    assert result.all? { |c| c.length <= 100 }
  end

  def test_splits_at_comma_boundary
    text = "Word, " * 20
    result = @splitter.split(text.strip)
    assert result.length >= 2
    assert result.all? { |c| c.length <= 100 }
  end

  def test_splits_at_whitespace
    text = "word " * 25
    result = @splitter.split(text.strip)
    assert result.length >= 2
    assert result.all? { |c| c.length <= 100 }
  end

  def test_utf8_safe_split
    splitter = TextSplitter.new(max_chars: 10)
    # Use a string where multibyte chars would be at the boundary
    text = "ščž " * 5
    result = splitter.split(text.strip)
    assert result.length >= 2
    # All chunks should be valid UTF-8
    result.each { |c| assert c.valid_encoding? }
  end

  def test_preserves_all_content
    text = "word " * 50
    result = @splitter.split(text.strip)
    rejoined = result.join(" ")
    # All original words should be present
    assert_equal 50, rejoined.scan(/word/).length
  end

  def test_respects_max_chars
    splitter = TextSplitter.new(max_chars: 50)
    text = "This is a test sentence. " * 10
    result = splitter.split(text.strip)
    assert result.all? { |c| c.length <= 50 }
  end

  def test_default_max_chars
    splitter = TextSplitter.new
    assert_equal [("a" * 9500)], splitter.split("a" * 9500)
  end

  def test_empty_string
    assert_equal [""], @splitter.split("")
  end

  def test_exactly_max_chars
    text = "a" * 100
    assert_equal [text], @splitter.split(text)
  end

  # --- boundary priority (characterization: paragraph > sentence > comma > whitespace) ---
  # The priority chain lives in #split; #find_safe_split_point is only the
  # final UTF-8-safe fallback when no whitespace exists at all.

  def test_split_prefers_paragraph_over_sentence
    text = "First. Second.\n\n#{"x" * 100}"
    result = @splitter.split(text)
    assert_equal ["First. Second.", "x" * 100], result
  end

  def test_split_prefers_sentence_over_later_comma
    # Comma boundary at index 8 is later than the sentence boundary at 4,
    # but the sentence pattern is tried first and wins.
    text = "Aaa. Bbb, ccc #{"z" * 91}"
    result = @splitter.split(text)
    assert_equal ["Aaa.", "Bbb, ccc #{"z" * 91}"], result
  end

  def test_split_prefers_comma_over_later_whitespace
    # Characterization: the comma pattern matches AT the comma, so the
    # first chunk ends before it and the comma leads the next chunk.
    text = "aaa, bbb ccc #{"z" * 90}"
    result = @splitter.split(text)
    assert_equal ["aaa", ", bbb ccc #{"z" * 90}"], result
  end

  def test_split_falls_back_to_whitespace
    text = "#{"a" * 50} #{"b" * 60}"
    result = @splitter.split(text)
    assert_equal ["a" * 50, "b" * 60], result
  end

  # --- find_safe_split_point (characterization, private) ---

  def test_find_safe_split_point_walks_back_to_ascii_char
    text = "#{"あ" * 10}a#{"あ" * 10}"
    assert_equal 10, @splitter.send(:find_safe_split_point, text, 15)
  end

  def test_find_safe_split_point_all_multibyte_returns_max_pos
    # No ASCII or whitespace anywhere — pos reaches 0, max_pos returned.
    assert_equal 15, @splitter.send(:find_safe_split_point, "あ" * 30, 15)
  end

  def test_split_unbroken_multibyte_text_splits_at_max_chars
    text = "あ" * 120
    result = @splitter.split(text)
    assert_equal ["あ" * 100, "あ" * 20], result
    # String slicing is character-based, so no UTF-8 char is bisected.
    assert result.all?(&:valid_encoding?)
  end
end
