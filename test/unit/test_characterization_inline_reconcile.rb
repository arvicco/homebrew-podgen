# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "date"
require "episode_history"
require "cli/language_pipeline"
require "subtitle_reconciliation_runner"
require "subtitle_reconciler"
require "timestamp_persister"

# P3-0 H1 characterization harness: pins the CURRENT behavior of the
# reconcile-and-persist step as LanguagePipeline#reconcile_subtitles inlines
# it, side by side with SubtitleReconciliationRunner.run (used by regen and
# the YouTube publisher), before a later packet consolidates them. The
# "contrast" tests feed both paths the same fixture so any behavior the
# dry-up changes on either side goes RED.
#
# SubtitleReconciler.reconcile is always stubbed: no Anthropic API calls.
class TestCharacterizationInlineReconcile < Minitest::Test
  BASE = "lang-2026-03-10"
  RAW_SEGMENTS = [
    {"start" => 0.0, "end" => 5.0, "text" => "raw garbled"},
    {"start" => 5.0, "end" => 10.0, "text" => "more garble"}
  ].freeze
  CLEAN_SEGMENTS = [
    {"start" => 0.0, "end" => 5.0, "text" => "Clean one"},
    {"start" => 5.0, "end" => 10.0, "text" => "Clean two"}
  ].freeze

  class EventLogger
    attr_reader :events

    def initialize = @events = []

    def log(msg) = @events << [:log, msg]

    def error(msg) = @events << [:error, msg]

    def phase_start(name) = @events << [:phase_start, name]

    def phase_end(name) = @events << [:phase_end, name]
  end

  PipelineConfig = Struct.new(:podcast_dir, :episodes_dir, :transcription_language, :vocabulary_level,
    :lingq_enabled, keyword_init: true) do
    def lingq_enabled? = lingq_enabled
  end

  def setup
    @tmpdir = Dir.mktmpdir("podgen_char_recon")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    @logger = EventLogger.new
    @saved_key = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "test-key-not-real"
  end

  def teardown
    @saved_key.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = @saved_key
    FileUtils.rm_rf(@tmpdir)
  end

  # ════════════════════════════════════════════════════════════════════
  # Inline path — LanguagePipeline#reconcile_subtitles
  # ════════════════════════════════════════════════════════════════════

  def test_reconcile_subtitles_happy_path_reconciles_in_memory_text_and_persists
    pipeline = build_pipeline(reconciled_text: "In-memory reconciled text.")
    write_staged_timestamps(pipeline)
    calls = []

    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_equal [[RAW_SEGMENTS, "In-memory reconciled text.", "test-key-not-real"]], calls
    data = JSON.parse(File.read(staged_ts_path(pipeline)))
    assert_equal CLEAN_SEGMENTS, data["segments"]
    assert_equal true, data["reconciled"]
    assert_equal [
      [:phase_start, "Subtitle Reconciliation"],
      [:log, "Subtitles reconciled (2 segments)"],
      [:phase_end, "Subtitle Reconciliation"]
    ], @logger.events
    assert_empty pipeline.instance_variable_get(:@warnings)
  end

  def test_reconcile_subtitles_reads_staging_dir_not_episodes_dir
    pipeline = build_pipeline(reconciled_text: "Text.")
    write_timestamps(File.join(@episodes_dir, "#{BASE}_timestamps.json"))
    calls = []

    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_empty calls
    assert_empty @logger.events
  end

  def test_reconcile_subtitles_without_reconciled_text_is_silent_noop
    pipeline = build_pipeline(reconciled_text: nil)
    write_staged_timestamps(pipeline)
    calls = []

    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_empty calls
    assert_empty @logger.events
    refute JSON.parse(File.read(staged_ts_path(pipeline)))["reconciled"]
  end

  def test_reconcile_subtitles_without_timestamps_file_is_silent_noop
    pipeline = build_pipeline(reconciled_text: "Text.")
    FileUtils.mkdir_p(staging_dir(pipeline))
    calls = []

    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_empty calls
    assert_empty @logger.events
    assert_empty pipeline.instance_variable_get(:@warnings)
  end

  def test_reconcile_subtitles_without_api_key_is_silent_noop
    pipeline = build_pipeline(reconciled_text: "Text.")
    write_staged_timestamps(pipeline)
    calls = []

    [nil, ""].each do |key|
      key.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = key
      stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }
    end

    assert_empty calls
    assert_empty @logger.events, "inline path logs nothing when the key is missing (runner returns :no_api_key)"
    assert_empty pipeline.instance_variable_get(:@warnings)
  end

  def test_reconcile_subtitles_already_reconciled_file_is_reconciled_again
    pipeline = build_pipeline(reconciled_text: "Text.")
    write_staged_timestamps(pipeline, reconciled: true)
    calls = []

    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_equal 1, calls.length, "inline path has no already-reconciled guard"
    assert_equal CLEAN_SEGMENTS, JSON.parse(File.read(staged_ts_path(pipeline)))["segments"]
  end

  def test_reconcile_subtitles_blank_reconciled_text_still_calls_reconciler
    pipeline = build_pipeline(reconciled_text: "   ")
    write_staged_timestamps(pipeline)
    calls = []

    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_equal [[RAW_SEGMENTS, "   ", "test-key-not-real"]], calls,
      "inline path has no empty-transcript guard (runner returns :no_transcript)"
  end

  def test_reconcile_subtitles_reconciler_error_is_skippable_warning_and_file_untouched
    pipeline = build_pipeline(reconciled_text: "Text.")
    write_staged_timestamps(pipeline)
    before = File.read(staged_ts_path(pipeline))
    raiser = ->(*, **) { raise SubtitleReconciler::ReconciliationError, "bad json" }

    SubtitleReconciler.stub(:reconcile, raiser) { pipeline.send(:reconcile_subtitles) }

    assert_equal before, File.read(staged_ts_path(pipeline))
    assert_equal ["Subtitle reconciliation failed (SubtitleReconciler::ReconciliationError: bad json)"],
      pipeline.instance_variable_get(:@warnings)
    assert_equal [
      [:phase_start, "Subtitle Reconciliation"],
      [:log, "Warning: Subtitle reconciliation failed: SubtitleReconciler::ReconciliationError: bad json " \
             "(non-fatal, keeping raw segments)"],
      [:phase_end, "Subtitle Reconciliation"]
    ], @logger.events
  end

  def test_reconcile_subtitles_corrupt_timestamps_is_skippable_warning
    pipeline = build_pipeline(reconciled_text: "Text.")
    FileUtils.mkdir_p(staging_dir(pipeline))
    File.write(staged_ts_path(pipeline), "{ truncated")
    calls = []

    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_empty calls
    warnings = pipeline.instance_variable_get(:@warnings)
    assert_equal 1, warnings.length
    assert_match(/\ASubtitle reconciliation failed \(TimestampPersister::CorruptSidecarError: /, warnings.first)
  end

  # Pins where the inline step sits in LanguagePipeline#run: after the
  # timestamps are persisted into staging and BEFORE the transcript file is
  # written (so it cannot read the transcript from disk the way the runner
  # does) and before commit / post-commit uploads.
  def test_run_reconcile_subtitles_runs_after_persist_timestamps_and_before_transcript_save
    pipeline = build_pipeline(reconciled_text: "Text.", options: {lingq: true, youtube: true})
    pipeline.instance_variable_set(:@transcription_result, {text: "raw"})
    order = []
    nil_steps = %i[validate_image_options acquire_episode]
    steps = %i[setup_staging trim_source_audio discover_transcript transcribe
      clean_or_generate_description trim_outro assemble_episode persist_timestamps
      reconcile_subtitles save_transcript_and_cover annotate_vocabulary commit_episode
      upload_to_lingq upload_to_youtube log_completion cleanup_temp_files cleanup_staging]
    (nil_steps + steps).each do |step|
      pipeline.define_singleton_method(step) do |*|
        order << step
        nil
      end
    end

    code = pipeline.run

    assert_equal 0, code
    assert_equal nil_steps + steps, order
  end

  # ════════════════════════════════════════════════════════════════════
  # Runner path — SubtitleReconciliationRunner.run (regen, publisher)
  # Behaviors not pinned by test_subtitle_reconciliation_runner.rb.
  # ════════════════════════════════════════════════════════════════════

  def test_run_reconciles_transcript_file_body_not_header_or_vocabulary
    ts = File.join(@tmpdir, "r_timestamps.json")
    tr = File.join(@tmpdir, "r_transcript.md")
    write_timestamps(ts)
    File.write(tr, "# Title\n\nDesc\n\n## Transcript\n\nBody **marked** text.\n\n## Vocabulary\n\n- **w** — def\n")
    calls = []

    result = stub_reconciler(calls) { SubtitleReconciliationRunner.run(ts_path: ts, transcript_path: tr, api_key: "k") }

    assert_equal :reconciled, result.status
    assert_equal "reconciled 2 segments", result.message
    assert_equal [[RAW_SEGMENTS, "Body **marked** text.", "k"]], calls
  end

  def test_run_defaults_api_key_from_env
    ts = File.join(@tmpdir, "r_timestamps.json")
    tr = File.join(@tmpdir, "r_transcript.md")
    write_timestamps(ts)
    File.write(tr, "# T\n\n## Transcript\n\nBody.\n")
    calls = []

    stub_reconciler(calls) { SubtitleReconciliationRunner.run(ts_path: ts, transcript_path: tr) }

    assert_equal "test-key-not-real", calls.first[2]
  end

  def test_run_corrupt_timestamps_returns_failed
    ts = File.join(@tmpdir, "r_timestamps.json")
    File.write(ts, "{ truncated")

    result = SubtitleReconciliationRunner.run(ts_path: ts, transcript_path: nil, api_key: "k")

    assert_equal :failed, result.status
    assert_match(/corrupt timestamps sidecar/, result.message)
  end

  def test_run_nil_transcript_path_returns_no_transcript
    ts = File.join(@tmpdir, "r_timestamps.json")
    write_timestamps(ts)

    result = SubtitleReconciliationRunner.run(ts_path: ts, transcript_path: nil, api_key: "k")

    assert_equal :no_transcript, result.status
  end

  def test_run_guard_order_already_reconciled_checked_before_api_key_and_transcript
    ts = File.join(@tmpdir, "r_timestamps.json")
    write_timestamps(ts, reconciled: true)

    result = SubtitleReconciliationRunner.run(ts_path: ts, transcript_path: nil, api_key: nil)

    assert_equal :already_reconciled, result.status
  end

  def test_run_guard_order_api_key_checked_before_transcript
    ts = File.join(@tmpdir, "r_timestamps.json")
    write_timestamps(ts)

    result = SubtitleReconciliationRunner.run(ts_path: ts, transcript_path: nil, api_key: "")

    assert_equal :no_api_key, result.status
  end

  # ════════════════════════════════════════════════════════════════════
  # Contrast — same fixture through both paths
  # ════════════════════════════════════════════════════════════════════

  def test_contrast_already_reconciled_runner_skips_inline_reconciles
    pipeline = build_pipeline(reconciled_text: "Text.")
    write_staged_timestamps(pipeline, reconciled: true)
    tr = File.join(@tmpdir, "c_transcript.md")
    File.write(tr, "# T\n\n## Transcript\n\nText.\n")
    calls = []

    result = stub_reconciler(calls) do
      SubtitleReconciliationRunner.run(ts_path: staged_ts_path(pipeline), transcript_path: tr)
    end
    runner_calls = calls.length
    stub_reconciler(calls) { pipeline.send(:reconcile_subtitles) }

    assert_equal :already_reconciled, result.status
    assert_equal 0, runner_calls
    assert_equal 1, calls.length
  end

  def test_contrast_reconciler_error_runner_returns_failed_inline_records_warning
    pipeline = build_pipeline(reconciled_text: "Text.")
    write_staged_timestamps(pipeline)
    tr = File.join(@tmpdir, "c_transcript.md")
    File.write(tr, "# T\n\n## Transcript\n\nText.\n")
    raiser = ->(*, **) { raise SubtitleReconciler::ReconciliationError, "boom" }

    result = nil
    SubtitleReconciler.stub(:reconcile, raiser) do
      result = SubtitleReconciliationRunner.run(ts_path: staged_ts_path(pipeline), transcript_path: tr)
      pipeline.send(:reconcile_subtitles)
    end

    assert_equal SubtitleReconciliationRunner::Result.new(status: :failed, message: "boom"), result
    assert_equal ["Subtitle reconciliation failed (SubtitleReconciler::ReconciliationError: boom)"],
      pipeline.instance_variable_get(:@warnings)
  end

  private

  def build_pipeline(reconciled_text:, options: {})
    config = PipelineConfig.new(podcast_dir: @tmpdir, episodes_dir: @episodes_dir,
      transcription_language: "sl", vocabulary_level: "B1", lingq_enabled: false)
    pipeline = PodgenCLI::LanguagePipeline.new(
      config: config,
      options: {verbosity: :quiet}.merge(options),
      logger: @logger,
      history: EpisodeHistory.new(File.join(@tmpdir, "history.yml")),
      today: Date.new(2026, 3, 10)
    )
    pipeline.instance_variable_set(:@base_name, BASE)
    pipeline.instance_variable_set(:@reconciled_text, reconciled_text)
    pipeline
  end

  def staging_dir(pipeline) = pipeline.instance_variable_get(:@staging_dir)

  def staged_ts_path(pipeline) = File.join(staging_dir(pipeline), "#{BASE}_timestamps.json")

  def write_staged_timestamps(pipeline, reconciled: false)
    FileUtils.mkdir_p(staging_dir(pipeline))
    write_timestamps(staged_ts_path(pipeline), reconciled: reconciled)
  end

  def write_timestamps(path, reconciled: false)
    data = {"version" => 1, "engine" => "groq", "intro_duration" => 0.0, "segments" => RAW_SEGMENTS}
    data["reconciled"] = true if reconciled
    File.write(path, JSON.pretty_generate(data))
  end

  def stub_reconciler(calls, &block)
    fake = ->(segments, text, api_key:) {
      calls << [segments, text, api_key]
      CLEAN_SEGMENTS.map(&:dup)
    }
    SubtitleReconciler.stub(:reconcile, fake, &block)
  end
end
