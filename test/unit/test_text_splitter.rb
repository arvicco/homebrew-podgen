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
end
