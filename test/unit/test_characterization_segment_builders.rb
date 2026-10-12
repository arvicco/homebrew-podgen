# frozen_string_literal: true

require_relative "../test_helper"
require "timestamp_persister"
require "transcription/elevenlabs_engine"

ENV["ELEVENLABS_API_KEY"] ||= "test-key"

# P3-0 H3 characterization harness — duplicated path 4.
#
# Word-to-segment aggregation exists twice:
#   TimestampPersister.build_segments_from_words  (TP)
#   Transcription::ElevenlabsEngine#build_segments_from_words  (ELAB, private)
# Every row of the shared table is run through BOTH implementations and each
# output is pinned. Rows where the two differ pin both outputs explicitly in
# the DIVERGENT section, so a consolidation has to pick one visibly.
# These tests pin CURRENT behavior, quirks included; they are not a spec.
#
# P4-3 consolidated both into TimestampPersister (ELAB delegates). Flipped
# pins are marked "P4-3"; only D1 (ELAB quality fields) remains divergent.
class TestCharacterizationSegmentBuilders < Minitest::Test
  ELAB_DEFAULTS = {no_speech_prob: 0.0, compression_ratio: 0.0, avg_logprob: 0.0}.freeze

  def w(text, start, finish) = {"word" => text, "start" => start, "end" => finish}

  # Shared rows: string keys with "word" (the one shape both read).
  # Each row: words => segments as TP returns them. ELAB returns the same
  # segments with ELAB_DEFAULTS merged in (pinned by the loop below).
  def shared_rows
    {
      normal_sentence: [
        [w("The", 0.0, 0.2), w("cat", 0.3, 0.5), w("sat.", 0.6, 1.0)],
        [{start: 0.0, end: 1.0, text: "The cat sat."}]
      ],
      punctuation_boundaries: [
        [w("Stop!", 0.0, 0.4), w("Why?", 0.5, 0.9), w("Because.", 1.0, 1.6), w("Then", 1.7, 2.0)],
        [
          {start: 0.0, end: 0.4, text: "Stop!"},
          {start: 0.5, end: 0.9, text: "Why?"},
          {start: 1.0, end: 1.6, text: "Because."},
          {start: 1.7, end: 2.0, text: "Then"}
        ]
      ],
      # Comma, semicolon, colon never split.
      non_terminal_punctuation_does_not_split: [
        [w("One,", 0.0, 0.3), w("two;", 0.4, 0.6), w("three:", 0.7, 0.9), w("four.", 1.0, 1.2)],
        [{start: 0.0, end: 1.2, text: "One, two; three: four."}]
      ],
      # Abbreviations and ellipses split like any terminal period.
      abbreviation_splits: [
        [w("Dr.", 0.0, 0.3), w("Smith", 0.4, 0.8), w("wait...", 0.9, 1.4), w("ok", 1.5, 1.7)],
        [
          {start: 0.0, end: 0.3, text: "Dr."},
          {start: 0.4, end: 1.4, text: "Smith wait..."},
          {start: 1.5, end: 1.7, text: "ok"}
        ]
      ],
      # Terminal punctuation followed by a closing quote/paren does NOT split.
      closing_quote_after_period_does_not_split: [
        [w("He", 0.0, 0.2), w("said", 0.3, 0.5), w("\"hi.\"", 0.6, 0.9), w("(really.)", 1.0, 1.4)],
        [{start: 0.0, end: 1.4, text: "He said \"hi.\" (really.)"}]
      ],
      # Decimal points mid-word do not split; the regex anchors at end.
      decimal_mid_word_does_not_split: [
        [w("Version", 0.0, 0.4), w("3.5", 0.5, 0.8), w("ships", 0.9, 1.2)],
        [{start: 0.0, end: 1.2, text: "Version 3.5 ships"}]
      ],
      # Trailing whitespace after the terminator still splits; strip trims it.
      trailing_whitespace_after_terminator_splits: [
        [w("End. ", 0.0, 0.5), w("Next.", 0.6, 1.0)],
        [{start: 0.0, end: 0.5, text: "End."}, {start: 0.6, end: 1.0, text: "Next."}]
      ],
      # P4-3: the terminator is anchored with \z, so "a.\nb" is not terminated.
      embedded_newline_after_period_does_not_split: [
        [w("a.\nb", 0.0, 1.0), w("c", 1.0, 2.0)],
        [{start: 0.0, end: 2.0, text: "a.\nb c"}]
      ],
      # No length cap: a long unpunctuated run becomes one segment.
      long_run_without_punctuation: [
        (0...60).map { |i| w("w#{i}", i * 0.5, i * 0.5 + 0.4) },
        [{start: 0.0, end: 29.9, text: (0...60).map { |i| "w#{i}" }.join(" ")}]
      ],
      # No pause-based splitting: a 30 s gap stays inside one segment.
      long_pause_does_not_split: [
        [w("Before", 0.0, 0.5), w("after.", 30.5, 31.0)],
        [{start: 0.0, end: 31.0, text: "Before after."}]
      ],
      single_word_terminated: [
        [w("Hi.", 0.2, 0.5)],
        [{start: 0.2, end: 0.5, text: "Hi."}]
      ],
      single_word_unterminated: [
        [w("Hi", 0.2, 0.5)],
        [{start: 0.2, end: 0.5, text: "Hi"}]
      ],
      empty_list: [[], []],
      # nil timings coerce to 0.0 via to_f; a missing "end" key too.
      nil_timings: [
        [{"word" => "A", "start" => nil, "end" => nil}, {"word" => "b.", "start" => 1.0}],
        [{start: 0.0, end: 0.0, text: "A b."}]
      ],
      # A 0.0 start is kept (0.0 is truthy for ||=); start is the first word's.
      zero_timings: [
        [w("Zero", 0.0, 0.0), w("time.", 0.0, 0.0)],
        [{start: 0.0, end: 0.0, text: "Zero time."}]
      ],
      # P4-3: timing strings coerce through Float() ("abc" -> 0.0) and the
      # segment end is clamped to be >= its start.
      string_timings_coerced_end_clamped: [
        [{"word" => "x.", "start" => "1.5", "end" => "abc"}],
        [{start: 1.5, end: 1.5, text: "x."}]
      ],
      # nil word text becomes "" and still joins with a space.
      nil_word_text: [
        [w(nil, 0.0, 0.2), w("ok.", 0.3, 0.5)],
        [{start: 0.0, end: 0.5, text: "ok."}]
      ],
      empty_word_text_in_middle_doubles_space: [
        [w("a", 0.0, 0.1), w("", 0.1, 0.2), w("b.", 0.2, 0.3)],
        [{start: 0.0, end: 0.3, text: "a  b."}]
      ],
      non_latin_cyrillic: [
        [w("Привет", 0.0, 0.5), w("мир.", 0.6, 1.0), w("Как", 1.1, 1.3), w("дела?", 1.4, 1.8)],
        [{start: 0.0, end: 1.0, text: "Привет мир."}, {start: 1.1, end: 1.8, text: "Как дела?"}]
      ],
      # P4-3: CJK full-width terminators (。？！) split like ASCII ones.
      non_latin_cjk_fullwidth_terminators_split: [
        [w("こんにちは。", 0.0, 1.0), w("元気？", 1.0, 2.0), w("はい！", 2.0, 2.5)],
        [
          {start: 0.0, end: 1.0, text: "こんにちは。"},
          {start: 1.0, end: 2.0, text: "元気？"},
          {start: 2.0, end: 2.5, text: "はい！"}
        ]
      ],
      # ASCII terminator after CJK text does split.
      non_latin_cjk_ascii_terminator_splits: [
        [w("ビットコイン.", 0.0, 1.0), w("次", 1.0, 1.5)],
        [{start: 0.0, end: 1.0, text: "ビットコイン."}, {start: 1.0, end: 1.5, text: "次"}]
      ],
      # Words are joined with a space even when the language does not use them.
      # Language-aware joining is deferred (P4-3).
      non_latin_cjk_words_joined_with_space: [
        [w("日本", 0.0, 0.5), w("語", 0.5, 0.8)],
        [{start: 0.0, end: 0.8, text: "日本 語"}]
      ]
    }
  end

  def elab
    @elab ||= Transcription::ElevenlabsEngine.new(language: "sl")
  end

  def tp_build(words) = TimestampPersister.build_segments_from_words(words)

  def elab_build(words) = elab.send(:build_segments_from_words, words)

  # --- shared table: both implementations agree on segment content ---

  def test_build_segments_from_words_shared_table_timestamp_persister_matches_pins
    shared_rows.each do |name, (words, expected)|
      assert_equal expected, tp_build(words), "TP row #{name}"
    end
  end

  def test_build_segments_from_words_shared_table_elevenlabs_matches_pins
    shared_rows.each do |name, (words, expected)|
      assert_equal expected.map { |s| s.merge(ELAB_DEFAULTS) }, elab_build(words), "ELAB row #{name}"
    end
  end

  def test_build_segments_from_words_shared_table_does_not_mutate_input
    shared_rows.each do |name, (words, _)|
      snapshot = Marshal.load(Marshal.dump(words))
      tp_build(words)
      elab_build(words)
      assert_equal snapshot, words, "input mutated in row #{name}"
    end
  end

  # --- DIVERGENT: the two implementations differ; both outputs pinned ---

  # D1: output shape. ELAB adds three whisper-style quality fields; TP does not.
  def test_build_segments_from_words_output_keys_divergent_between_implementations
    words = [w("Hi.", 0.0, 0.5)]

    assert_equal [{start: 0.0, end: 0.5, text: "Hi."}], tp_build(words)
    assert_equal [{start: 0.0, end: 0.5, text: "Hi.", no_speech_prob: 0.0, compression_ratio: 0.0, avg_logprob: 0.0}],
      elab_build(words)
  end

  # D2 (P4-3, converged): ElevenLabs-native "text" key is read by both.
  def test_build_segments_from_words_text_key_converged_between_implementations
    words = [{"text" => "Hi", "start" => 0.0, "end" => 0.2}, {"text" => "there.", "start" => 0.3, "end" => 0.6}]

    assert_equal [{start: 0.0, end: 0.6, text: "Hi there."}], tp_build(words)
    assert_equal [{start: 0.0, end: 0.6, text: "Hi there."}.merge(ELAB_DEFAULTS)], elab_build(words)
  end

  # D2b (P4-3, converged): with "text" keys both split per sentence.
  def test_build_segments_from_words_text_key_multi_sentence_converged_between_implementations
    words = [{"text" => "A.", "start" => 0.0, "end" => 0.5}, {"text" => "B.", "start" => 0.6, "end" => 1.0}]
    expected = [{start: 0.0, end: 0.5, text: "A."}, {start: 0.6, end: 1.0, text: "B."}]

    assert_equal expected, tp_build(words)
    assert_equal expected.map { |s| s.merge(ELAB_DEFAULTS) }, elab_build(words)
  end

  # D2c (P4-3, converged): when both "text" and "word" are present, "word" wins.
  def test_build_segments_from_words_text_and_word_keys_converged_between_implementations
    words = [{"text" => "fromtext.", "word" => "fromword.", "start" => 0.0, "end" => 0.5}]

    assert_equal [{start: 0.0, end: 0.5, text: "fromword."}], tp_build(words)
    assert_equal [{start: 0.0, end: 0.5, text: "fromword."}.merge(ELAB_DEFAULTS)], elab_build(words)
  end

  # D3 (P4-3, converged): symbol keys are read by both.
  def test_build_segments_from_words_symbol_keys_converged_between_implementations
    words = [{word: "Hi.", start: 1.0, end: 1.5}, {word: "Bye", start: 2.0, end: 2.5}]
    expected = [{start: 1.0, end: 1.5, text: "Hi."}, {start: 2.0, end: 2.5, text: "Bye"}]

    assert_equal expected, tp_build(words)
    assert_equal expected.map { |s| s.merge(ELAB_DEFAULTS) }, elab_build(words)
  end

  # D4 (P4-3, converged): Scribe "spacing" tokens are skipped by both.
  def test_build_segments_from_words_spacing_tokens_converged_between_implementations
    words = [
      {"text" => "Hi", "start" => 0.0, "end" => 0.2, "type" => "word"},
      {"text" => " ", "start" => 0.2, "end" => 0.3, "type" => "spacing"},
      {"text" => "there.", "start" => 0.3, "end" => 0.6, "type" => "word"}
    ]

    assert_equal [{start: 0.0, end: 0.6, text: "Hi there."}], tp_build(words)
    assert_equal [{start: 0.0, end: 0.6, text: "Hi there."}.merge(ELAB_DEFAULTS)], elab_build(words)
  end

  # D5 (P4-3, converged): mixed key styles inside one list are read per word.
  def test_build_segments_from_words_mixed_key_styles_converged_between_implementations
    words = [{word: "One", start: 0.0, end: 0.3}, {"word" => "two.", "start" => 0.4, "end" => 0.8}]

    assert_equal [{start: 0.0, end: 0.8, text: "One two."}], tp_build(words)
    assert_equal [{start: 0.0, end: 0.8, text: "One two."}.merge(ELAB_DEFAULTS)], elab_build(words)
  end
end
