# frozen_string_literal: true

require_relative "../test_helper"
require "claude_models"
require "subtitle_reconciler"

class TestSubtitleReconciler < Minitest::Test
  FakeUsage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
  # An API message as the reconciler reads it: content, stop_reason, usage.
  FakeMsg = Struct.new(:content, :stop_reason, :usage) do
    def initialize(content, stop_reason = "end_turn", usage = FakeUsage.new(10, 5, 0, 0)) = super
  end

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

  # Regression: transcripts with quoted dialogue (e.g. Slovenian children's
  # stories: `"Morala bi jima reči šc," je zakrulil Gusti.`) caused Claude
  # to copy the literal `"` characters into JSON `text` values, breaking
  # the parser at the early-closed string. The prompt must explicitly
  # require escaping internal double-quotes.
  def test_build_prompt_instructs_to_escape_internal_quotes
    segments = [{ "start" => 0.0, "end" => 5.0, "text" => "x" }]
    transcript = %("Morala bi jima reči šc," je zakrulil Gusti.)
    prompt = SubtitleReconciler.build_prompt(segments, transcript)

    assert_match(/escape.*double[- ]quote|double[- ]quote.*escape/i, prompt,
      "Prompt must instruct Claude to escape internal double-quote characters in text values")
  end

  # The escape instruction must contain the LITERAL example characters
  # `\"` (backslash + quote) so Claude knows what to emit. A previous
  # version used `\"` in a double-quoted heredoc, which Ruby reduced to
  # just `"` — leaving Claude with a nonsensical "escape \" as \"" rule.
  def test_build_prompt_includes_literal_backslash_quote_example
    prompt = SubtitleReconciler.build_prompt([{ "start" => 0.0, "end" => 1.0, "text" => "x" }], "x")
    assert_includes prompt, '\\"',
      "Prompt must contain the literal characters backslash+quote so Claude has a concrete escape example"
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

  def test_validate_accepts_float_reserialization_drift
    original = [{ "start" => 7.7, "end" => 12.3, "text" => "Old." }]
    reconciled = [{ "start" => 7.7 + 1e-6, "end" => 12.3 - 1e-6, "text" => "New." }]

    SubtitleReconciler.validate!(reconciled, original) # should not raise
  end

  def test_validate_rejects_drift_beyond_epsilon
    original = [{ "start" => 7.7, "end" => 12.3, "text" => "Old." }]
    reconciled = [{ "start" => 7.75, "end" => 12.3, "text" => "New." }]

    assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.validate!(reconciled, original)
    end
  end

  def test_validate_count_mismatch_still_fails_with_matching_timestamps
    original = [{ "start" => 0.0, "end" => 5.0, "text" => "A." }, { "start" => 5.0, "end" => 6.0, "text" => "B." }]
    reconciled = [{ "start" => 0.0, "end" => 5.0, "text" => "A." }]

    err = assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.validate!(reconciled, original)
    end
    assert_match(/count mismatch/, err.message)
  end

  # P14-2 (Q-131): nothing null may reach *_timestamps.json
  def test_validate_missing_text_raises_reconciliation_error
    original = [{ "start" => 0.0, "end" => 5.0, "text" => "A." }]
    reconciled = [{ "start" => 0.0, "end" => 5.0 }]

    err = assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.validate!(reconciled, original)
    end
    assert_match(/text/, err.message)
  end

  def test_validate_null_text_raises_reconciliation_error
    original = [{ "start" => 0.0, "end" => 5.0, "text" => "A." }]
    reconciled = [{ "start" => 0.0, "end" => 5.0, "text" => nil }]

    assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.validate!(reconciled, original)
    end
  end

  # --- reconcile (stubbed API) ---

  # --- model resolution ---

  def test_reconcile_builds_the_client_with_the_bounded_request_timeout
    captured = nil
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**_|
      FakeMsg.new([Struct.new(:text).new(JSON.generate([{ "start" => 0.0, "end" => 1.0, "text" => "x" }]))])
    end
    fake_client = Struct.new(:messages).new(fake_messages)
    Anthropic::Client.stub(:new, ->(**kw) {
      captured = kw
      fake_client
    }) do
      SubtitleReconciler.reconcile([{ "start" => 0.0, "end" => 1.0, "text" => "y" }], "x", api_key: "k", model: "m")
    end
    assert_equal AnthropicClient::REQUEST_TIMEOUT, captured[:timeout]
  end

  def test_reconcile_uses_default_model_when_no_env_or_arg
    prev = ENV.delete("CLAUDE_RECONCILER_MODEL")
    captured_model = nil
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**kwargs|
      captured_model = kwargs[:model]
      content_block = Struct.new(:text).new(JSON.generate([{ "start" => 0.0, "end" => 1.0, "text" => "x" }]))
      FakeMsg.new([content_block])
    end
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      SubtitleReconciler.reconcile([{ "start" => 0.0, "end" => 1.0, "text" => "y" }], "x", api_key: "k")
    end
    assert_equal ClaudeModels.for(:subtitle_reconciler), captured_model
  ensure
    ENV["CLAUDE_RECONCILER_MODEL"] = prev if prev
  end

  def test_reconcile_uses_env_var_when_set
    ENV["CLAUDE_RECONCILER_MODEL"] = "claude-opus-4-7"
    captured_model = nil
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**kwargs|
      captured_model = kwargs[:model]
      content_block = Struct.new(:text).new(JSON.generate([{ "start" => 0.0, "end" => 1.0, "text" => "x" }]))
      FakeMsg.new([content_block])
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
      FakeMsg.new([content_block])
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
    api_response = FakeMsg.new([content_block])

    mock_messages = Minitest::Mock.new
    mock_messages.expect(:create, api_response,
      [], model: String, max_tokens: Integer, messages: Array, request_options: Hash)

    mock_client = Struct.new(:messages).new(mock_messages)

    Anthropic::Client.stub(:new, mock_client) do
      result = SubtitleReconciler.reconcile(segments, transcript, api_key: "test-key")
      assert_equal 2, result.length
      assert_equal "Clean text.", result[0]["text"]
      assert_equal "More clean.", result[1]["text"]
    end

    mock_messages.verify
  end

  # P4-1: the sidecar is a frozen schema — reconcile returns the ORIGINAL
  # start/end values (not the model's epsilon-drifted re-serialization) and
  # only the original segment's keys (model-invented keys are dropped).
  def test_reconcile_drift_within_epsilon_returns_original_timestamps
    segments = [{ "start" => 0.0, "end" => 7.7, "text" => "Garbled." }]
    reply = [{ "start" => 0.0, "end" => 7.700000001, "text" => "Clean." }]

    result = stub_reconcile_reply(reply) { SubtitleReconciler.reconcile(segments, "Clean.", api_key: "k", model: "m") }

    assert_equal 7.7, result.first["end"]
    assert_equal "Clean.", result.first["text"]
  end

  def test_reconcile_model_added_key_is_dropped
    segments = [{ "start" => 0.0, "end" => 5.0, "text" => "Garbled." }]
    reply = [{ "start" => 0.0, "end" => 5.0, "text" => "Clean.", "speaker" => "A" }]

    result = stub_reconcile_reply(reply) { SubtitleReconciler.reconcile(segments, "Clean.", api_key: "k", model: "m") }

    assert_equal %w[start end text], result.first.keys
  end

  # P8-2 (Q-66): reconciliation logs a usage line (ambient logger) like
  # every other Claude call site.
  def test_reconcile_logs_api_usage_line
    segments = [{ "start" => 0.0, "end" => 5.0, "text" => "Garbled." }]
    reply = [{ "start" => 0.0, "end" => 5.0, "text" => "Clean." }]
    msg = FakeMsg.new([Struct.new(:text).new(JSON.generate(reply))], "end_turn", FakeUsage.new(900, 300, 0, 0))
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**_| msg }
    lines = []
    logger = Object.new
    logger.define_singleton_method(:log) { |m| lines << m }

    PodcastAgent.with_logger(logger) do
      Anthropic::Client.stub(:new, Struct.new(:messages).new(fake_messages)) do
        SubtitleReconciler.reconcile(segments, "Clean.", api_key: "k", model: "m")
      end
    end

    log = lines.join("\n")
    assert_includes log, "[SubtitleReconciler] Subtitles reconciled in"
    assert_includes log, "(end_turn)"
    assert_includes log, "Input: 900 tokens | Output: 300 tokens"
  end

  # --- P17-2 (Q-156, I-12): cap sized from content, bounded retries ---

  # 65 segments of 93 Slovenian/Polish characters: the I-12 shape.
  def i12_segments
    text = ("Mačka je šla čez cesto, pogledala levo in desno ter rekla: žaba, čaj. " * 2)[0, 93]
    Array.new(65) { |i| {"start" => i * 2.0, "end" => i * 2.0 + 2.0, "text" => text} }
  end

  # Fake client answering a scripted list of [text, stop_reason]; records calls.
  class ScriptedClient
    attr_reader :calls

    def initialize(*replies)
      @replies = replies
      @calls = []
    end

    def messages = self

    def create(**kw)
      @calls << kw
      text, stop = @replies.fetch(@calls.length - 1)
      FakeMsg.new([Struct.new(:text).new(text)], stop)
    end
  end

  def run_scripted(segments, transcript, client)
    lines = []
    logger = Object.new
    logger.define_singleton_method(:log) { |m| lines << m }
    result = PodcastAgent.with_logger(logger) do
      Anthropic::Client.stub(:new, client) do
        SubtitleReconciler.reconcile(segments, transcript, api_key: "k", model: "m")
      end
    end
    [result, lines]
  end

  def reply_for(segments)
    JSON.generate(segments.each_with_index.map { |s, i| s.merge("text" => "Clean #{i}.") })
  end

  def test_reconcile_i12_segments_cap_covers_content_need
    segs = i12_segments
    transcript = segs.map { |s| s["text"] }.join(" ")
    client = ScriptedClient.new([reply_for(segs), "end_turn"])

    run_scripted(segs, transcript, client)

    chars = segs.sum { |s| s["text"].length } + transcript.length
    need = segs.length * 40 + chars * 0.8
    cap = client.calls.first[:max_tokens]
    assert_operator cap, :>=, need, "cap must cover segments x 40 + chars x 0.8"
    assert_operator cap, :>, [4096, segs.length * 80].max, "the I-12 cap (segments x 80) was too small"
    assert_operator cap, :<=, SubtitleReconciler::MAX_TOKENS_CEILING
  end

  def test_token_cap_short_input_keeps_floor_and_huge_input_is_ceiled
    assert_equal 4096, SubtitleReconciler.token_cap([{"start" => 0, "end" => 1, "text" => "x"}], "x")
    huge = Array.new(2000) { |i| {"start" => i, "end" => i + 1, "text" => "ż" * 100} }
    assert_equal SubtitleReconciler::MAX_TOKENS_CEILING, SubtitleReconciler.token_cap(huge, "ż" * 200_000)
  end

  def test_reconcile_max_tokens_stop_retries_once_with_doubled_cap_without_parsing
    segs = i12_segments
    truncated = reply_for(segs)[0, 500] # cut mid-string: unparseable
    client = ScriptedClient.new([truncated, "max_tokens"], [reply_for(segs), "end_turn"])

    result, lines = run_scripted(segs, "t", client)

    assert_equal 2, client.calls.length
    first, second = client.calls.map { |c| c[:max_tokens] }
    assert_equal [first * 2, SubtitleReconciler::MAX_TOKENS_CEILING].min, second
    assert_operator second, :>, first
    assert_equal "Clean 0.", result.first["text"], "the truncated first body was never parsed"
    assert_equal 1, lines.count { |l| l.include?("Retrying") }, "one retry line"
    assert lines.any? { |l| l.include?("(max_tokens)") }, "the stop reason is still logged"
  end

  def test_reconcile_max_tokens_twice_raises_naming_cap_and_segment_count
    segs = i12_segments
    client = ScriptedClient.new(["[{", "max_tokens"], ["[{", "max_tokens"])

    err = assert_raises(SubtitleReconciler::ReconciliationError) { run_scripted(segs, "t", client) }

    assert_equal 2, client.calls.length
    assert_includes err.message, client.calls.last[:max_tokens].to_s
    assert_includes err.message, "65 segments"
  end

  def test_reconcile_count_mismatch_retries_once_naming_the_mismatch
    segs = i12_segments
    client = ScriptedClient.new([reply_for(segs.first(64)), "end_turn"], [reply_for(segs), "end_turn"])

    result, lines = run_scripted(segs, "t", client)

    assert_equal 2, client.calls.length
    assert_equal 65, result.length
    retry_prompt = client.calls.last[:messages].first[:content]
    assert_match(/expected 65, got 64/, retry_prompt)
    refute_match(/expected 65, got 64/, client.calls.first[:messages].first[:content])
    assert_equal 1, lines.count { |l| l.include?("Retrying") }
  end

  def test_reconcile_count_mismatch_twice_raises
    segs = i12_segments
    short = reply_for(segs.first(64))
    client = ScriptedClient.new([short, "end_turn"], [short, "end_turn"])

    err = assert_raises(SubtitleReconciler::ReconciliationError) { run_scripted(segs, "t", client) }
    assert_equal 2, client.calls.length
    assert_match(/count mismatch/, err.message)
  end

  def test_build_prompt_requests_compact_one_line_json
    prompt = SubtitleReconciler.build_prompt([{"start" => 0.0, "end" => 1.0, "text" => "x"}], "x")
    assert_match(/compact.*one line/i, prompt)
  end

  def test_parse_response_unescaped_quote_inside_value_is_repaired
    text = '[{"start":0.0,"end":1.0,"text":"powiedział.""},' \
      '{"start":1.0,"end":2.0,"text":""Morala bi," je rekel."}]'
    result = SubtitleReconciler.parse_response(text)
    assert_equal 'powiedział."', result[0]["text"]
    assert_equal '"Morala bi," je rekel.', result[1]["text"]
  end

  def test_repair_json_leaves_valid_json_unchanged
    valid = [
      JSON.generate([{"start" => 0.0, "end" => 1.0, "text" => %(He said "hi", then: [ok] {x}.)}]),
      JSON.pretty_generate([{"start" => 0.0, "end" => 1.0, "text" => %(a \\ "b" \n)}, {"text" => ""}]),
      '[ { "text" : "x" } , { "text":"y" } ]'
    ]
    valid.each do |v|
      JSON.parse(v) # the fixture itself is valid
      assert_equal v, SubtitleReconciler.repair_json(v)
    end
  end

  private

  def stub_reconcile_reply(reply, &)
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) do |**_|
      FakeMsg.new([Struct.new(:text).new(JSON.generate(reply))])
    end
    Anthropic::Client.stub(:new, Struct.new(:messages).new(fake_messages), &)
  end
end
