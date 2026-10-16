# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "post_pipeline_uploads"
require "youtube_publisher"
require "youtube_uploader"
require "regen_cache"
require "subtitle_generator"
require "video_generator"
require "subtitle_reconciliation_runner"
require "subtitle_reconciler"
require "timestamp_persister"
require "transcription/engine_manager"
require "upload_tracker"
require "google/apis/errors"

# P3-0 H1 characterization harness: pins the behavior of the two YouTube
# upload entry points — PostPipelineUploads#upload_to_youtube (generate
# --youtube) and YouTubePublisher#upload_loop (publish --youtube / yt-batch).
# They are consolidated: both now run the shared routine
# YouTubePublisher#upload_episode (upload_to_youtube passes its metadata
# hash and authoritative timestamps). These tests go RED if a change alters
# a step, its order, its arguments, or its failure handling on either entry
# point. Where the entry points still differ (metadata source, timestamp
# handling, logging), both sides are pinned so the difference stays a
# visible, deliberate decision rather than a silent side effect.
#
# Every external seam is faked: no network, no ffmpeg, no YouTube API.
class TestCharacterizationYouTubeUploadPaths < Minitest::Test
  BASE = "ep-2026-03-10"

  # Records every seam call into one shared, ordered list.
  class FakeUploader
    attr_reader :upload_kwargs

    def initialize(calls, video_id: "vid_1", fail_on: nil, error: nil)
      @calls = calls
      @video_id = video_id
      @fail_on = fail_on
      @error = error || RuntimeError.new("#{fail_on} boom")
    end

    def authorize!
      @calls << [:authorize]
    end

    def verify_playlist!(id)
      @calls << [:verify_playlist, id]
      raise @error if @fail_on == :verify_playlist
    end

    def upload_video(path, **kw)
      @calls << [:upload_video, File.basename(path)]
      @upload_kwargs = kw
      raise @error if @fail_on == :upload_video
      @video_id
    end

    def upload_captions(video_id, srt_path, language:)
      @calls << [:upload_captions, video_id, File.basename(srt_path), language]
      raise @error if @fail_on == :upload_captions
    end

    def add_to_playlist(video_id, playlist_id)
      @calls << [:add_to_playlist, video_id, playlist_id]
    end
  end

  class FakeTracker
    def initialize(calls, path)
      @calls = calls
      @path = path
    end

    def entries_for(_platform, _group) = {}

    def record(platform, group, base_name, upload_id)
      @calls << [:record, platform, group, base_name, upload_id]
    end
  end

  class FakeVideoGenerator
    def initialize(calls, fail: false)
      @calls = calls
      @fail = fail
    end

    def generate(_audio_path, _image_path, output_path)
      @calls << [:video_generate, File.basename(output_path)]
      raise "ffmpeg exploded" if @fail
      File.write(output_path, "mp4")
      output_path
    end
  end

  class EventLogger
    attr_reader :events

    def initialize = @events = []

    def log(msg) = @events << [:log, msg]

    def phase_start(name) = @events << [:phase_start, name]

    def phase_end(name) = @events << [:phase_end, name]

    def messages = @events.select { |e| e[0] == :log }.map(&:last)
  end

  PipelineConfig = Struct.new(:episodes_dir, :name, :transcription_language, :yt, keyword_init: true) do
    def youtube_enabled? = !yt.nil?

    def youtube_config = yt

    def lingq_enabled? = false
  end

  PublisherConfig = Struct.new(:episodes_dir, :name, :transcription_language, :target_language,
    :transcription_engines, :yt, keyword_init: true) do
    def youtube_enabled? = !yt.nil?

    def youtube_config = yt
  end

  def setup
    @tmpdir = Dir.mktmpdir("podgen_char_yt")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    @logger = EventLogger.new
    RegenCache.reset!
    YouTubePublisher.reset_playlist_cache!
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    RegenCache.reset!
    YouTubePublisher.reset_playlist_cache!
  end

  # ════════════════════════════════════════════════════════════════════
  # Path A — PostPipelineUploads#upload_to_youtube (generate --youtube)
  # ════════════════════════════════════════════════════════════════════

  def test_upload_to_youtube_dry_run_logs_skip_and_touches_no_seam
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {playlist: "PLx"}, dry_run: true)

    with_seams(calls, uploader: FakeUploader.new(calls)) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    assert_equal [], calls
    assert_equal [[:log, "[dry-run] Skipping YouTube upload"]], @logger.events
    assert_empty uploads.warnings
  end

  # P4-8 flipped: the pipeline runs the publisher's one routine in its one
  # order (verify playlist → cover check → srt → video → upload → record →
  # captions → playlist). Its timestamps are authoritative, so no
  # retranscription/reconcile step; no explicit authorize! (the uploader
  # authorizes lazily); the uploader is built at first use (the verify step).
  def test_upload_to_youtube_with_playlist_runs_steps_in_shared_routine_order
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {playlist: "PLx"})

    with_seams(calls, uploader: FakeUploader.new(calls, video_id: "vid_p")) do
      uploads.upload_to_youtube(episode: {title: "T", description: "D"}, base_name: BASE, output_path: mp3_path)
    end

    assert_equal [
      [:uploader_new],
      [:verify_playlist, "PLx"],
      [:generate_srt, "#{BASE}_timestamps.json"],
      [:video_generate, "#{BASE}.mp4"],
      [:upload_video, "#{BASE}.mp4"],
      [:record, :youtube, "PLx", BASE, "vid_p"],
      [:upload_captions, "vid_p", "#{BASE}.srt", "sl"],
      [:add_to_playlist, "vid_p", "PLx"]
    ], calls
    assert_empty uploads.warnings
  end

  def test_upload_to_youtube_success_logs_phase_bracket_and_recorded_line
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: FakeUploader.new(calls, video_id: "vid_ok")) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    assert_equal [:phase_start, "YouTube Upload"], @logger.events.first
    assert_equal [:phase_end, "YouTube Upload"], @logger.events.last
    assert_includes @logger.messages, "Recorded YouTube upload: #{BASE} → vid_ok"
  end

  def test_upload_to_youtube_without_playlist_records_under_default_group
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: FakeUploader.new(calls, video_id: "vid_d")) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    refute(calls.any? { |c| c[0] == :verify_playlist || c[0] == :add_to_playlist })
    record_at = calls.index { |c| c[0] == :record }
    assert_equal [:record, :youtube, "default", BASE, "vid_d"], calls[record_at]
    assert_equal :upload_video, calls[record_at - 1][0]
  end

  def test_upload_to_youtube_without_timestamps_skips_srt_and_captions_and_never_retranscribes
    seed_episode(timestamps: false, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {}, engines: %w[groq])

    with_seams(calls, uploader: FakeUploader.new(calls)) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    kinds = calls.map(&:first)
    refute_includes kinds, :engine_manager
    refute_includes kinds, :generate_srt
    refute_includes kinds, :upload_captions
    refute_includes kinds, :reconcile
    assert_includes kinds, :upload_video
    assert_empty uploads.warnings
  end

  def test_upload_to_youtube_with_unreconciled_timestamps_never_reconciles
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: FakeUploader.new(calls)) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    refute_includes calls.map(&:first), :reconcile
    refute_includes calls.map(&:first), :reconciler_direct
    refute JSON.parse(File.read(ts_path))["reconciled"], "timestamps file must be left unreconciled"
  end

  # P4-8 flipped: mp4 reuse everywhere (was: the pipeline always regenerated).
  def test_upload_to_youtube_existing_mp4_is_reused_not_regenerated
    seed_episode(timestamps: true, cover: true, mp4: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: FakeUploader.new(calls)) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    refute_includes calls.map(&:first), :video_generate
    assert_includes calls, [:upload_video, "#{BASE}.mp4"]
  end

  # P4-8 flipped: a non-nil episode-hash field wins; a nil one falls back to
  # the transcript file (was: nil description uploaded as "").
  def test_upload_to_youtube_metadata_hash_wins_and_file_fills_nil_fields
    seed_episode(timestamps: true, cover: true, transcript_title: "File Title")
    calls = []
    uploader = FakeUploader.new(calls)
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: uploader) do
      uploads.upload_to_youtube(episode: {title: "Hash Title", description: nil}, base_name: BASE, output_path: mp3_path)
    end

    assert_equal({title: "Hash Title", description: "Desc", language: "sl",
                  privacy: "unlisted", category: "27", tags: []}, uploader.upload_kwargs)
  end

  def test_upload_to_youtube_nil_description_without_transcript_file_uploads_empty_string
    seed_episode(timestamps: true, cover: true)
    File.delete(File.join(@episodes_dir, "#{BASE}_transcript.md"))
    calls = []
    uploader = FakeUploader.new(calls)
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: uploader) do
      uploads.upload_to_youtube(episode: {title: "T", description: nil}, base_name: BASE, output_path: mp3_path)
    end

    assert_equal "", uploader.upload_kwargs[:description]
  end

  def test_upload_to_youtube_configured_privacy_category_tags_pass_through
    seed_episode(timestamps: false, cover: true)
    calls = []
    uploader = FakeUploader.new(calls)
    uploads = build_pipeline_uploads(yt: {privacy: "public", category: "22", tags: %w[a b]})

    with_seams(calls, uploader: uploader) do
      uploads.upload_to_youtube(episode: {title: "T", description: "D"}, base_name: BASE, output_path: mp3_path)
    end

    assert_equal "public", uploader.upload_kwargs[:privacy]
    assert_equal "22", uploader.upload_kwargs[:category]
    assert_equal %w[a b], uploader.upload_kwargs[:tags]
    assert_equal "D", uploader.upload_kwargs[:description]
  end

  def test_upload_to_youtube_nil_language_defaults_to_en_for_video_and_captions
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploader = FakeUploader.new(calls, video_id: "vid_en")
    uploads = build_pipeline_uploads(yt: {}, language: nil)

    with_seams(calls, uploader: uploader) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    assert_equal "en", uploader.upload_kwargs[:language]
    assert_includes calls, [:upload_captions, "vid_en", "#{BASE}.srt", "en"]
  end

  # P4-0 flipped this former divergence pin: the pipeline now records the
  # upload right after upload_video, like the publisher path (see the Path B
  # twin), so a captions failure is a warning and the upload stays tracked.
  def test_upload_to_youtube_captions_failure_keeps_upload_recorded
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {playlist: "PLx"})

    with_seams(calls, uploader: FakeUploader.new(calls, video_id: "vid_c", fail_on: :upload_captions)) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    kinds = calls.map(&:first)
    assert_includes kinds, :upload_video
    refute_includes kinds, :add_to_playlist
    assert_includes calls, [:record, :youtube, "PLx", BASE, "vid_c"]
    assert_equal ["YouTube upload failed (RuntimeError: upload_captions boom)"], uploads.warnings
  end

  def test_upload_to_youtube_playlist_verification_failure_is_skippable_warning_before_upload
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {playlist: "PLbad"})

    with_seams(calls, uploader: FakeUploader.new(calls, fail_on: :verify_playlist)) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    refute_includes calls.map(&:first), :upload_video
    assert_equal ["YouTube upload failed (RuntimeError: verify_playlist boom)"], uploads.warnings
  end

  # P4-8 flipped: verification is cached per pod+playlist everywhere (was:
  # the pipeline verified on every call).
  def test_upload_to_youtube_verifies_playlist_once_per_pod_and_playlist
    seed_episode(timestamps: true, cover: true)
    calls = []

    with_seams(calls, uploader: FakeUploader.new(calls)) do
      2.times do
        build_pipeline_uploads(yt: {playlist: "PLx"})
          .upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
      end
    end

    assert_equal 1, calls.count { |c| c[0] == :verify_playlist }
    assert_equal 2, calls.count { |c| c[0] == :upload_video }
  end

  def test_upload_to_youtube_failure_logs_class_and_backtrace_without_phase_end
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: FakeUploader.new(calls, fail_on: :upload_video)) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    assert_includes @logger.messages,
      "Warning: YouTube upload failed: RuntimeError: upload_video boom (non-fatal, continuing)"
    refute_includes @logger.events, [:phase_end, "YouTube Upload"]
    refute_includes calls.map(&:first), :record
  end

  def test_upload_to_youtube_video_generation_failure_is_skippable_warning
    seed_episode(timestamps: true, cover: true)
    calls = []
    uploads = build_pipeline_uploads(yt: {})

    with_seams(calls, uploader: FakeUploader.new(calls), video_fail: true) do
      uploads.upload_to_youtube(episode: {title: "T"}, base_name: BASE, output_path: mp3_path)
    end

    refute_includes calls.map(&:first), :uploader_new
    assert_equal ["YouTube upload failed (RuntimeError: ffmpeg exploded)"], uploads.warnings
  end

  # ════════════════════════════════════════════════════════════════════
  # Path B — YouTubePublisher#upload_loop (publish --youtube / yt-batch)
  # ════════════════════════════════════════════════════════════════════

  def test_upload_loop_with_playlist_runs_steps_in_publisher_order
    seed_episode(timestamps: true, cover: true)
    calls = []
    publisher = build_publisher(yt: {playlist: "PLx"}, uploader: FakeUploader.new(calls, video_id: "vid_p"))

    result = run_publisher(publisher, calls)

    # Q-80 / Phase 7 flipped: run authorizes once BEFORE playlist
    # verification and any per-episode work (was: lazy, on the first API
    # call). Reconcile via runner; video built only if missing; tracker
    # record BEFORE captions and playlist insertion.
    assert_equal [
      [:authorize],
      [:verify_playlist, "PLx"],
      [:reconcile, "#{BASE}_timestamps.json", "#{BASE}_transcript.md"],
      [:generate_srt, "#{BASE}_timestamps.json"],
      [:video_generate, "#{BASE}.mp4"],
      [:upload_video, "#{BASE}.mp4"],
      [:record, :youtube, "PLx", BASE, "vid_p"],
      [:upload_captions, "vid_p", "#{BASE}.srt", "sl"],
      [:add_to_playlist, "vid_p", "PLx"]
    ], calls
    assert_equal 1, result.uploaded
    assert_equal 1, result.attempted
    assert_empty result.errors
  end

  # Q-80 / Phase 7 flipped: was "never calls authorize explicitly" (lazy
  # auth on the first API call — with no playlist that was upload_video, so
  # one episode's subtitles and mp4 were prepared before a refused consent
  # surfaced). run now authorizes exactly once, first; the injected
  # uploader is still used as-is.
  def test_upload_loop_authorizes_once_before_any_episode_work
    seed_episode(timestamps: true, cover: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls))

    run_publisher(publisher, calls)

    assert_equal [:authorize], calls.first
    assert_equal 1, calls.count { |c| c.first == :authorize }
    refute_includes calls.map(&:first), :uploader_new
  end

  def test_upload_loop_metadata_comes_from_transcript_file_with_defaults
    seed_episode(timestamps: true, cover: true, transcript_title: "File Title", transcript_description: "File Desc")
    calls = []
    uploader = FakeUploader.new(calls)
    publisher = build_publisher(yt: {}, uploader: uploader)

    run_publisher(publisher, calls)

    assert_equal({title: "File Title", description: "File Desc", language: "sl",
                  privacy: "unlisted", category: "27", tags: []}, uploader.upload_kwargs)
  end

  def test_upload_loop_missing_description_uploads_empty_string
    seed_episode(timestamps: true, cover: true, transcript_description: nil)
    calls = []
    uploader = FakeUploader.new(calls)
    publisher = build_publisher(yt: {}, uploader: uploader)

    run_publisher(publisher, calls)

    assert_equal "", uploader.upload_kwargs[:description]
  end

  def test_upload_loop_stdout_lines_for_upload_and_success
    seed_episode(timestamps: true, cover: true, transcript_title: "File Title")
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls, video_id: "vid_s"))

    out = nil
    with_seams(calls) { out, _err = capture_io { publisher.run } }

    assert_includes out, "  uploading: #{BASE} — \"File Title\""
    assert_includes out, "  ✓ #{BASE} → https://youtu.be/vid_s"
  end

  def test_upload_loop_existing_mp4_is_reused_not_regenerated
    seed_episode(timestamps: true, cover: true, mp4: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls))

    result = run_publisher(publisher, calls)

    refute_includes calls.map(&:first), :video_generate
    assert_equal 1, result.uploaded
  end

  def test_upload_loop_missing_timestamps_retranscribes_then_reconciles_then_srt
    seed_episode(timestamps: false, cover: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls, video_id: "vid_r"),
      engines: %w[open groq])

    result = run_publisher(publisher, calls)

    # Q-80 / Phase 7: authorize runs first, before the paid retranscription.
    kinds = calls.map(&:first)
    assert_equal %i[authorize engine_manager transcribe reconcile generate_srt video_generate upload_video record upload_captions],
      kinds
    assert_equal [:engine_manager, ["groq"], "sl"], calls[1], "groq wins TIMESTAMP_ENGINE_PRIORITY over open"
    data = JSON.parse(File.read(ts_path))
    assert_equal 0.0, data["intro_duration"]
    assert_equal "groq", data["engine"]
    assert_equal 1, result.uploaded
  end

  def test_upload_loop_missing_timestamps_without_language_uploads_without_subtitles
    seed_episode(timestamps: false, cover: true)
    calls = []
    uploader = FakeUploader.new(calls)
    publisher = build_publisher(yt: {}, uploader: uploader, language: nil, engines: %w[groq])

    out = nil
    with_seams(calls) { out, _ = capture_io { publisher.run } }

    kinds = calls.map(&:first)
    refute_includes kinds, :engine_manager
    refute_includes kinds, :generate_srt
    refute_includes kinds, :upload_captions
    assert_includes out, "no transcription language configured, skipping subtitles"
    assert_equal "en", uploader.upload_kwargs[:language]
  end

  def test_upload_loop_missing_timestamps_without_engines_uploads_without_subtitles
    seed_episode(timestamps: false, cover: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls), engines: [])

    out = nil
    with_seams(calls) { out, _ = capture_io { publisher.run } }

    refute_includes calls.map(&:first), :engine_manager
    refute_includes calls.map(&:first), :upload_captions
    assert_includes out, "no transcription engine configured, skipping subtitles"
  end

  def test_upload_loop_retranscription_failure_still_uploads_without_captions
    seed_episode(timestamps: false, cover: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls), engines: %w[groq])

    err = nil
    result = nil
    with_seams(calls, transcribe_fail: true) { _, err = capture_io { result = publisher.run } }

    refute_includes calls.map(&:first), :upload_captions
    assert_includes err, "retranscription failed (RuntimeError: stt down), uploading without subtitles"
    assert_equal 1, result.uploaded
    assert_empty result.errors
  end

  def test_upload_loop_reconcile_failed_warns_and_still_uploads_with_captions
    seed_episode(timestamps: true, cover: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls))

    err = nil
    result = nil
    with_seams(calls, reconcile_status: :failed) { _, err = capture_io { result = publisher.run } }

    assert_includes err, "  Warning: subtitle reconciliation failed: stub failed (using raw segments)"
    assert_includes calls.map(&:first), :upload_captions
    assert_equal 1, result.uploaded
  end

  def test_upload_loop_reconciled_status_prints_reconciled_line
    seed_episode(timestamps: true, cover: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls))

    out = nil
    with_seams(calls, reconcile_status: :reconciled) { out, _ = capture_io { publisher.run } }

    assert_includes out, "  reconciled subtitles: #{BASE}_timestamps.json"
  end

  # P4-8 flipped: the cover check runs BEFORE subtitle prep, so a skipped
  # episode costs no paid reconcile/re-transcription (was: reconcile + srt ran).
  # Q-80 / Phase 7: run's up-front authorize is the only seam call.
  def test_upload_loop_missing_cover_skips_before_subtitles_unattempted
    seed_episode(timestamps: true, cover: false)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls))

    result = run_publisher(publisher, calls)

    assert_equal [[:authorize]], calls
    assert_equal 0, result.attempted
    assert_equal 0, result.uploaded
    assert_equal [{type: :missing_cover, base: BASE, message: "no cover image"}], result.errors
  end

  def test_upload_loop_video_generation_failure_is_video_error_unattempted
    seed_episode(timestamps: true, cover: true)
    calls = []
    publisher = build_publisher(yt: {}, uploader: FakeUploader.new(calls))

    result = nil
    with_seams(calls, video_fail: true) { capture_io { result = publisher.run } }

    refute_includes calls.map(&:first), :upload_video
    assert_equal 0, result.attempted
    assert_equal [{type: :video, base: BASE, message: "ffmpeg exploded"}], result.errors
  end

  # Twin of the Path A captions test (both paths agree since P4-0): the publisher records the
  # upload BEFORE captions, so the video stays tracked when captions fail.
  def test_upload_loop_captions_failure_keeps_upload_recorded_and_counts_error
    seed_episode(timestamps: true, cover: true)
    calls = []
    publisher = build_publisher(yt: {playlist: "PLx"},
      uploader: FakeUploader.new(calls, video_id: "vid_c", fail_on: :upload_captions))

    result = run_publisher(publisher, calls)

    assert_includes calls, [:record, :youtube, "PLx", BASE, "vid_c"]
    refute_includes calls.map(&:first), :add_to_playlist
    assert_equal 1, result.attempted
    assert_equal 0, result.uploaded
    assert_equal [{type: :upload, base: BASE, message: "upload_captions boom"}], result.errors
  end

  def test_upload_loop_non_quota_client_error_is_upload_error_and_batch_continues
    seed_episode(timestamps: true, cover: true)
    seed_episode(timestamps: true, cover: true, base: "ep-2026-03-11")
    calls = []
    n = 0
    uploader = FakeUploader.new(calls)
    uploader.define_singleton_method(:upload_video) do |path, **kw|
      calls << [:upload_video, File.basename(path)]
      n += 1
      raise Google::Apis::ClientError.new("badRequest: nope") if n == 1
      "vid_2"
    end
    publisher = build_publisher(yt: {}, uploader: uploader)

    result = run_publisher(publisher, calls)

    refute result.rate_limited
    assert_equal 2, result.attempted
    assert_equal 1, result.uploaded
    assert_equal [{type: :upload, base: BASE, message: "badRequest: nope"}], result.errors
  end

  private

  def mp3_path = File.join(@episodes_dir, "#{BASE}.mp3")

  def ts_path = File.join(@episodes_dir, "#{BASE}_timestamps.json")

  def seed_episode(timestamps:, cover:, mp4: false, base: BASE,
    transcript_title: "Title #{BASE}", transcript_description: "Desc")
    File.write(File.join(@episodes_dir, "#{base}.mp3"), "x" * 100)
    desc = transcript_description ? "#{transcript_description}\n\n" : ""
    File.write(File.join(@episodes_dir, "#{base}_transcript.md"),
      "# #{transcript_title}\n\n#{desc}## Transcript\n\nHello.\n")
    File.write(File.join(@episodes_dir, "#{base}_cover.jpg"), "jpg") if cover
    File.write(File.join(@episodes_dir, "#{base}.mp4"), "mp4") if mp4
    return unless timestamps

    File.write(File.join(@episodes_dir, "#{base}_timestamps.json"), JSON.pretty_generate(
      "version" => 1, "engine" => "groq", "intro_duration" => 0.0,
      "segments" => [{"start" => 0.0, "end" => 1.0, "text" => "raw"}]
    ))
  end

  def build_pipeline_uploads(yt:, dry_run: false, language: "sl", engines: [])
    config = PipelineConfig.new(episodes_dir: @episodes_dir, name: "char_pod", transcription_language: language, yt: yt)
    config.define_singleton_method(:transcription_engines) { engines }
    PostPipelineUploads.new(config: config, logger: @logger, dry_run: dry_run)
  end

  def build_publisher(yt:, uploader:, language: "sl", engines: [])
    config = PublisherConfig.new(episodes_dir: @episodes_dir, name: "char_pod",
      transcription_language: language, target_language: nil, transcription_engines: engines, yt: yt)
    publisher = YouTubePublisher.new(config: config, options: {}, uploader: uploader,
      tracker_path: File.join(@tmpdir, "uploads.yml"))
    publisher.define_singleton_method(:regenerate!) { nil }
    publisher
  end

  def run_publisher(publisher, calls)
    result = nil
    with_seams(calls) { capture_io { result = publisher.run } }
    result
  end

  # Installs every external seam as a recording fake. SubtitleReconciler is
  # wired to raise so no path can reach the Anthropic API unnoticed.
  def with_seams(calls, uploader: nil, video_fail: false, reconcile_status: :already_reconciled,
    transcribe_fail: false, &block)
    srt = ->(ts, out) {
      calls << [:generate_srt, File.basename(ts)]
      File.write(out, "1\n00:00:00,000 --> 00:00:01,000\nraw\n")
    }
    runner = ->(ts_path:, transcript_path:, **) {
      calls << [:reconcile, File.basename(ts_path), File.basename(transcript_path)]
      SubtitleReconciliationRunner::Result.new(status: reconcile_status, message: "stub #{reconcile_status}")
    }
    manager = Object.new
    manager.define_singleton_method(:transcribe) do |_path|
      calls << [:transcribe]
      raise "stt down" if transcribe_fail
      {segments: [{start: 0.0, end: 1.0, text: "stt"}]}
    end
    new_manager = ->(engine_codes:, language:, **) {
      calls << [:engine_manager, engine_codes, language]
      manager
    }
    extract = ->(_result, engine_codes:, **) { [[{start: 0.0, end: 1.0, text: "stt"}], engine_codes.first] }

    SubtitleGenerator.stub(:generate_srt, srt) do
      VideoGenerator.stub(:new, ->(**) { FakeVideoGenerator.new(calls, fail: video_fail) }) do
        YouTubeUploader.stub(:new, ->(**) { calls << [:uploader_new] && uploader }) do
          UploadTracker.stub(:new, ->(path) { FakeTracker.new(calls, path) }) do
            SubtitleReconciliationRunner.stub(:run, runner) do
              SubtitleReconciler.stub(:reconcile, ->(*, **) { calls << [:reconciler_direct] && raise("no network") }) do
                Transcription::EngineManager.stub(:new, new_manager) do
                  TimestampPersister.stub(:extract_segments, extract, &block)
                end
              end
            end
          end
        end
      end
    end
  end
end
