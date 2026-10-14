# frozen_string_literal: true

require_relative "../test_helper"
require "transcription/engine_manager"

# Mock engine that returns configurable results
class MockTranscriptionEngine
  attr_reader :transcribe_called

  def initialize(result: nil, error: nil, delay: 0)
    @result = result
    @error = error
    @delay = delay
    @transcribe_called = false
  end

  def transcribe(_audio_path)
    @transcribe_called = true
    sleep(@delay) if @delay > 0
    raise @error if @error
    @result
  end
end

# Mock reconciler
class MockReconciler
  attr_reader :reconcile_called, :cleanup_called, :last_texts

  def initialize(reconcile_result: "reconciled text", cleanup_result: "cleaned text", reconcile_error: nil, cleanup_error: nil)
    @reconcile_result = reconcile_result
    @cleanup_result = cleanup_result
    @reconcile_error = reconcile_error
    @cleanup_error = cleanup_error
    @reconcile_called = false
    @cleanup_called = false
  end

  def reconcile(texts)
    @reconcile_called = true
    @last_texts = texts
    raise @reconcile_error if @reconcile_error
    @reconcile_result
  end

  def cleanup(text, captions: nil)
    @cleanup_called = true
    raise @cleanup_error if @cleanup_error
    @cleanup_result
  end
end

class TestEngineManager < Minitest::Test
  def test_registry_has_all_engines
    assert_equal %w[open elab groq], Transcription::EngineManager::REGISTRY.keys
  end

  def test_single_engine_returns_text_and_cleaned
    result = { text: "hello world", segments: [], speech_start: 0.0, speech_end: 5.0 }
    mock_engine = MockTranscriptionEngine.new(result: result)
    mock_reconciler = MockReconciler.new(cleanup_result: "cleaned hello")

    manager = build_manager(["open"])
    stub_engine(manager, "open", mock_engine)
    stub_reconciler(manager, mock_reconciler)

    output = manager.transcribe("/fake.mp3")
    assert_equal "hello world", output[:text]
    assert_equal "cleaned hello", output[:cleaned]
    assert mock_reconciler.cleanup_called
  end

  def test_single_engine_cleanup_failure_is_non_fatal
    result = { text: "hello", segments: [], speech_start: 0.0, speech_end: 5.0 }
    mock_engine = MockTranscriptionEngine.new(result: result)
    mock_reconciler = MockReconciler.new(cleanup_error: RuntimeError.new("API down"))

    manager = build_manager(["open"])
    stub_engine(manager, "open", mock_engine)
    stub_reconciler(manager, mock_reconciler)

    output = manager.transcribe("/fake.mp3")
    assert_equal "hello", output[:text]
    assert_nil output[:cleaned]
  end

  def test_comparison_mode_runs_all_engines
    open_result = { text: "open text", segments: [] }
    groq_result = { text: "groq text", segments: [], words: [{ word: "groq", start: 0, end: 1 }] }
    mock_open = MockTranscriptionEngine.new(result: open_result)
    mock_groq = MockTranscriptionEngine.new(result: groq_result)
    mock_reconciler = MockReconciler.new(reconcile_result: "merged text")

    manager = build_manager(%w[open groq])
    stub_engine(manager, "open", mock_open)
    stub_engine(manager, "groq", mock_groq)
    stub_reconciler(manager, mock_reconciler)

    output = manager.transcribe("/fake.mp3")

    assert_equal open_result, output[:primary], "Primary should be first engine"
    assert_equal 2, output[:all].size
    assert_equal "merged text", output[:reconciled]
    assert_empty output[:errors]
    assert mock_reconciler.reconcile_called
  end

  def test_comparison_mode_falls_back_when_primary_fails
    groq_result = { text: "groq text", segments: [] }
    mock_open = MockTranscriptionEngine.new(error: RuntimeError.new("API error"))
    mock_groq = MockTranscriptionEngine.new(result: groq_result)
    mock_reconciler = MockReconciler.new

    manager = build_manager(%w[open groq])
    stub_engine(manager, "open", mock_open)
    stub_engine(manager, "groq", mock_groq)
    stub_reconciler(manager, mock_reconciler)

    output = manager.transcribe("/fake.mp3")
    assert_equal groq_result, output[:primary]
    assert_includes output[:errors], "open"
  end

  def test_comparison_mode_raises_when_all_fail
    mock_open = MockTranscriptionEngine.new(error: RuntimeError.new("fail 1"))
    mock_groq = MockTranscriptionEngine.new(error: RuntimeError.new("fail 2"))

    manager = build_manager(%w[open groq])
    stub_engine(manager, "open", mock_open)
    stub_engine(manager, "groq", mock_groq)

    err = assert_raises(RuntimeError) { manager.transcribe("/fake.mp3") }
    assert_match(/All engines failed/, err.message)
    assert_includes err.message, "fail 1"
    assert_includes err.message, "fail 2"
  end

  def test_comparison_mode_keys_results_and_errors_per_engine_under_concurrency
    results = %w[open elab groq].each_with_index.to_h { |c, i| [c, { text: "#{c} text", segments: [], i: i }] }
    manager = build_manager(%w[open elab groq])
    # Finish in reverse of configured order; elab fails.
    stub_engine(manager, "open", MockTranscriptionEngine.new(result: results["open"], delay: 0.06))
    stub_engine(manager, "elab", MockTranscriptionEngine.new(error: RuntimeError.new("elab down"), delay: 0.03))
    stub_engine(manager, "groq", MockTranscriptionEngine.new(result: results["groq"]))
    stub_reconciler(manager, MockReconciler.new)

    output = manager.transcribe("/fake.mp3")

    assert_equal results["open"], output[:primary], "Primary is the first configured engine, not the first to finish"
    assert_equal %w[groq open], output[:all].keys.sort
    assert_equal results["groq"], output[:all]["groq"]
    assert_equal({ "elab" => "elab down" }, output[:errors])
  end

  def test_comparison_mode_includes_captions_in_reconciliation
    open_result = { text: "open text", segments: [] }
    groq_result = { text: "groq text", segments: [] }
    mock_open = MockTranscriptionEngine.new(result: open_result)
    mock_groq = MockTranscriptionEngine.new(result: groq_result)
    mock_reconciler = MockReconciler.new(reconcile_result: "merged")

    manager = build_manager(%w[open groq])
    stub_engine(manager, "open", mock_open)
    stub_engine(manager, "groq", mock_groq)
    stub_reconciler(manager, mock_reconciler)

    manager.transcribe("/fake.mp3", captions: "caption text")

    assert_equal({ "open" => "open text", "groq" => "groq text", "captions" => "caption text" },
                 mock_reconciler.last_texts)
  end

  def test_comparison_mode_reconciliation_failure_is_non_fatal
    open_result = { text: "open text", segments: [] }
    groq_result = { text: "groq text", segments: [] }
    mock_open = MockTranscriptionEngine.new(result: open_result)
    mock_groq = MockTranscriptionEngine.new(result: groq_result)
    mock_reconciler = MockReconciler.new(reconcile_error: RuntimeError.new("boom"))

    manager = build_manager(%w[open groq])
    stub_engine(manager, "open", mock_open)
    stub_engine(manager, "groq", mock_groq)
    stub_reconciler(manager, mock_reconciler)

    output = manager.transcribe("/fake.mp3")
    assert_nil output[:reconciled]
    assert_equal 2, output[:all].size
  end

  def test_unknown_engine_raises
    manager = build_manager(["unknown"])

    assert_raises(RuntimeError) { manager.transcribe("/fake.mp3") }
  end

  def test_single_engine_passes_captions_to_cleanup
    result = { text: "hello", segments: [] }
    mock_engine = MockTranscriptionEngine.new(result: result)
    cleanup_called_with_captions = nil

    mock_reconciler = Object.new
    mock_reconciler.define_singleton_method(:cleanup) do |text, captions: nil|
      cleanup_called_with_captions = captions
      "cleaned"
    end

    manager = build_manager(["open"])
    stub_engine(manager, "open", mock_engine)
    stub_reconciler(manager, mock_reconciler)

    manager.transcribe("/fake.mp3", captions: "some captions")
    assert_equal "some captions", cleanup_called_with_captions
  end

  private

  def build_manager(codes, language: "sl")
    Transcription::EngineManager.new(engine_codes: codes, language: language)
  end

  def stub_engine(manager, code, mock_engine)
    @engine_stubs ||= {}
    @engine_stubs[code] = mock_engine
    stubs = @engine_stubs
    # One singleton build_engine serves every stubbed code (they share the
    # hash); redefining it per code only triggered a redefinition warning.
    return if manager.singleton_methods.include?(:build_engine)

    manager.define_singleton_method(:build_engine) do |c|
      stubs[c] || raise("Unknown engine: #{c}")
    end
  end

  def stub_reconciler(manager, mock_reconciler)
    manager.define_singleton_method(:build_reconciler) { mock_reconciler }
  end
end
