# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../tell_mocks"
require "tell/config"
require "tell/detector"
require "tell/translator"
require "tell/tts"
require "tell/glosser"
require "tell/espeak"
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
      tts_model_id: "eleven_multilingual_v2",
      output_format: "mp3_44100_128",
      translation_timeout: 8.0,
      reverse_translate: false,
      gloss: false,
      gloss_reverse: false,
      phonetic: false,
      gloss_model: ["claude-opus-4-6"],
      phonetic_model: ["claude-opus-4-6"]
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
    # gloss_reverse subsumes gloss — only GR: fires, not both GL: and GR:
    assert_equal [[:gloss_translate, "dober dan"]], @glosser.calls
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

  def test_explanation_no_speech_no_addons
    # Translation 3x+ longer → explanation → no speech, no addons
    @config.gloss = true
    processor = build_processor
    @translator.forward_result = "This is a very long explanation that is much longer than the original text"
    stub_detect("en") do
      processor.process("hi", translate_from: "auto")
    end
    assert_empty @tts.calls
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
    @config.gloss_model = ["claude-opus-4-6", "claude-sonnet-4-6"]
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(gloss_result: "opus_gloss")
    glosser_sonnet = MockGlosser.new(gloss_result: "sonnet_gloss")
    processor = Tell::Processor.new(@config, interactive: false, tts: @tts, translator: @translator, glossers: {
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
    @config.gloss_model = ["claude-opus-4-6", "claude-sonnet-4-6"]
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(gloss_result: "opus_gloss")
    glosser_sonnet = MockGlosser.new(error: RuntimeError.new("API down"))
    processor = Tell::Processor.new(@config, interactive: false, tts: @tts, translator: @translator, glossers: {
      "claude-opus-4-6" => glosser_opus,
      "claude-sonnet-4-6" => glosser_sonnet
    })

    processor.process("danes je lep dan")

    # Only one model succeeded → return its result without reconciliation
    assert_empty glosser_opus.reconcile_calls
  end

  def test_multi_model_all_fail_reports_error
    @config.gloss = true
    @config.gloss_model = ["claude-opus-4-6", "claude-sonnet-4-6"]
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(error: RuntimeError.new("Opus down"))
    glosser_sonnet = MockGlosser.new(error: RuntimeError.new("Sonnet down"))
    processor = Tell::Processor.new(@config, interactive: false, tts: @tts, translator: @translator, glossers: {
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
    @config.gloss_model = ["claude-opus-4-6", "claude-sonnet-4-6"]
    @tts = MockTts.new
    @translator = MockTranslator.new
    glosser_opus = MockGlosser.new(gloss_translate_result: "opus_gr")
    glosser_sonnet = MockGlosser.new(gloss_translate_result: "sonnet_gr")
    processor = Tell::Processor.new(@config, interactive: false, tts: @tts, translator: @translator, glossers: {
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
    # Translation >3x length IS an explanation — no speech
    processor = build_processor
    @translator.forward_result = "abcd" # 4 chars > 3x "x" (1 char)
    stub_detect("en") do
      processor.process("x", translate_from: "auto")
    end
    assert_empty @tts.calls
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

  # --- Translation hints ---

  def test_hints_stripped_before_synthesis_default_mode
    processor = build_processor
    processor.process("dober dan /pm")
    assert_equal ["dober dan"], @tts.calls
  end

  def test_hints_stripped_and_passed_to_translator
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_detect("en") do
      processor.process("good morning /pm", translate_from: "auto")
    end
    assert_equal ["dober dan"], @tts.calls
    assert_includes @translator.forward_calls, ["good morning", { from: "en", to: "sl" }]
    hints = @translator.forward_hints.last
    assert_equal :polite, hints.formality
    assert_equal :male, hints.gender
  end

  def test_hints_casual_female
    processor = build_processor
    @translator.forward_result = "živijo"
    stub_detect("en") do
      processor.process("hi /cf", translate_from: "auto")
    end
    hints = @translator.forward_hints.last
    assert_equal :casual, hints.formality
    assert_equal :female, hints.gender
  end

  def test_no_hints_passes_nil_formality
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_detect("en") do
      processor.process("good morning", translate_from: "auto")
    end
    hints = @translator.forward_hints.last
    assert_nil hints.formality
    assert_nil hints.gender
  end

  def test_hint_only_input_skipped
    processor = build_processor
    processor.process("/pm")
    assert_empty @tts.calls
  end

  # --- Voice switching by gender hint ---

  def test_male_hint_switches_voice
    @config.voice_male = "male_voice"
    processor = build_processor
    processor.process("dober dan /m")
    assert_equal ["dober dan"], @tts.calls
    assert_equal ["male_voice"], @tts.voices
  end

  def test_female_hint_switches_voice
    @config.voice_female = "female_voice"
    processor = build_processor
    processor.process("dober dan /f")
    assert_equal ["dober dan"], @tts.calls
    assert_equal ["female_voice"], @tts.voices
  end

  def test_no_gender_hint_uses_default_voice
    @config.voice_male = "male_voice"
    @config.voice_female = "female_voice"
    processor = build_processor
    processor.process("dober dan")
    assert_equal ["dober dan"], @tts.calls
    assert_equal [nil], @tts.voices
  end

  def test_gender_hint_without_voice_config_uses_default
    # voice_male/voice_female not set → nil passed → TTS uses its default
    processor = build_processor
    processor.process("dober dan /m")
    assert_equal ["dober dan"], @tts.calls
    assert_equal [nil], @tts.voices
  end

  def test_voice_switch_with_translation
    @config.voice_female = "female_voice"
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_detect("en") do
      processor.process("good morning /f", translate_from: "auto")
    end
    assert_equal ["dober dan"], @tts.calls
    assert_equal ["female_voice"], @tts.voices
  end

  # --- Phonetic add-on (standalone, Claude fallback) ---

  def test_standalone_phonetic_fires_claude_when_espeak_unavailable
    @config.phonetic = true
    processor = build_processor
    stub_espeak_off { processor.process("dober dan") }
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
    assert_empty @glosser.calls  # no gloss calls
  end

  def test_default_phonetic_false_no_addon
    processor = build_processor
    processor.process("dober dan")
    assert_empty @glosser.phonetic_calls
  end

  def test_auto_detect_target_fires_standalone_phonetic_claude
    @config.phonetic = true
    processor = build_processor
    stub_espeak_off do
      stub_detect("sl") do
        processor.process("danes je lep dan", translate_from: "auto")
      end
    end
    assert_equal [[:phonetic, "danes je lep dan"]], @glosser.phonetic_calls
  end

  def test_auto_detect_forward_fires_standalone_phonetic_claude
    @config.phonetic = true
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_espeak_off do
      stub_detect("en") do
        processor.process("good morning", translate_from: "auto")
      end
    end
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
  end

  def test_phonetic_error_does_not_block_tts
    @config.phonetic = true
    processor = build_processor
    @glosser.error = RuntimeError.new("Anthropic down")
    stub_espeak_off { processor.process("danes je lep dan") }
    assert_equal ["danes je lep dan"], @tts.calls
  end

  # --- Phonetic add-on (eSpeak path) ---

  def test_standalone_phonetic_uses_espeak_for_ipa
    skip "espeak-ng not installed" unless Tell::Espeak.available?
    @config.phonetic = true
    processor = build_processor
    processor.process("dober dan")
    # eSpeak handles it — glosser NOT called
    assert_empty @glosser.phonetic_calls
  end

  def test_standalone_phonetic_espeak_output_displayed
    skip "espeak-ng not installed" unless Tell::Espeak.available?
    @config.phonetic = true
    processor = build_processor
    output = capture_stderr { processor.process("dober dan") }
    assert_match %r{PH:.*/.+/}, output
  end

  def test_non_ipa_system_skips_espeak
    skip "espeak-ng not installed" unless Tell::Espeak.available?
    @config.phonetic = true
    @config.phonetic_system = "simple"
    processor = build_processor
    processor.process("dober dan")
    # Non-IPA system → Claude glosser called, not eSpeak
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
  end

  # --- Combined --gp (gloss + phonetic inline) ---

  def test_gp_fires_gloss_phonetic_and_standalone
    @config.gloss = true
    @config.phonetic = true
    processor = build_processor
    stub_espeak_off { processor.process("dober dan") }
    # Combined path: base gloss + mechanical merge with phonetic
    assert_equal [[:gloss, "dober dan"]], @glosser.calls
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
  end

  def test_gp_forward_translation
    @config.gloss = true
    @config.phonetic = true
    processor = build_processor
    @translator.forward_result = "dober dan"
    stub_espeak_off do
      stub_detect("en") do
        processor.process("good morning", translate_from: "auto")
      end
    end
    # Combined path: base gloss + mechanical merge with phonetic
    assert_equal [[:gloss, "dober dan"]], @glosser.calls
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
  end

  # --- Combined --grp (gloss_translate + phonetic inline + standalone) ---

  def test_grp_fires_gloss_translate_phonetic_and_standalone
    @config.gloss_reverse = true
    @config.phonetic = true
    processor = build_processor
    stub_espeak_off { processor.process("dober dan") }
    # Combined path: base gloss_translate + mechanical merge with phonetic
    assert_equal [[:gloss_translate, "dober dan"]], @glosser.calls
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
  end

  # --- Combined --rp (reverse + standalone phonetic) ---

  def test_rp_fires_reverse_and_standalone_phonetic
    @config.reverse_translate = true
    @config.phonetic = true
    processor = build_processor
    stub_espeak_off { processor.process("dober dan") }
    assert_includes @translator.reverse_calls, ["dober dan", { from: "sl", to: "en" }]
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
    assert_empty @glosser.calls  # no gloss
  end

  # --- All flags including phonetic ---

  def test_all_flags_with_phonetic_integrates_into_gloss
    @config.reverse_translate = true
    @config.gloss = true
    @config.gloss_reverse = true
    @config.phonetic = true
    processor = build_processor
    # gloss_reverse subsumes gloss — combined path fires base gloss_translate + merge
    stub_espeak_off { processor.process("dober dan") }
    assert_equal [[:gloss_translate, "dober dan"]], @glosser.calls
    assert_includes @translator.reverse_calls, ["dober dan", { from: "sl", to: "en" }]
    assert_equal [[:phonetic, "dober dan"]], @glosser.phonetic_calls
  end

  # --- Add-on errors ---

  def test_glosser_error_does_not_block_tts
    @config.gloss = true
    processor = build_processor
    @glosser.error = RuntimeError.new("Anthropic down")
    processor.process("danes je lep dan")
    assert_equal ["danes je lep dan"], @tts.calls
  end

  # --- play_audio / stop_playback ---

  def test_play_audio_non_interactive_cleans_up_temp
    processor = build_processor(interactive: false)
    tmp_files = []
    # Stub system to avoid actually playing audio
    processor.define_singleton_method(:system) { |*_args| true }
    processor.send(:play_audio, "fake_audio_data")
    # The temp file should be deleted after play
    Dir.glob(File.join(Dir.tmpdir, "tell_#{Process.pid}_*")).each do |f|
      tmp_files << f
    end
    assert_empty tmp_files, "Temp files should be cleaned up"
  end

  def test_play_audio_interactive_spawns_and_cleans_up
    processor = build_processor(interactive: true)
    spawned = false
    # Stub spawn to avoid playing
    processor.define_singleton_method(:spawn) { |*_args| spawned = true; $$.to_i }
    # Stub Process.wait to avoid hanging
    processor.send(:play_audio, "fake_audio_data")
    assert spawned, "Should spawn afplay in interactive mode"
    # Give cleanup thread a moment
    sleep 0.05
  end

  def test_stop_playback_with_no_pid_is_noop
    processor = build_processor(interactive: true)
    # Should not raise
    processor.send(:stop_playback)
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

  # --- Japanese phonetic pipeline ---

  def test_japanese_hiragana_calls_ai_with_hiragana_system
    @config.target_language = "ja"
    @config.phonetic = true
    @config.phonetic_system = "hiragana"
    @glosser_ja = MockGlosser.new(phonetic_result: "おはよう・ございます")
    processor = build_processor_with_glosser(@glosser_ja)
    output = capture_stderr { processor.process("おはようございます") }
    # AI called with hiragana system
    assert_equal [[:phonetic, "おはようございます"]], @glosser_ja.phonetic_calls
    assert_match(/PH:.*おはよう・ございます/, output)
  end

  def test_japanese_hepburn_derives_from_ai_hiragana
    @config.target_language = "ja"
    @config.phonetic = true
    @config.phonetic_system = "hepburn"
    @glosser_ja = MockGlosser.new(phonetic_result: "おはよう・ございます")
    processor = build_processor_with_glosser(@glosser_ja)
    output = capture_stderr { processor.process("おはようございます") }
    # AI called once for hiragana, then Kana converts to hepburn
    assert_equal [[:phonetic, "おはようございます"]], @glosser_ja.phonetic_calls
    assert_match(/PH:.*ohayou gozaimasu/, output)
  end

  def test_japanese_kunrei_derives_from_ai_hiragana
    @config.target_language = "ja"
    @config.phonetic = true
    @config.phonetic_system = "kunrei"
    @glosser_ja = MockGlosser.new(phonetic_result: "おはよう・ございます")
    processor = build_processor_with_glosser(@glosser_ja)
    output = capture_stderr { processor.process("おはようございます") }
    assert_equal [[:phonetic, "おはようございます"]], @glosser_ja.phonetic_calls
    assert_match(/PH:.*ohayou gozaimasu/, output)
  end

  def test_japanese_ipa_uses_kana_module
    @config.target_language = "ja"
    @config.phonetic = true
    @config.phonetic_system = "ipa"
    @glosser_ja = MockGlosser.new(phonetic_result: "おはよう・ございます")
    processor = build_processor_with_glosser(@glosser_ja)
    output = capture_stderr { processor.process("おはようございます") }
    # AI called for hiragana, then Kana module converts to broad IPA
    assert_equal [[:phonetic, "おはようございます"]], @glosser_ja.phonetic_calls
    assert_match %r{PH:.*/.+/}, output
    # Verify broad IPA symbols from Kana (not eSpeak narrow phonetic)
    assert_match(/ɡozaimasɯ/, output)
  end

  def test_japanese_hiragana_cached_across_calls
    @config.target_language = "ja"
    @config.phonetic = true
    @config.phonetic_system = "hiragana"
    @glosser_ja = MockGlosser.new(phonetic_result: "こんにちは")
    processor = build_processor_with_glosser(@glosser_ja)
    # First call
    capture_stderr { processor.process("こんにちは") }
    assert_equal 1, @glosser_ja.phonetic_calls.size
    # Switch to hepburn — should reuse cached hiragana
    @config.phonetic_system = "hepburn"
    output = capture_stderr { processor.process("こんにちは") }
    assert_equal 1, @glosser_ja.phonetic_calls.size  # no additional AI call
    assert_match(/PH:.*konnichiha/, output)
  end

  private

  # --- Helpers ---

  def build_processor_with_glosser(glosser, interactive: false)
    @tts = MockTts.new
    @translator = MockTranslator.new
    glossers = @config.gloss_model.each_with_object({}) { |m, h| h[m] = glosser }
    @config.phonetic_model.each { |m| glossers[m] = glosser }
    Tell::Processor.new(@config, interactive: interactive, tts: @tts, translator: @translator, glossers: glossers)
  end

  def build_processor(interactive: false)
    @tts = MockTts.new
    @translator = MockTranslator.new
    @glosser = MockGlosser.new
    glossers = @config.gloss_model.each_with_object({}) { |m, h| h[m] = @glosser }
    @config.phonetic_model.each { |m| glossers[m] = @glosser }
    Tell::Processor.new(@config, interactive: interactive, tts: @tts, translator: @translator, glossers: glossers)
  end

  def stub_detect(result, &block)
    Tell::Detector.stub(:detect, result) do
      Tell::Detector.stub(:has_characteristic_chars?, false, &block)
    end
  end

  def stub_espeak_off(&block)
    Tell::Espeak.stub(:supports?, false, &block)
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end
