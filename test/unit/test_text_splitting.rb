# frozen_string_literal: true

require_relative "../test_helper"
require "text_splitter"

class TestTextSplitting < Minitest::Test
  def setup
    @max_chars = TextSplitter::DEFAULT_MAX_CHARS
    @splitter = TextSplitter.new
  end

  def test_short_text_returns_single_chunk
    chunks = @splitter.split("Hello, this is a short text.")
    assert_equal 1, chunks.length
    assert_equal "Hello, this is a short text.", chunks[0]
  end

  def test_splits_on_paragraph_boundary
    para1 = "A" * 5000
    para2 = "B" * 5000
    text = "#{para1}\n\n#{para2}"

    chunks = @splitter.split(text)
    assert_equal 2, chunks.length
    assert_equal para1, chunks[0]
    assert_equal para2, chunks[1]
  end

  def test_splits_on_sentence_boundary
    # No paragraph breaks — should split on sentence ending
    sentence1 = "A" * 7000 + "."
    sentence2 = " " + "B" * 5000
    text = sentence1 + sentence2

    chunks = @splitter.split(text)
    assert_equal 2, chunks.length
    assert_equal sentence1, chunks[0]
    assert_equal sentence2.strip, chunks[1]
  end

  def test_splits_on_comma
    # No paragraph or sentence breaks — should split on comma
    part1 = "A" * 7000 + ","
    part2 = " " + "B" * 5000
    text = part1 + part2

    chunks = @splitter.split(text)
    assert_equal 2, chunks.length
    # Split happens at the comma position; comma stays in second chunk
    assert_equal "A" * 7000, chunks[0]
  end

  def test_splits_on_whitespace
    # No punctuation at all — should split on whitespace
    word = "A" * 4000
    text = ([word] * 4).join(" ")

    chunks = @splitter.split(text)
    assert chunks.length >= 2, "Expected at least 2 chunks for #{text.length} chars"
    chunks.each do |chunk|
      assert chunk.length <= @max_chars, "Chunk too long: #{chunk.length}"
    end
  end

  def test_utf8_multibyte_characters
    # Slovenian diacritics: č, š, ž
    text = "Dober dan. " + "Živijo, čestitke in pozdrave. " * 400
    chunks = @splitter.split(text)

    chunks.each do |chunk|
      assert chunk.valid_encoding?, "Chunk has invalid encoding"
      assert chunk.length <= @max_chars, "Chunk too long: #{chunk.length}"
    end
  end

  def test_all_chunks_under_max_chars
    text = "Hello world. " * 1000
    chunks = @splitter.split(text)
    chunks.each do |chunk|
      assert chunk.length <= @max_chars, "Chunk exceeds MAX_CHARS: #{chunk.length}"
    end
  end
end
