# frozen_string_literal: true

require_relative "../test_helper"
require "audio_trimmer"

class TestAudioTrimmer < Minitest::Test
  # --- find_speech_end_timestamp ---

  def test_find_speech_end_exact_match
    groq_words = [
      { word: "Hello", start: 0.0, end: 0.5 },
      { word: "world", start: 0.6, end: 1.0 },
      { word: "this", start: 1.1, end: 1.5 },
      { word: "is", start: 1.6, end: 1.8 },
      { word: "great", start: 1.9, end: 2.5 }
    ]

    result = trimmer.find_speech_end_timestamp("Hello world this is great", groq_words)
    assert_in_delta 2.5, result
  end

  def test_find_speech_end_fuzzy_prefix_match
    groq_words = [
      { word: "Lepo", start: 0.0, end: 0.5 },
      { word: "sanja", start: 0.6, end: 1.2 }
    ]

    result = trimmer.find_speech_end_timestamp("Lepo sanjam", groq_words)
    assert_in_delta 1.2, result
  end

  def test_find_speech_end_no_match
    groq_words = [
      { word: "completely", start: 0.0, end: 0.5 },
      { word: "different", start: 0.6, end: 1.0 }
    ]

    result = trimmer.find_speech_end_timestamp("Hello world", groq_words)
    assert_nil result
  end

  def test_find_speech_end_empty_text
    result = trimmer.find_speech_end_timestamp("", [])
    assert_nil result
  end

  def test_find_speech_end_single_word_fallback_disabled
    # Single-word matching is too brittle — common words match mid-audio.
    # Regression: bajke-2026-04-30 wrongly cut 48s because last 5..2 words
    # didn't match groq, fell back to "dekleta" which appears throughout.
    groq_words = [
      { word: "Hello", start: 0.0, end: 0.5 },
      { word: "world", start: 0.6, end: 1.0 }
    ]
    result = trimmer.find_speech_end_timestamp("world", groq_words)
    assert_nil result, "n=1 fallback must be disabled"
  end

  def test_find_speech_end_two_word_fallback_still_works
    groq_words = [
      { word: "Once", start: 0.0, end: 0.4 },
      { word: "upon", start: 0.4, end: 0.7 },
      { word: "a",    start: 0.7, end: 0.9 },
      { word: "time", start: 0.9, end: 1.4 }
    ]
    result = trimmer.find_speech_end_timestamp("a time", groq_words)
    assert_in_delta 1.4, result
  end

  def test_find_speech_end_skips_match_too_far_from_groq_end
    # The bajke scenario: last reconciled words don't appear in groq, falls
    # back to a shorter target that matches MID-AUDIO, far from groq's actual
    # last word. Should refuse (return nil) so autotrim is skipped.
    groq_words = []
    # "the end" appears at second 5.0 — and we want it to match here naively
    groq_words << { word: "the",  start: 5.0, end: 5.3 }
    groq_words << { word: "end",  start: 5.3, end: 5.7 }
    # ...but groq has many more words after (audio actually goes to 60s)
    (6..59).each do |t|
      groq_words << { word: "filler#{t}", start: t.to_f, end: t + 0.5 }
    end
    groq_words << { word: "kraj", start: 59.0, end: 59.6 } # groq's last word

    # Reconciled text last 2 words ("the end") match at 5.7s, but groq's
    # last word is at 59.6s — that's a 53.9s gap, way over the threshold.
    result = trimmer.find_speech_end_timestamp("once upon a time the end", groq_words)
    assert_nil result, "should refuse match that's too far before groq's last word"
  end

  def test_find_speech_end_handles_nil_end_in_last_groq_word
    # Some upstream STT outputs omit :end on the final word.
    # Should return nil (skip autotrim) rather than raise.
    groq_words = [
      { word: "hello", start: 0.0, end: 1.0 },
      { word: "world", start: 1.0, end: nil }
    ]
    result = nil
    assert_silent do
      # Don't actually need silence — just that it doesn't raise.
    end
    begin
      result = trimmer.find_speech_end_timestamp("hello world", groq_words)
    rescue NoMethodError => e
      flunk "should not raise on nil :end (got: #{e.message})"
    end
    assert_nil result
  end

  def test_find_speech_end_accepts_match_near_groq_end
    groq_words = [
      { word: "filler", start: 0.0,  end: 0.5  },
      { word: "the",    start: 58.0, end: 58.4 },
      { word: "end",    start: 58.4, end: 58.9 }
    ]
    # Last "the end" matches at 58.9s, groq's last word ends at 58.9s → gap 0.
    result = trimmer.find_speech_end_timestamp("once the end", groq_words)
    assert_in_delta 58.9, result
  end

  def test_find_speech_end_ignores_punctuation
    groq_words = [
      { word: "Hello,", start: 0.0, end: 0.5 },
      { word: "world!", start: 0.6, end: 1.0 }
    ]

    result = trimmer.find_speech_end_timestamp("Hello, world!", groq_words)
    assert_in_delta 1.0, result
  end

  def test_find_speech_end_case_insensitive
    groq_words = [
      { word: "HELLO", start: 0.0, end: 0.5 },
      { word: "WORLD", start: 0.6, end: 1.0 }
    ]

    result = trimmer.find_speech_end_timestamp("hello world", groq_words)
    assert_in_delta 1.0, result
  end

  # --- format_timestamp ---

  def test_format_timestamp
    assert_equal "0:00.0", trimmer.format_timestamp(0)
    assert_equal "1:30.0", trimmer.format_timestamp(90)
    assert_equal "2:05.5", trimmer.format_timestamp(125.5)
  end

  # --- apply_trim ---

  def test_apply_trim_no_args_returns_original
    path = trimmer.apply_trim("/input.mp3")
    assert_equal "/input.mp3", path
  end

  def test_apply_trim_zero_skip_returns_original
    path = trimmer.apply_trim("/input.mp3", skip: 0)
    assert_equal "/input.mp3", path
  end

  def test_apply_trim_with_skip
    path = trimmer.apply_trim("/input.mp3", skip: 10)
    refute_equal "/input.mp3", path
    keeps = @mock_assembler.snip_calls.first[:keeps]
    assert_equal 1, keeps.length
    assert_in_delta 10.0, keeps.first.from
    assert_in_delta 100.0, keeps.first.to
  end

  def test_apply_trim_with_cut
    path = trimmer.apply_trim("/input.mp3", cut: 20)
    refute_equal "/input.mp3", path
    keeps = @mock_assembler.snip_calls.first[:keeps]
    assert_equal 1, keeps.length
    assert_in_delta 0.0, keeps.first.from
    assert_in_delta 80.0, keeps.first.to
  end

  def test_apply_trim_with_skip_and_cut
    trimmer.apply_trim("/input.mp3", skip: 10, cut: 20)
    keeps = @mock_assembler.snip_calls.first[:keeps]
    assert_equal 1, keeps.length
    assert_in_delta 10.0, keeps.first.from
    assert_in_delta 80.0, keeps.first.to
  end

  def test_apply_trim_with_absolute_cut
    cut_val = AbsoluteValue.new(30.0)
    trimmer.apply_trim("/input.mp3", cut: cut_val)
    keeps = @mock_assembler.snip_calls.first[:keeps]
    assert_in_delta 0.0, keeps.first.from
    assert_in_delta 30.0, keeps.first.to
  end

  def test_apply_trim_invalid_cut_returns_original
    # Cut 200s from 100s total → cut_point = -100 → invalid
    path = trimmer.apply_trim("/input.mp3", cut: 200)
    assert_equal "/input.mp3", path
    assert_empty @mock_assembler.snip_calls
  end

  def test_apply_trim_tracks_temp_files
    trimmer.apply_trim("/input.mp3", skip: 10)
    assert_equal 1, trimmer.temp_files.length
  end

  # --- trim_outro ---

  def test_trim_outro_with_matching_words
    groq_words = [
      { word: "hello", start: 0.0, end: 0.5 },
      { word: "world", start: 0.6, end: 1.0 }
    ]
    path = trimmer.trim_outro(
      "/input.mp3",
      reconciled_text: "hello world",
      groq_words: groq_words,
      base_name: "ep-2026-01-15",
      tails_dir: @tmpdir
    )
    refute_equal "/input.mp3", path
    assert File.exist?(File.join(@tmpdir, "ep-2026-01-15_tail.mp3"))
  end

  def test_trim_outro_no_match_returns_original
    groq_words = [{ word: "different", start: 0.0, end: 0.5 }]
    path = trimmer.trim_outro(
      "/input.mp3",
      reconciled_text: "hello world",
      groq_words: groq_words,
      base_name: "ep",
      tails_dir: @tmpdir
    )
    assert_equal "/input.mp3", path
  end

  def test_trim_outro_small_savings_returns_original
    groq_words = [{ word: "word", start: 97.0, end: 98.0 }]
    path = trimmer.trim_outro(
      "/input.mp3",
      reconciled_text: "word",
      groq_words: groq_words,
      base_name: "ep",
      tails_dir: @tmpdir
    )
    assert_equal "/input.mp3", path
  end

  def test_trim_outro_tracks_temp_files
    # Mock probe_duration returns 100.0s; savings must exceed MIN_OUTRO_SAVINGS (5s).
    groq_words = [
      { word: "hello", start: 0.0,  end: 1.0  },
      { word: "world", start: 1.0,  end: 2.0  },
      { word: "the",   start: 89.0, end: 89.4 },
      { word: "end",   start: 89.4, end: 90.0 }
    ]
    trimmer.trim_outro(
      "/input.mp3",
      reconciled_text: "hello world the end",
      groq_words: groq_words,
      base_name: "ep",
      tails_dir: @tmpdir
    )
    assert_equal 1, trimmer.temp_files.length
  end

  # --- private helpers (via send) ---

  def test_normalize_word_strips_punctuation
    assert_equal "hello", trimmer.send(:normalize_word, "Hello!")
    assert_equal "world", trimmer.send(:normalize_word, "world,")
    assert_equal "noč", trimmer.send(:normalize_word, "noč.")
  end

  def test_normalize_word_downcases
    assert_equal "hello", trimmer.send(:normalize_word, "HELLO")
  end

  def test_word_match_exact
    assert trimmer.send(:word_match?, "hello", "hello")
  end

  def test_word_match_prefix
    assert trimmer.send(:word_match?, "san", "sanjam")
    assert trimmer.send(:word_match?, "sanja", "sanjam")
  end

  def test_word_match_short_prefix_rejected
    refute trimmer.send(:word_match?, "sa", "sanjam")
  end

  def test_word_match_no_match
    refute trimmer.send(:word_match?, "hello", "world")
  end

  def setup
    @tmpdir = Dir.mktmpdir("trimmer_test")
    @mock_assembler = MockAssembler.new
    @trimmer = nil
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  private

  def trimmer
    @trimmer ||= AudioTrimmer.new(assembler: @mock_assembler)
  end

  class MockAssembler
    attr_reader :snip_calls, :trim_calls

    def initialize(duration: 100.0)
      @duration = duration
      @snip_calls = []
      @trim_calls = []
    end

    def probe_duration(_path) = @duration

    def snip_segments(_input, output, keeps)
      @snip_calls << { keeps: keeps }
      FileUtils.touch(output)
    end

    def extract_segment(_input, output, _from, _to)
      FileUtils.touch(output)
    end

    def trim_to_duration(_input, output, duration)
      @trim_calls << { duration: duration }
      FileUtils.touch(output)
    end
  end

  # Mimics TimeValue with absolute? flag for cut tests
  class AbsoluteValue
    def initialize(value) = @value = value.to_f
    def to_f = @value
    def >(other) = @value > other
    def absolute? = true
  end
end
