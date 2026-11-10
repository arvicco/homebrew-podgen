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
    # P17-3 (Q-135): split AFTER the comma, so TTS never reads ", B..."
    assert_equal part1, chunks[0]
    assert chunks[0].end_with?(","), "chunk 0 ends with the comma"
    assert_equal "B" * 5000, chunks[1]
  end

  def test_splits_after_semicolon_and_colon
    %w[; :].each do |mark|
      text = "A" * 7000 + mark + " " + "B" * 5000
      chunks = @splitter.split(text)
      assert_equal "A" * 7000 + mark, chunks[0]
      assert_equal "B" * 5000, chunks[1]
    end
  end

  # P17-3 (Q-135): CJK sentence ends (no space follows them) are sentence
  # boundaries, as in TimestampPersister::SENTENCE_END.
  def test_splits_on_cjk_sentence_end_without_space
    %w[。 ！ ？].each do |mark|
      sentence1 = "あ" * 7000 + mark
      sentence2 = "い" * 5000
      chunks = @splitter.split(sentence1 + sentence2)
      assert_equal [sentence1, sentence2], chunks, "split after #{mark}"
    end
  end

  # P18-8 (6): a closing quote/bracket after the sentence end stays with
  # the sentence, not at the start of the next TTS chunk.
  def test_cjk_sentence_end_keeps_closing_bracket_in_the_chunk
    %w[」 』 ） 」』].each do |close|
      sentence1 = "「" + "あ" * 7000 + "。" + close
      sentence2 = "い" * 5000
      chunks = @splitter.split(sentence1 + sentence2)
      assert_equal [sentence1, sentence2], chunks, "split after 。#{close}"
    end
  end

  def test_cjk_closing_bracket_without_sentence_end_is_not_a_boundary
    text = "「" + "あ" * 7000 + "」" + "い" * 5000
    chunks = @splitter.split(text)
    refute chunks[0].end_with?("」"), "a bare 」 is not a sentence end"
  end

  def test_cjk_sentence_end_preferred_over_comma
    text = "あ" * 6000 + "。" + "い" * 1000 + "、, " + "う" * 5000
    chunks = @splitter.split(text)
    assert chunks[0].end_with?("。"), "sentence end wins over a later comma"
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
