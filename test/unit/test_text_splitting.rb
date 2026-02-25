# frozen_string_literal: true

require_relative "../test_helper"
require "agents/tts_agent"

class TestTextSplitting < Minitest::Test
  def setup
    # We test private methods via send — no API keys needed
    @max_chars = TTSAgent::MAX_CHARS
  end

  def test_short_text_returns_single_chunk
    chunks = split("Hello, this is a short text.")
    assert_equal 1, chunks.length
    assert_equal "Hello, this is a short text.", chunks[0]
  end

  def test_splits_on_paragraph_boundary
    para1 = "A" * 5000
    para2 = "B" * 5000
    text = "#{para1}\n\n#{para2}"

    chunks = split(text)
    assert_equal 2, chunks.length
    assert_equal para1, chunks[0]
    assert_equal para2, chunks[1]
  end

  def test_splits_on_sentence_boundary
    # No paragraph breaks — should split on sentence ending
    sentence1 = "A" * 7000 + "."
    sentence2 = " " + "B" * 5000
    text = sentence1 + sentence2

    chunks = split(text)
    assert_equal 2, chunks.length
    assert_equal sentence1, chunks[0]
    assert_equal sentence2.strip, chunks[1]
  end

  def test_splits_on_comma
    # No paragraph or sentence breaks — should split on comma
    part1 = "A" * 7000 + ","
    part2 = " " + "B" * 5000
    text = part1 + part2

    chunks = split(text)
    assert_equal 2, chunks.length
    # Split happens at the comma position; comma stays in second chunk
    assert_equal "A" * 7000, chunks[0]
  end

  def test_splits_on_whitespace
    # No punctuation at all — should split on whitespace
    word = "A" * 4000
    text = ([word] * 4).join(" ")

    chunks = split(text)
    assert chunks.length >= 2, "Expected at least 2 chunks for #{text.length} chars"
    chunks.each do |chunk|
      assert chunk.length <= @max_chars, "Chunk too long: #{chunk.length}"
    end
  end

  def test_utf8_multibyte_characters
    # Slovenian diacritics: č, š, ž
    text = "Dober dan. " + "Živijo, čestitke in pozdrave. " * 400
    chunks = split(text)

    chunks.each do |chunk|
      assert chunk.valid_encoding?, "Chunk has invalid encoding"
      assert chunk.length <= @max_chars, "Chunk too long: #{chunk.length}"
    end
  end

  def test_find_safe_split_point_basic
    agent = build_agent
    text = "Hello world, this is a test"
    pos = agent.send(:find_safe_split_point, text, 10)
    assert pos > 0
    assert pos <= 10
  end

  def test_find_safe_split_point_multibyte
    agent = build_agent
    text = "aaaa" + "čšž" * 100
    pos = agent.send(:find_safe_split_point, text, 10)
    # Should land on the ASCII boundary at position 4 or earlier
    assert pos > 0
    assert text[0...pos].valid_encoding?
  end

  def test_all_chunks_under_max_chars
    text = "Hello world. " * 1000
    chunks = split(text)
    chunks.each do |chunk|
      assert chunk.length <= @max_chars, "Chunk exceeds MAX_CHARS: #{chunk.length}"
    end
  end

  private

  def build_agent
    # Stub ENV to avoid fetch errors
    ENV["ELEVENLABS_API_KEY"] ||= "test_key"
    ENV["ELEVENLABS_VOICE_ID"] ||= "test_voice"
    TTSAgent.new
  end

  def split(text)
    build_agent.send(:split_text, text)
  end
end
