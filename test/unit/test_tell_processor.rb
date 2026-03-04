# frozen_string_literal: true

require_relative "../test_helper"
require "tell/config"
require "tell/detector"
require "tell/translator"
require "tell/tts"
require "tell/glosser"
require "tell/processor"

class TestTellProcessor < Minitest::Test
  def setup
    @config = MockConfig.new(
      original_language: "en",
      target_language: "sl",
      voice_id: "test_voice",
      translation_engines: ["deepl"],
      tts_engine: "elevenlabs",
      engine_api_keys: { "deepl" => "fake_key" },
      api_key: "fake_eleven_key",
      model_id: "eleven_multilingual_v2",
      output_format: "mp3_44100_128",
      translation_timeout: 8.0,
      reverse_translate: false,
      gloss: false,
      gloss_reverse: false,
      gloss_models: ["claude-opus-4-6"]
    )
  end

  # --- Empty / blank input ---

  def test_process_skips_empty_text
    processor = build_processor
    assert_nil processor.process("")
    assert_empty @tts.calls
  end

  def test_process_skips_blank_text
    processor = build_processor
    assert_nil processor.process("   ")
    assert_empty @tts.calls
  end

  # --- Default mode (no translate_from) ---

  def test_default_synthesizes_as_is
    processor = build_processor
    processor.process("dober dan")
    assert_equal ["dober dan"], @tts.calls
  end

  def test_default_does_not_call_detector
    processor = build_processor
    detected = false
    Tell::Detector.stub(:detect, ->(_) { detected = true; "sl" }) do
      processor.process("dober dan")
    end
    refute detected, "Detector should not be called in default mode"
    assert_equal ["dober dan"], @tts.calls
  end

  def test_default_fires_gloss
    @config.gloss = true
    processor = build_processor
    processor.process("dober dan")
    assert_equal [[:gloss, "dober dan"]], @glosser.calls
  end

  def test_default_fires_reverse
    @config.reverse_translate = true
    processor = build_processor
    processor.process("dober dan")
    assert_includes @translator.reverse_calls, ["dober dan", { from: "sl", to: "en" }]
  end

  def test_default_fires_gloss_translate
    @config.gloss_reverse = true
    processor = build_processor
    processor.process("dober dan")
    assert_equal [[:gloss_translate, "dober dan"]], @glosser.calls
  end

  def test_default_all_flags_false_no_addons
    processor = build_processor
    processor.process("dober dan")
    assert_equal ["dober dan"], @tts.calls
    assert_empty @glosser.calls
    assert_empty @translator.reverse_calls
  end

  def test_default_all_flags_true_all_addons_fire
    @config.reverse_translate = true
    @config.gloss = true
    @config.gloss_reverse = true
    processor = build_processor
    processor.process("dober dan")
    assert_equal ["dober dan"], @tts.calls
    assert_includes @glosser.calls, [:gloss, "dober dan"]
    assert_includes @glosser.calls, [:gloss_translate, "dober dan"]
    assert_includes @translator.reverse_calls, ["dober dan", { from: "sl", to: "en" }]
  end

  # --- Auto-detect target (translate_from: "auto") ---

  def test_auto_detect_target_synthesizes_directly
    processor = build_processor
    stub_detect("sl") do
      processor.process("danes je lep dan", translate_from: "auto")
    end
    assert_equal ["danes je lep dan"], @tts.calls
  end

  def test_auto_detect_target_fires_gloss
    @config.gloss = true
    processor = build_processor
    stub_detect("sl") do
      processor.process("danes je lep dan", translate_from: "auto")
    end
    assert_equal [[:gloss, "danes je lep dan"]], @glosser.calls
  end

  def test_auto_detect_target_fires_gloss_translate
    @config.gloss_reverse = true
    processor = build_processor
    stub_detect("sl") do
      processor.process("danes je lep dan", translate_from: "auto")
    end
    assert_equal [[:gloss_translate, "danes je lep dan"]], @glosser.calls
  end

  def test_auto_detect_target_fires_reverse
    @config.reverse_translate = true
    processor = build_processor
    stub_detect("sl") do
      processor.process("danes je lep dan", translate_from: "auto")
    end
    assert_includes @translator.reverse_calls, ["danes je lep dan", { from: "sl", to: "en" }]
  end

  # --- Characteristic chars fallback (auto-detect) ---

  def test_characteristic_chars_triggers_target_path_with_addons
    @config.gloss = true
    processor = build_processor
    # detect returns nil, but chars match → target path
    Tell::Detector.stub(:detect, nil) do
      Tell::Detector.stub(:has_characteristic_chars?, true) do
        processor.process("Desetnica", translate_from: "auto")
      end
    end
    assert_equal ["Desetnica"], @tts.calls
    assert_equal [[:gloss, "Desetnica"]], @glosser.calls
  end

  # --- Auto-detect forward translation ---

  def test_auto_detect_forward_translation
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_detect("en") do
      processor.process("good morning", translate_from: "auto")
    end
    assert_equal ["dober dan"], @tts.calls
    assert_includes @translator.forward_calls, ["good morning", { from: "en", to: "sl" }]
  end

  def test_auto_detect_forward_fires_gloss
    @config.gloss = true
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_detect("en") do
      processor.process("good morning", translate_from: "auto")
    end
    assert_equal [[:gloss, "dober dan"]], @glosser.calls
  end

  def test_auto_detect_forward_fires_reverse
    @config.reverse_translate = true
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_detect("en") do
      processor.process("good morning", translate_from: "auto")
    end
    assert_includes @translator.reverse_calls, ["dober dan", { from: "sl", to: "en" }]
  end

  # --- Explicit -f LANG ---

  def test_explicit_from_translates
    processor = build_processor
    @translator.forward_result = "dober dan"
    processor.process("good morning", translate_from: "en")
    assert_equal ["dober dan"], @tts.calls
    assert_includes @translator.forward_calls, ["good morning", { from: "en", to: "sl" }]
  end

  def test_explicit_from_skips_detection
    processor = build_processor
    @translator.forward_result = "dober dan"
    detected = false
    Tell::Detector.stub(:detect, ->(_) { detected = true; "en" }) do
      processor.process("good morning", translate_from: "en")
    end
    refute detected, "Detector should not be called with explicit -f LANG"
    assert_equal ["dober dan"], @tts.calls
  end

  def test_explicit_from_matching_target_speaks_directly
    processor = build_processor
    processor.process("dober dan", translate_from: "sl")
    assert_equal ["dober dan"], @tts.calls
    assert_empty @translator.forward_calls
  end

  def test_explicit_from_matching_target_fires_addons
    @config.gloss = true
    processor = build_processor
    processor.process("dober dan", translate_from: "sl")
    assert_equal [[:gloss, "dober dan"]], @glosser.calls
  end

  # --- Translation returns nil (explanation or same-text) ---

  def test_explanation_speaks_original_no_addons
    # Translation 3x+ longer → explanation → forward_translate returns nil
    @config.gloss = true
    processor = build_processor
    @translator.forward_result = "This is a very long explanation that is much longer than the original text"
    stub_detect("en") do
      processor.process("hi", translate_from: "auto")
    end
    assert_equal ["hi"], @tts.calls
    assert_empty @glosser.calls
  end

  def test_same_text_recognized_as_target_fires_addons
    # Translation matches input → text was already target language → fire add-ons
    @config.gloss = true
    processor = build_processor
    @translator.forward_result = "hello"
    stub_detect("en") do
      processor.process("hello", translate_from: "auto")
    end
    assert_equal ["hello"], @tts.calls
    assert_equal [[:gloss, "hello"]], @glosser.calls
  end

  # --- Translation error ---

  def test_translation_error_speaks_original_no_addons
    @config.gloss = true
    processor = build_processor
    @translator.forward_error = RuntimeError.new("API timeout")
    stub_detect("en") do
      processor.process("hello there", translate_from: "auto")
    end
    assert_equal ["hello there"], @tts.calls
    assert_empty @glosser.calls
  end

  # --- Interactive mode ---

  def test_interactive_mode_does_not_join_threads
    @config.gloss = true
    processor = build_processor(interactive: true)
    processor.process("danes je lep dan")
    # Just verify it completes without hanging — gloss fires asynchronously
    assert_equal ["danes je lep dan"], @tts.calls
  end

  # --- Multi-model glossing ---

  def test_multi_model_gloss_calls_reconcile
    @config.gloss = true
    @config.gloss_models = ["claude-opus-4-6", "claude-sonnet-4-6"]
    processor = Tell::Processor.new(@config, interactive: false)
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(gloss_result: "opus_gloss")
    glosser_sonnet = MockGlosser.new(gloss_result: "sonnet_gloss")
    processor.instance_variable_set(:@tts, @tts)
    processor.instance_variable_set(:@translator, @translator)
    processor.instance_variable_set(:@glossers, {
      "claude-opus-4-6" => glosser_opus,
      "claude-sonnet-4-6" => glosser_sonnet
    })

    processor.process("danes je lep dan")

    assert_equal [[:gloss, "danes je lep dan"]], glosser_opus.calls
    assert_equal [[:gloss, "danes je lep dan"]], glosser_sonnet.calls
    # Reconciler is the first (opus) model
    assert_equal 1, glosser_opus.reconcile_calls.size
    reconcile_call = glosser_opus.reconcile_calls.first
    assert_equal({ "claude-opus-4-6" => "opus_gloss", "claude-sonnet-4-6" => "sonnet_gloss" }, reconcile_call[:glosses])
    assert_equal :gloss, reconcile_call[:mode]
  end

  def test_multi_model_single_survivor_skips_reconcile
    @config.gloss = true
    @config.gloss_models = ["claude-opus-4-6", "claude-sonnet-4-6"]
    processor = Tell::Processor.new(@config, interactive: false)
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(gloss_result: "opus_gloss")
    glosser_sonnet = MockGlosser.new(error: RuntimeError.new("API down"))
    processor.instance_variable_set(:@tts, @tts)
    processor.instance_variable_set(:@translator, @translator)
    processor.instance_variable_set(:@glossers, {
      "claude-opus-4-6" => glosser_opus,
      "claude-sonnet-4-6" => glosser_sonnet
    })

    processor.process("danes je lep dan")

    # Only one model succeeded → return its result without reconciliation
    assert_empty glosser_opus.reconcile_calls
  end

  def test_multi_model_all_fail_reports_error
    @config.gloss = true
    @config.gloss_models = ["claude-opus-4-6", "claude-sonnet-4-6"]
    processor = Tell::Processor.new(@config, interactive: false)
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(error: RuntimeError.new("Opus down"))
    glosser_sonnet = MockGlosser.new(error: RuntimeError.new("Sonnet down"))
    processor.instance_variable_set(:@tts, @tts)
    processor.instance_variable_set(:@translator, @translator)
    processor.instance_variable_set(:@glossers, {
      "claude-opus-4-6" => glosser_opus,
      "claude-sonnet-4-6" => glosser_sonnet
    })

    # Should not raise — error is caught and printed to stderr
    processor.process("danes je lep dan")
    assert_equal ["danes je lep dan"], @tts.calls
  end

  # --- Multi-model gloss_translate ---

  def test_multi_model_gloss_translate_calls_reconcile
    @config.gloss_reverse = true
    @config.gloss_models = ["claude-opus-4-6", "claude-sonnet-4-6"]
    processor = Tell::Processor.new(@config, interactive: false)
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(gloss_translate_result: "opus_gr")
    glosser_sonnet = MockGlosser.new(gloss_translate_result: "sonnet_gr")
    processor.instance_variable_set(:@tts, @tts)
    processor.instance_variable_set(:@translator, @translator)
    processor.instance_variable_set(:@glossers, {
      "claude-opus-4-6" => glosser_opus,
      "claude-sonnet-4-6" => glosser_sonnet
    })

    processor.process("danes je lep dan")

    assert_equal [[:gloss_translate, "danes je lep dan"]], glosser_opus.calls
    assert_equal [[:gloss_translate, "danes je lep dan"]], glosser_sonnet.calls
    reconcile_call = glosser_opus.reconcile_calls.first
    assert_equal :gloss_translate, reconcile_call[:mode]
    assert_equal({ "claude-opus-4-6" => "opus_gr", "claude-sonnet-4-6" => "sonnet_gr" }, reconcile_call[:glosses])
  end

  # --- Translation boundary ---

  def test_explanation_exactly_3x_is_not_explanation
    # Translation exactly 3x length is NOT an explanation — it gets spoken
    processor = build_processor
    @translator.forward_result = "abc" # 3 chars = 3x "x" (1 char)
    stub_detect("en") do
      processor.process("x", translate_from: "auto")
    end
    assert_equal ["abc"], @tts.calls
  end

  def test_explanation_just_over_3x_is_explanation
    # Translation >3x length IS an explanation — original gets spoken
    processor = build_processor
    @translator.forward_result = "abcd" # 4 chars > 3x "x" (1 char)
    stub_detect("en") do
      processor.process("x", translate_from: "auto")
    end
    assert_equal ["x"], @tts.calls
  end

  # --- Piped output (stdout not tty) ---

  def test_piped_output_writes_to_stdout
    processor = build_processor
    fake_stdout = StringIO.new
    fake_stdout.define_singleton_method(:tty?) { false }
    original_stdout = $stdout
    $stdout = fake_stdout
    begin
      processor.process("danes je lep dan")
    ensure
      $stdout = original_stdout
    end
    assert_equal "fake_audio", fake_stdout.string
  end

  # --- friendly_error ---

  def test_friendly_error_overloaded_json
    processor = build_processor
    err = RuntimeError.new('{"type":"overloaded_error","message":"Overloaded"}')
    assert_equal "API overloaded (try again)", processor.send(:friendly_error, err)
  end

  def test_friendly_error_overloaded_status
    processor = build_processor
    err = RuntimeError.new("status: 529 overloaded")
    assert_equal "API overloaded (try again)", processor.send(:friendly_error, err)
  end

  def test_friendly_error_rate_limit_json
    processor = build_processor
    err = RuntimeError.new('{"type":"rate_limit_error","message":"Too many requests"}')
    assert_equal "rate limited (try again)", processor.send(:friendly_error, err)
  end

  def test_friendly_error_rate_limit_status
    processor = build_processor
    err = RuntimeError.new("status: 429 too many requests")
    assert_equal "rate limited (try again)", processor.send(:friendly_error, err)
  end

  def test_friendly_error_http_status_with_message
    processor = build_processor
    err = RuntimeError.new('status: 500, "message": "Internal server error"')
    assert_equal "HTTP 500: Internal server error", processor.send(:friendly_error, err)
  end

  def test_friendly_error_truncates_long_message
    processor = build_processor
    long_msg = "A" * 100
    err = RuntimeError.new(long_msg)
    result = processor.send(:friendly_error, err)
    assert_equal 80, result.length
    assert result.end_with?("...")
  end

  def test_friendly_error_short_message_passthrough
    processor = build_processor
    err = RuntimeError.new("connection refused")
    assert_equal "connection refused", processor.send(:friendly_error, err)
  end

  # --- Add-on errors ---

  def test_glosser_error_does_not_block_tts
    @config.gloss = true
    processor = build_processor
    @glosser.error = RuntimeError.new("Anthropic down")
    processor.process("danes je lep dan")
    assert_equal ["danes je lep dan"], @tts.calls
  end

  # --- Output to file ---

  def test_output_to_file
    processor = build_processor
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.mp3")
      processor.process("danes je lep dan", output_path: path)
      assert File.exist?(path)
      assert_equal "fake_audio", File.read(path)
    end
  end

  private

  # --- Helpers ---

  def build_processor(interactive: false)
    processor = Tell::Processor.new(@config, interactive: interactive)
    @tts = MockTts.new
    @translator = MockTranslator.new
    @glosser = MockGlosser.new
    processor.instance_variable_set(:@tts, @tts)
    processor.instance_variable_set(:@translator, @translator)
    # Processor now caches glossers by model_id
    glossers = @config.gloss_models.each_with_object({}) { |m, h| h[m] = @glosser }
    processor.instance_variable_set(:@glossers, glossers)
    processor
  end

  def stub_detect(result, &block)
    Tell::Detector.stub(:detect, result) do
      Tell::Detector.stub(:has_characteristic_chars?, false, &block)
    end
  end

  # --- Mock collaborators ---

  MockConfig = Struct.new(
    :original_language, :target_language, :voice_id,
    :translation_engines, :tts_engine, :engine_api_keys,
    :api_key, :tts_api_key, :model_id, :output_format,
    :google_language_code, :reverse_translate, :gloss, :gloss_reverse,
    :gloss_models, :translation_timeout,
    keyword_init: true
  ) do
    def translation_engine
      translation_engines&.first
    end

    def engine_api_key
      engine_api_keys&.dig(translation_engine)
    end

    def reverse_language
      original_language == "auto" ? "en" : original_language
    end

    def gloss_model
      gloss_models&.first
    end

    def gloss_reconciler
      gloss_models&.first
    end
  end

  class MockTts
    attr_reader :calls

    def initialize
      @calls = []
    end

    def synthesize(text)
      @calls << text
      "fake_audio"
    end
  end

  class MockTranslator
    attr_reader :reverse_calls, :forward_calls
    attr_accessor :forward_result, :forward_error

    def initialize
      @reverse_calls = []
      @forward_calls = []
      @forward_result = nil
      @forward_error = nil
    end

    def translate(text, from:, to:)
      raise @forward_error if @forward_error

      if to == "en" # reverse translation
        @reverse_calls << [text, { from: from, to: to }]
        "back_translation"
      else
        @forward_calls << [text, { from: from, to: to }]
        @forward_result || text
      end
    end
  end

  class MockGlosser
    attr_reader :calls, :reconcile_calls
    attr_accessor :error

    def initialize(gloss_result: nil, gloss_translate_result: nil, error: nil)
      @calls = []
      @reconcile_calls = []
      @gloss_result = gloss_result || "word(n.m.N.sg)"
      @gloss_translate_result = gloss_translate_result || "word(n.m.N.sg)translation"
      @error = error
    end

    def gloss(text, from:, to:)
      raise @error if @error
      @calls << [:gloss, text]
      @gloss_result
    end

    def gloss_translate(text, from:, to:)
      raise @error if @error
      @calls << [:gloss_translate, text]
      @gloss_translate_result
    end

    def reconcile(glosses, text, from:, to:, mode:)
      @reconcile_calls << { glosses: glosses, text: text, from: from, to: to, mode: mode }
      "reconciled(n.m.N.sg)"
    end
  end
end
