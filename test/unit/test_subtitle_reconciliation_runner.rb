# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "subtitle_reconciliation_runner"
require "subtitle_reconciler"

class TestSubtitleReconciliationRunner < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("recon_runner")
    @ts_path = File.join(@tmpdir, "ep_timestamps.json")
    @tr_path = File.join(@tmpdir, "ep_transcript.md")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def write_timestamps(reconciled: false, segments: nil)
    segments ||= [
      { "start" => 0.0, "end" => 5.0, "text" => "raw garbled" },
      { "start" => 5.0, "end" => 10.0, "text" => "more garble" }
    ]
    data = {
      "version" => 1,
      "engine" => "groq",
      "intro_duration" => 0.0,
      "segments" => segments
    }
    data["reconciled"] = true if reconciled
    File.write(@ts_path, JSON.pretty_generate(data))
  end

  def write_transcript(body = "Clean correct text.")
    File.write(@tr_path, "# Title\n\n## Transcript\n\n#{body}\n")
  end

  def stub_reconciler(segments)
    SubtitleReconciler.stub(:reconcile, ->(_segs, _text, **_) { segments }) do
      yield
    end
  end

  # ── status: :no_timestamps ─────────────────────────────────────────

  def test_run_returns_no_timestamps_when_file_missing
    write_transcript
    result = SubtitleReconciliationRunner.run(
      ts_path: @ts_path, transcript_path: @tr_path, api_key: "k"
    )
    assert_equal :no_timestamps, result.status
  end

  # ── status: :already_reconciled ────────────────────────────────────

  def test_run_skips_when_already_reconciled
    write_timestamps(reconciled: true)
    write_transcript
    result = SubtitleReconciliationRunner.run(
      ts_path: @ts_path, transcript_path: @tr_path, api_key: "k"
    )
    assert_equal :already_reconciled, result.status
  end

  def test_run_with_force_ignores_reconciled_flag
    write_timestamps(reconciled: true)
    write_transcript
    new_segs = [
      { "start" => 0.0, "end" => 5.0, "text" => "FORCED" },
      { "start" => 5.0, "end" => 10.0, "text" => "FORCED2" }
    ]
    result = stub_reconciler(new_segs) do
      SubtitleReconciliationRunner.run(
        ts_path: @ts_path, transcript_path: @tr_path, api_key: "k", force: true
      )
    end
    assert_equal :reconciled, result.status
    data = JSON.parse(File.read(@ts_path))
    assert_equal "FORCED", data["segments"][0]["text"]
    assert_equal true, data["reconciled"]
  end

  # ── status: :no_api_key ────────────────────────────────────────────

  def test_run_returns_no_api_key_when_key_missing
    write_timestamps
    write_transcript
    result = SubtitleReconciliationRunner.run(
      ts_path: @ts_path, transcript_path: @tr_path, api_key: nil
    )
    assert_equal :no_api_key, result.status
  end

  def test_run_returns_no_api_key_when_key_empty
    write_timestamps
    write_transcript
    result = SubtitleReconciliationRunner.run(
      ts_path: @ts_path, transcript_path: @tr_path, api_key: ""
    )
    assert_equal :no_api_key, result.status
  end

  # ── status: :no_transcript ─────────────────────────────────────────

  def test_run_returns_no_transcript_when_transcript_empty
    write_timestamps
    write_transcript("")
    result = SubtitleReconciliationRunner.run(
      ts_path: @ts_path, transcript_path: @tr_path, api_key: "k"
    )
    assert_equal :no_transcript, result.status
  end

  def test_run_returns_no_transcript_when_transcript_file_missing
    write_timestamps
    result = SubtitleReconciliationRunner.run(
      ts_path: @ts_path, transcript_path: @tr_path, api_key: "k"
    )
    assert_equal :no_transcript, result.status
  end

  # ── status: :reconciled (happy path) ───────────────────────────────

  def test_run_reconciles_and_persists_segments
    write_timestamps
    write_transcript("Clean text.")
    new_segs = [
      { "start" => 0.0, "end" => 5.0, "text" => "Clean text part 1" },
      { "start" => 5.0, "end" => 10.0, "text" => "Clean text part 2" }
    ]
    result = stub_reconciler(new_segs) do
      SubtitleReconciliationRunner.run(
        ts_path: @ts_path, transcript_path: @tr_path, api_key: "k"
      )
    end

    assert_equal :reconciled, result.status
    assert_match(/2 segments/, result.message)

    data = JSON.parse(File.read(@ts_path))
    assert_equal true, data["reconciled"]
    assert_equal "Clean text part 1", data["segments"][0]["text"]
  end

  # ── status: :failed ────────────────────────────────────────────────

  def test_run_returns_failed_when_reconciler_raises
    write_timestamps
    write_transcript
    SubtitleReconciler.stub(:reconcile, ->(*) { raise SubtitleReconciler::ReconciliationError, "JSON parse oops" }) do
      result = SubtitleReconciliationRunner.run(
        ts_path: @ts_path, transcript_path: @tr_path, api_key: "k"
      )
      assert_equal :failed, result.status
      assert_match(/JSON parse oops/, result.message)
    end
  end

  def test_run_failed_result_carries_error_class
    write_timestamps
    write_transcript
    SubtitleReconciler.stub(:reconcile, ->(*) { raise SubtitleReconciler::ReconciliationError, "bad" }) do
      result = SubtitleReconciliationRunner.run(ts_path: @ts_path, transcript_path: @tr_path, api_key: "k")
      assert_equal :failed, result.status
      assert_equal "bad", result.message
      assert_equal "SubtitleReconciler::ReconciliationError", result.error_class
    end
  end

  # ── text: keyword (in-memory transcript, P4-2) ─────────────────────

  def test_run_with_text_reconciles_text_without_reading_transcript_file
    write_timestamps
    calls = []
    fake = ->(segs, text, api_key:) {
      calls << [text, api_key]
      segs
    }
    TranscriptParser.stub(:parse_file, ->(_) { flunk "transcript file must not be read when text: is given" }) do
      SubtitleReconciler.stub(:reconcile, fake) do
        result = SubtitleReconciliationRunner.run(
          ts_path: @ts_path, transcript_path: nil, text: "In-memory text.", api_key: "k"
        )
        assert_equal :reconciled, result.status
      end
    end
    assert_equal [["In-memory text.", "k"]], calls
  end

  def test_run_with_blank_text_returns_no_transcript_without_calling_reconciler
    write_timestamps
    write_transcript("File body that must be ignored.")
    SubtitleReconciler.stub(:reconcile, ->(*) { flunk "reconciler must not run on blank text" }) do
      result = SubtitleReconciliationRunner.run(
        ts_path: @ts_path, transcript_path: @tr_path, text: "  \n", api_key: "k"
      )
      assert_equal :no_transcript, result.status
    end
    refute JSON.parse(File.read(@ts_path))["reconciled"]
  end

  def test_run_with_text_keeps_already_reconciled_guard
    write_timestamps(reconciled: true)
    result = SubtitleReconciliationRunner.run(ts_path: @ts_path, transcript_path: nil, text: "T.", api_key: "k")
    assert_equal :already_reconciled, result.status
  end
end
