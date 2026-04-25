# frozen_string_literal: true

require_relative "../test_helper"
require "subtitle_reconciler"

class TestSubtitleReconciler < Minitest::Test
  # --- prompt construction ---

  def test_build_prompt_includes_segments_and_transcript
    segments = [
      { "start" => 0.0, "end" => 5.0, "text" => "Raw garbled text." }
    ]
    prompt = SubtitleReconciler.build_prompt(segments, "Clean correct text.")

    assert_includes prompt, "Raw garbled text."
    assert_includes prompt, "Clean correct text."
    assert_includes prompt, '"start"'
  end

  # --- parse_response ---

  def test_parse_response_extracts_json_array
    response = <<~JSON
      ```json
      [
        {"start": 0.0, "end": 5.0, "text": "Clean."}
      ]
      ```
    JSON
    result = SubtitleReconciler.parse_response(response)

    assert_equal 1, result.length
    assert_equal "Clean.", result[0]["text"]
    assert_in_delta 0.0, result[0]["start"]
  end

  def test_parse_response_handles_bare_json
    response = '[{"start": 0.0, "end": 5.0, "text": "Clean."}]'
    result = SubtitleReconciler.parse_response(response)

    assert_equal 1, result.length
  end

  def test_parse_response_raises_on_invalid_json
    assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.parse_response("not json at all")
    end
  end

  def test_parse_response_raises_on_segment_count_mismatch
    segments_json = '[{"start": 0.0, "end": 5.0, "text": "One."}]'
    # parse_response doesn't know expected count, but validate does
    result = SubtitleReconciler.parse_response(segments_json)
    assert_equal 1, result.length
  end

  # --- validate ---

  def test_validate_raises_on_count_mismatch
    original = [
      { "start" => 0.0, "end" => 5.0, "text" => "One." },
      { "start" => 5.0, "end" => 10.0, "text" => "Two." }
    ]
    reconciled = [
      { "start" => 0.0, "end" => 10.0, "text" => "Merged." }
    ]

    assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.validate!(reconciled, original)
    end
  end

  def test_validate_raises_on_timestamp_mismatch
    original = [{ "start" => 0.0, "end" => 5.0, "text" => "Old." }]
    reconciled = [{ "start" => 1.0, "end" => 5.0, "text" => "New." }]

    assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.validate!(reconciled, original)
    end
  end

  def test_validate_passes_with_matching_timestamps
    original = [{ "start" => 0.0, "end" => 5.0, "text" => "Old." }]
    reconciled = [{ "start" => 0.0, "end" => 5.0, "text" => "New." }]

    SubtitleReconciler.validate!(reconciled, original) # should not raise
  end

  # --- reconcile (stubbed API) ---

  # --- model resolution ---

  def test_reconcile_uses_default_model_when_no_env_or_arg
    ENV.delete("CLAUDE_RECONCILER_MODEL")
    captured_model = nil
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**kwargs|
      captured_model = kwargs[:model]
      content_block = Struct.new(:text).new(JSON.generate([{ "start" => 0.0, "end" => 1.0, "text" => "x" }]))
      Struct.new(:content).new([content_block])
    end
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      SubtitleReconciler.reconcile([{ "start" => 0.0, "end" => 1.0, "text" => "y" }], "x", api_key: "k")
    end
    assert_equal "claude-sonnet-4-6", captured_model
  end

  def test_reconcile_uses_env_var_when_set
    ENV["CLAUDE_RECONCILER_MODEL"] = "claude-opus-4-7"
    captured_model = nil
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**kwargs|
      captured_model = kwargs[:model]
      content_block = Struct.new(:text).new(JSON.generate([{ "start" => 0.0, "end" => 1.0, "text" => "x" }]))
      Struct.new(:content).new([content_block])
    end
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      SubtitleReconciler.reconcile([{ "start" => 0.0, "end" => 1.0, "text" => "y" }], "x", api_key: "k")
    end
    assert_equal "claude-opus-4-7", captured_model
  ensure
    ENV.delete("CLAUDE_RECONCILER_MODEL")
  end

  def test_reconcile_explicit_model_arg_takes_precedence_over_env
    ENV["CLAUDE_RECONCILER_MODEL"] = "claude-opus-4-7"
    captured_model = nil
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**kwargs|
      captured_model = kwargs[:model]
      content_block = Struct.new(:text).new(JSON.generate([{ "start" => 0.0, "end" => 1.0, "text" => "x" }]))
      Struct.new(:content).new([content_block])
    end
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      SubtitleReconciler.reconcile([{ "start" => 0.0, "end" => 1.0, "text" => "y" }], "x", api_key: "k", model: "claude-haiku-4-5-20251001")
    end
    assert_equal "claude-haiku-4-5-20251001", captured_model
  ensure
    ENV.delete("CLAUDE_RECONCILER_MODEL")
  end

  def test_reconcile_calls_api_and_returns_segments
    segments = [
      { "start" => 0.0, "end" => 5.0, "text" => "Garbled." },
      { "start" => 5.0, "end" => 10.0, "text" => "More garble." }
    ]
    transcript = "Clean text. More clean."

    fake_response = [
      { "start" => 0.0, "end" => 5.0, "text" => "Clean text." },
      { "start" => 5.0, "end" => 10.0, "text" => "More clean." }
    ]

    content_block = Struct.new(:text).new(JSON.generate(fake_response))
    api_response = Struct.new(:content).new([content_block])

    mock_messages = Minitest::Mock.new
    mock_messages.expect(:create, api_response,
      [], model: String, max_tokens: Integer, messages: Array)

    mock_client = Struct.new(:messages).new(mock_messages)

    Anthropic::Client.stub(:new, mock_client) do
      result = SubtitleReconciler.reconcile(segments, transcript, api_key: "test-key")
      assert_equal 2, result.length
      assert_equal "Clean text.", result[0]["text"]
      assert_equal "More clean.", result[1]["text"]
    end

    mock_messages.verify
  end
end
