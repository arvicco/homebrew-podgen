# frozen_string_literal: true

require_relative "../test_helper"
require "timestamp_persister"

class TestTimestampPersister < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_timestamp_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- persist ---

  def test_persist_writes_json_file
    output_path = File.join(@tmpdir, "ep-2026-03-01_timestamps.json")
    segments = [
      { start: 0.0, end: 4.2, text: "First sentence." },
      { start: 4.2, end: 9.1, text: "Second sentence." }
    ]

    TimestampPersister.persist(segments: segments, engine: "groq", intro_duration: 0.0, output_path: output_path)

    assert File.exist?(output_path)
    data = JSON.parse(File.read(output_path))
    assert_equal 1, data["version"]
    assert_equal "groq", data["engine"]
    assert_in_delta 0.0, data["intro_duration"]
    assert_equal 2, data["segments"].length
    assert_equal "First sentence.", data["segments"][0]["text"]
  end

  def test_persist_adjusts_timestamps_by_intro_duration
    output_path = File.join(@tmpdir, "ep_timestamps.json")
    segments = [
      { start: 0.0, end: 4.2, text: "Hello." },
      { start: 4.2, end: 9.1, text: "World." }
    ]

    TimestampPersister.persist(segments: segments, engine: "groq", intro_duration: 3.5, output_path: output_path)

    data = JSON.parse(File.read(output_path))
    assert_in_delta 3.5, data["segments"][0]["start"]
    assert_in_delta 7.7, data["segments"][0]["end"]
    assert_in_delta 7.7, data["segments"][1]["start"]
    assert_in_delta 12.6, data["segments"][1]["end"]
  end

  def test_persist_clamps_segments_past_audio_duration
    output_path = File.join(@tmpdir, "ep_timestamps.json")
    segments = [
      { start: 0.0, end: 5.0, text: "Kept." },
      { start: 5.0, end: 10.0, text: "Straddling." },
      { start: 10.0, end: 15.0, text: "Past end." }
    ]

    TimestampPersister.persist(segments: segments, engine: "groq", intro_duration: 0.0,
      output_path: output_path, audio_duration: 8.0)

    data = JSON.parse(File.read(output_path))
    assert_equal 2, data["segments"].length
    assert_equal "Kept.", data["segments"][0]["text"]
    assert_equal "Straddling.", data["segments"][1]["text"]
    assert_in_delta 8.0, data["segments"][1]["end"]
  end

  def test_persist_drops_segments_entirely_past_duration
    output_path = File.join(@tmpdir, "ep_timestamps.json")
    segments = [
      { start: 0.0, end: 3.0, text: "Only this." },
      { start: 10.0, end: 15.0, text: "Way past." }
    ]

    TimestampPersister.persist(segments: segments, engine: "groq", intro_duration: 0.0,
      output_path: output_path, audio_duration: 5.0)

    data = JSON.parse(File.read(output_path))
    assert_equal 1, data["segments"].length
  end

  def test_persist_no_clamping_without_audio_duration
    output_path = File.join(@tmpdir, "ep_timestamps.json")
    segments = [
      { start: 0.0, end: 100.0, text: "Long." }
    ]

    TimestampPersister.persist(segments: segments, engine: "groq", intro_duration: 0.0, output_path: output_path)

    data = JSON.parse(File.read(output_path))
    assert_equal 1, data["segments"].length
  end

  def test_persist_empty_segments
    output_path = File.join(@tmpdir, "ep_timestamps.json")

    TimestampPersister.persist(segments: [], engine: "open", intro_duration: 0.0, output_path: output_path)

    data = JSON.parse(File.read(output_path))
    assert_equal 0, data["segments"].length
  end

  def test_persist_handles_string_keys_in_segments
    output_path = File.join(@tmpdir, "ep_timestamps.json")
    segments = [
      { "start" => 1.0, "end" => 2.0, "text" => "String keys." }
    ]

    TimestampPersister.persist(segments: segments, engine: "elab", intro_duration: 0.0, output_path: output_path)

    data = JSON.parse(File.read(output_path))
    assert_equal "String keys.", data["segments"][0]["text"]
    assert_in_delta 1.0, data["segments"][0]["start"]
  end

  # --- load ---

  def test_load_reads_back_persisted_data
    output_path = File.join(@tmpdir, "ep_timestamps.json")
    segments = [{ start: 0.0, end: 5.0, text: "Hello." }]
    TimestampPersister.persist(segments: segments, engine: "groq", intro_duration: 2.0, output_path: output_path)

    data = TimestampPersister.load(output_path)
    assert_equal 1, data["version"]
    assert_equal "groq", data["engine"]
    assert_in_delta 2.0, data["intro_duration"]
    assert_equal 1, data["segments"].length
  end

  # P1-4 (Q-05): a truncated/corrupt sidecar must surface as a named error, not a raw ParserError
  def test_load_raises_corrupt_sidecar_error_for_truncated_json
    path = File.join(@tmpdir, "ep_timestamps.json")
    File.write(path, '{"segments": [{"start": 0.0, "end": 1.0, "te')

    err = assert_raises(TimestampPersister::CorruptSidecarError) { TimestampPersister.load(path) }
    assert_includes err.message, path
  end

  def test_load_returns_nil_for_missing_file
    assert_nil TimestampPersister.load(File.join(@tmpdir, "nonexistent.json"))
  end

  # --- update_segments ---

  def test_update_segments_replaces_text_and_sets_reconciled
    path = File.join(@tmpdir, "ep_timestamps.json")
    TimestampPersister.persist(segments: [{ start: 0.0, end: 5.0, text: "Raw garbled." }],
      engine: "groq", intro_duration: 0.0, output_path: path)

    new_segments = [{ "start" => 0.0, "end" => 5.0, "text" => "Clean correct." }]
    TimestampPersister.update_segments(path, new_segments)

    data = JSON.parse(File.read(path))
    assert_equal "Clean correct.", data["segments"][0]["text"]
    assert_equal true, data["reconciled"]
    assert_equal "groq", data["engine"] # preserved
  end

  def test_update_segments_preserves_metadata
    path = File.join(@tmpdir, "ep_timestamps.json")
    TimestampPersister.persist(segments: [{ start: 0.0, end: 5.0, text: "Old." }],
      engine: "elab", intro_duration: 3.5, output_path: path)

    TimestampPersister.update_segments(path, [{ "start" => 3.5, "end" => 8.5, "text" => "New." }])

    data = JSON.parse(File.read(path))
    assert_equal 1, data["version"]
    assert_equal "elab", data["engine"]
    assert_in_delta 3.5, data["intro_duration"]
  end

  def test_load_returns_reconciled_flag
    path = File.join(@tmpdir, "ep_timestamps.json")
    TimestampPersister.persist(segments: [{ start: 0.0, end: 5.0, text: "Raw." }],
      engine: "groq", intro_duration: 0.0, output_path: path)

    data = TimestampPersister.load(path)
    refute data["reconciled"]

    TimestampPersister.update_segments(path, [{ "start" => 0.0, "end" => 5.0, "text" => "Clean." }])
    data = TimestampPersister.load(path)
    assert data["reconciled"]
  end

  # --- extract_segments ---

  def test_extract_segments_single_engine_with_segments
    result = { segments: [{ start: 0.0, end: 5.0, text: "Hello." }] }
    engine_codes = ["groq"]

    segments, engine = TimestampPersister.extract_segments(result, engine_codes: engine_codes)

    assert_equal 1, segments.length
    assert_equal "groq", engine
  end

  def test_extract_segments_comparison_mode_prefers_groq
    result = {
      segments: [{ start: 0.0, end: 5.0, text: "Primary." }]
    }
    comparison_results = {
      "groq" => { segments: [{ start: 0.0, end: 5.0, text: "Groq." }] },
      "open" => { segments: [{ start: 0.0, end: 5.0, text: "OpenAI." }] }
    }
    engine_codes = ["open", "groq"]

    segments, engine = TimestampPersister.extract_segments(result, engine_codes: engine_codes,
      comparison_results: comparison_results)

    assert_equal "Groq.", segments[0][:text]
    assert_equal "groq", engine
  end

  def test_extract_segments_comparison_mode_falls_back_to_elab
    comparison_results = {
      "elab" => { segments: [{ start: 0.0, end: 5.0, text: "ElevenLabs." }] },
      "open" => { segments: [{ start: 0.0, end: 5.0, text: "OpenAI." }] }
    }
    engine_codes = ["open", "elab"]

    segments, engine = TimestampPersister.extract_segments({}, engine_codes: engine_codes,
      comparison_results: comparison_results)

    assert_equal "ElevenLabs.", segments[0][:text]
    assert_equal "elab", engine
  end

  def test_extract_segments_returns_nil_when_no_segments
    result = { text: "No segments here" }
    segments, engine = TimestampPersister.extract_segments(result, engine_codes: ["open"])

    assert_nil segments
    assert_nil engine
  end

  # --- build_segments_from_words fallback ---

  def test_extract_segments_builds_from_words_when_no_segments
    result = {
      segments: [],
      words: [
        { word: "Hello", start: 0.0, end: 0.5 },
        { word: "world.", start: 0.5, end: 1.0 },
        { word: "Second", start: 1.5, end: 2.0 },
        { word: "sentence.", start: 2.0, end: 2.5 }
      ]
    }

    segments, engine = TimestampPersister.extract_segments(result, engine_codes: ["groq"])

    assert_equal 2, segments.length
    assert_equal "Hello world.", segments[0][:text]
    assert_in_delta 0.0, segments[0][:start]
    assert_in_delta 1.0, segments[0][:end]
    assert_equal "Second sentence.", segments[1][:text]
    assert_equal "groq", engine
  end

  def test_extract_segments_builds_from_words_comparison_mode
    comparison_results = {
      "groq" => {
        segments: [],
        words: [
          { word: "Ciao.", start: 0.0, end: 0.5 },
          { word: "Mondo.", start: 0.5, end: 1.0 }
        ]
      }
    }

    segments, engine = TimestampPersister.extract_segments({}, engine_codes: ["groq"],
      comparison_results: comparison_results)

    assert_equal 2, segments.length
    assert_equal "groq", engine
  end

  def test_build_segments_from_words_flushes_trailing_words
    words = [
      { word: "No", start: 0.0, end: 0.3 },
      { word: "punctuation", start: 0.3, end: 0.8 }
    ]

    segments = TimestampPersister.build_segments_from_words(words)

    assert_equal 1, segments.length
    assert_equal "No punctuation", segments[0][:text]
    assert_in_delta 0.8, segments[0][:end]
  end

  def test_build_segments_from_words_handles_string_keys
    words = [
      { "word" => "Hello.", "start" => 0.0, "end" => 0.5 }
    ]

    segments = TimestampPersister.build_segments_from_words(words)

    assert_equal 1, segments.length
    assert_equal "Hello.", segments[0][:text]
  end

  # --- P4-3: the one canonical word-to-segment builder ---

  def test_build_segments_from_words_text_key_read_when_word_key_absent
    words = [{ "text" => "Hi", "start" => 0.0, "end" => 0.2 }, { "text" => "there.", "start" => 0.3, "end" => 0.6 }]

    assert_equal [{ start: 0.0, end: 0.6, text: "Hi there." }], TimestampPersister.build_segments_from_words(words)
  end

  def test_build_segments_from_words_word_key_preferred_over_text_key
    words = [{ "text" => "fromtext.", "word" => "fromword.", "start" => 0.0, "end" => 0.5 }]

    assert_equal "fromword.", TimestampPersister.build_segments_from_words(words).first[:text]
  end

  def test_build_segments_from_words_symbol_text_key_read
    words = [{ text: "One", start: 0.0, end: 0.3 }, { text: "two.", start: 0.4, end: 0.8 }]

    assert_equal [{ start: 0.0, end: 0.8, text: "One two." }], TimestampPersister.build_segments_from_words(words)
  end

  def test_build_segments_from_words_spacing_tokens_skipped
    words = [
      { "text" => "Hi", "start" => 0.0, "end" => 0.2, "type" => "word" },
      { "text" => " ", "start" => 0.2, "end" => 0.3, "type" => "spacing" },
      { text: "there.", start: 0.3, end: 0.6, type: "word" },
      { text: "  ", start: 0.6, end: 0.9, type: "spacing" }
    ]

    assert_equal [{ start: 0.0, end: 0.6, text: "Hi there." }], TimestampPersister.build_segments_from_words(words)
  end

  def test_build_segments_from_words_only_spacing_tokens_yields_no_segments
    words = [{ "text" => " ", "start" => 0.0, "end" => 0.1, "type" => "spacing" }]

    assert_equal [], TimestampPersister.build_segments_from_words(words)
  end

  def test_build_segments_from_words_untyped_empty_token_kept
    words = [{ "word" => "a", "start" => 0.0, "end" => 0.1 }, { "word" => "", "start" => 0.1, "end" => 0.2 },
      { "word" => "b.", "start" => 0.2, "end" => 0.3 }]

    assert_equal "a  b.", TimestampPersister.build_segments_from_words(words).first[:text]
  end

  def test_build_segments_from_words_newline_inside_word_does_not_split
    words = [{ "word" => "a.\nb", "start" => 0.0, "end" => 1.0 }, { "word" => "c", "start" => 1.0, "end" => 2.0 }]

    assert_equal [{ start: 0.0, end: 2.0, text: "a.\nb c" }], TimestampPersister.build_segments_from_words(words)
  end

  def test_build_segments_from_words_cjk_fullwidth_terminators_split
    words = [{ "word" => "こんにちは。", "start" => 0.0, "end" => 1.0 }, { "word" => "元気？", "start" => 1.0, "end" => 2.0 },
      { "word" => "はい！", "start" => 2.0, "end" => 2.5 }, { "word" => "次", "start" => 2.5, "end" => 3.0 }]

    assert_equal ["こんにちは。", "元気？", "はい！", "次"], TimestampPersister.build_segments_from_words(words).map { |s| s[:text] }
  end

  def test_build_segments_from_words_unparseable_end_clamped_to_start
    words = [{ "word" => "x.", "start" => "1.5", "end" => "abc" }]

    assert_equal [{ start: 1.5, end: 1.5, text: "x." }], TimestampPersister.build_segments_from_words(words)
  end

  def test_build_segments_from_words_end_before_start_clamped_on_flush
    words = [{ "word" => "late", "start" => 4.0, "end" => 4.5 }, { "word" => "early", "start" => 1.0, "end" => 1.2 }]

    assert_equal [{ start: 4.0, end: 4.0, text: "late early" }], TimestampPersister.build_segments_from_words(words)
  end

  def test_build_segments_from_words_nil_timings_become_zero
    words = [{ "word" => "A.", "start" => nil, "end" => nil }]

    assert_equal [{ start: 0.0, end: 0.0, text: "A." }], TimestampPersister.build_segments_from_words(words)
  end
end
