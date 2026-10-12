# frozen_string_literal: true

require_relative "../test_helper"
require "json"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "subtitle_reconciler"
require "transcription/reconciler"

# P3-0 H2 — characterization harness for the two confusably named
# reconcilers. They do different jobs:
#   SubtitleReconciler          — module; segment-PRESERVING: Array of
#                                 {start,end,text} in → same-shape Array out
#   Transcription::Reconciler   — class; whole-transcript MERGE: Hash of
#                                 engine → text (or one text) in → String out
# These tests pin each one's public surface and its behavior on the same
# shaped inputs, so a future rename/merge cannot silently swap semantics.
class TestCharacterizationReconcilers < Minitest::Test
  SEGMENTS = [
    {"start" => 0.0, "end" => 2.5, "text" => "helo wrld"},
    {"start" => 2.5, "end" => 7.7, "text" => "how r u"}
  ].freeze
  TRANSCRIPT = "Hello world. How are you?"

  # ── public API surface ──────────────────────────────────────────────

  def test_subtitle_reconciler_surface_is_a_module_of_singleton_functions
    assert_instance_of Module, SubtitleReconciler
    assert_equal %i[build_prompt close_enough? parse_response reconcile validate!],
      SubtitleReconciler.singleton_methods(false).sort
    assert_equal [[:req, :segments], [:req, :reconciled_text], [:keyreq, :api_key], [:key, :model]],
      SubtitleReconciler.method(:reconcile).parameters
    assert_operator SubtitleReconciler::ReconciliationError, :<, StandardError
    assert_equal 0.01, SubtitleReconciler::TIMESTAMP_EPSILON
  end

  def test_transcription_reconciler_surface_is_a_class_with_reconcile_and_cleanup
    assert_instance_of Class, Transcription::Reconciler
    assert_equal %i[cleanup reconcile], Transcription::Reconciler.public_instance_methods(false).sort
    assert_equal [[:key, :language], [:key, :logger]],
      Transcription::Reconciler.instance_method(:initialize).parameters
    assert_equal [[:req, :transcripts]], Transcription::Reconciler.instance_method(:reconcile).parameters
    assert_equal [[:req, :text], [:key, :captions]], Transcription::Reconciler.instance_method(:cleanup).parameters
    assert_equal 3, Transcription::Reconciler::MAX_RETRIES
  end

  def test_names_two_reconcilers_are_distinct_constants_with_distinct_model_roles
    refute_same SubtitleReconciler, Transcription::Reconciler
    refute Transcription.const_defined?(:SubtitleReconciler, false)
    refute Object.const_defined?(:Reconciler, false), "no top-level Reconciler alias"
    assert_equal :sonnet, ClaudeModels::ROLES[:subtitle_reconciler]
    assert_equal :opus, ClaudeModels::ROLES[:transcript_reconciler]
  end

  # ── SubtitleReconciler: segment-preserving ──────────────────────────

  def test_reconcile_subtitle_segments_returns_same_count_and_boundaries_with_new_text
    reply = SEGMENTS.zip(["Hello world.", "How are you?"]).map { |s, t| s.merge("text" => t) }
    fake = FakeSubtitleClient.new(JSON.generate(reply))

    result = Anthropic::Client.stub(:new, fake) do
      SubtitleReconciler.reconcile(SEGMENTS, TRANSCRIPT, api_key: "k", model: "m")
    end

    assert_kind_of Array, result
    assert_equal SEGMENTS.map { |s| [s["start"], s["end"]] }, result.map { |s| [s["start"], s["end"]] }
    assert_equal ["Hello world.", "How are you?"], result.map { |s| s["text"] }
  end

  def test_reconcile_subtitle_request_shape_has_no_system_prompt_and_scaled_max_tokens
    fake = FakeSubtitleClient.new(JSON.generate(SEGMENTS))

    Anthropic::Client.stub(:new, fake) do
      SubtitleReconciler.reconcile(SEGMENTS, TRANSCRIPT, api_key: "k", model: "m")
    end

    call = fake.calls.first
    assert_equal %i[max_tokens messages model], call.keys.sort, "no system: key"
    assert_equal 4096, call[:max_tokens], "max(4096, segments * 80)"
    many = Array.new(60) { |i| {"start" => i.to_f, "end" => i + 1.0, "text" => "x"} }
    fake2 = FakeSubtitleClient.new(JSON.generate(many))
    Anthropic::Client.stub(:new, fake2) { SubtitleReconciler.reconcile(many, "x", api_key: "k", model: "m") }
    assert_equal 4800, fake2.calls.first[:max_tokens]
  end

  # Drift within epsilon is ACCEPTED and the LLM's drifted values are
  # returned (not snapped back to the originals).
  def test_reconcile_subtitle_drift_within_epsilon_returns_llm_values_not_originals
    reply = [{"start" => 0.0, "end" => 2.5, "text" => "a"}, {"start" => 2.5, "end" => 7.700000001, "text" => "b"}]
    fake = FakeSubtitleClient.new(JSON.generate(reply))

    result = Anthropic::Client.stub(:new, fake) do
      SubtitleReconciler.reconcile(SEGMENTS, TRANSCRIPT, api_key: "k", model: "m")
    end

    assert_equal 7.700000001, result.last["end"]
  end

  def test_reconcile_subtitle_extra_keys_in_reply_pass_through
    reply = SEGMENTS.map { |s| s.merge("speaker" => "x") }
    fake = FakeSubtitleClient.new(JSON.generate(reply))

    result = Anthropic::Client.stub(:new, fake) do
      SubtitleReconciler.reconcile(SEGMENTS, TRANSCRIPT, api_key: "k", model: "m")
    end

    assert_equal %w[start end text speaker], result.first.keys
  end

  def test_reconcile_subtitle_api_error_is_not_retried
    fake = FakeSubtitleClient.new(nil, raise_error: true)

    assert_raises(Anthropic::Errors::APIConnectionError) do
      Anthropic::Client.stub(:new, fake) do
        SubtitleReconciler.reconcile(SEGMENTS, TRANSCRIPT, api_key: "k", model: "m")
      end
    end
    assert_equal 1, fake.calls.length
  end

  def test_validate_empty_segments_both_empty_passes
    assert_equal [], SubtitleReconciler.validate!([], []), "no raise; returns the (empty) reconciled array"
  end

  def test_parse_response_merged_plain_text_reply_raises_reconciliation_error
    assert_raises(SubtitleReconciler::ReconciliationError) do
      SubtitleReconciler.parse_response(TRANSCRIPT)
    end
  end

  def test_build_prompt_drops_extra_segment_keys
    segs = [SEGMENTS.first.merge("words" => [1, 2])]

    prompt = SubtitleReconciler.build_prompt(segs, TRANSCRIPT)

    refute_includes prompt, "words"
    assert_includes prompt, "\"start\": 0.0"
  end

  # ── Transcription::Reconciler: whole-transcript merge ───────────────

  def test_reconcile_transcription_engine_hash_returns_single_string
    reconciler, client = transcription_reconciler("Merged text.")

    result = reconciler.reconcile({"open" => "a", "groq" => "b"})

    assert_kind_of String, result
    assert_equal "Merged text.", result
    call = client.calls.first
    assert_equal %i[max_tokens messages model system], call.keys.sort
    assert_equal 16384, call[:max_tokens]
  end

  def test_reconcile_transcription_joins_text_blocks_and_strips
    reconciler, = transcription_reconciler(["  part one", "part two  "])

    assert_equal "part one\npart two", reconciler.cleanup("raw")
  end

  def test_reconcile_transcription_retries_api_errors_up_to_max
    reconciler, client = transcription_reconciler("ok", fail_times: 2)

    assert_equal "ok", reconciler.reconcile({"a" => "x", "b" => "y"})
    assert_equal 3, client.calls.length
  end

  def test_reconcile_transcription_empty_hash_raises_argument_error
    reconciler, client = transcription_reconciler("x")

    assert_raises(ArgumentError) { reconciler.reconcile({}) }
    assert_empty client.calls
  end

  # ── same-shaped inputs: the semantics a swap would change ───────────

  # Feeding the segment Array to the transcript merger does NOT raise: it
  # is accepted (size >= 2) and returns a String. A swap of the two would
  # therefore fail silently downstream, which is why the shapes are pinned.
  def test_reconcile_transcription_given_segment_array_returns_string_not_segments
    reconciler, client = transcription_reconciler("merged")

    result = reconciler.reconcile(SEGMENTS)

    assert_kind_of String, result
    user = client.calls.first[:messages].first[:content]
    assert_includes user, "=== Engine: "
    assert_includes user, "Reconcile these 2 transcripts"
  end

  def test_reconcile_subtitle_given_transcript_hash_raises
    fake = FakeSubtitleClient.new(JSON.generate(SEGMENTS))

    assert_raises(StandardError) do
      Anthropic::Client.stub(:new, fake) do
        SubtitleReconciler.reconcile({"open" => "a", "groq" => "b"}, TRANSCRIPT, api_key: "k", model: "m")
      end
    end
  end

  def test_reconcile_both_on_merged_text_reply_subtitle_raises_transcription_returns_it
    fake = FakeSubtitleClient.new(TRANSCRIPT)
    assert_raises(SubtitleReconciler::ReconciliationError) do
      Anthropic::Client.stub(:new, fake) do
        SubtitleReconciler.reconcile(SEGMENTS, TRANSCRIPT, api_key: "k", model: "m")
      end
    end

    reconciler, = transcription_reconciler(JSON.generate(SEGMENTS))
    assert_equal JSON.generate(SEGMENTS), reconciler.cleanup(TRANSCRIPT),
      "transcript merger returns whatever text comes back, unparsed"
  end

  private

  # Subtitle path: Anthropic::Client.new is stubbed to return this.
  class FakeSubtitleClient
    attr_reader :calls

    def initialize(text, raise_error: false)
      @text = text
      @raise_error = raise_error
      @calls = []
    end

    def messages = self

    def create(**kw)
      @calls << kw
      raise Anthropic::Errors::APIConnectionError.new(url: nil, request: nil) if @raise_error
      Struct.new(:content).new([Struct.new(:type, :text).new(:text, @text)])
    end
  end

  # Transcription path: @client is replaced after construction.
  class FakeTranscriptClient
    attr_reader :calls

    def initialize(texts, fail_times)
      @texts = Array(texts)
      @fail_times = fail_times
      @calls = []
    end

    def messages = self

    def create(**kw)
      @calls << kw
      raise Anthropic::Errors::APIConnectionError.new(url: nil, request: nil) if @calls.length <= @fail_times
      blocks = @texts.map { |t| Struct.new(:type, :text).new("text", t) }
      usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens).new(1, 1, 0, 0)
      Struct.new(:content, :usage, :stop_reason).new(blocks, usage, "end_turn")
    end
  end

  def transcription_reconciler(texts, fail_times: 0)
    reconciler = Transcription::Reconciler.new(language: "Slovenian")
    reconciler.define_singleton_method(:sleep) { |_| }
    client = FakeTranscriptClient.new(texts, fail_times)
    reconciler.instance_variable_set(:@client, client)
    [reconciler, client]
  end
end
