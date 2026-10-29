# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "fileutils"
require "post_pipeline_uploads"
require "youtube_uploader"
require "youtube_publisher"

class TestPostPipelineUploads < Minitest::Test
  class CaptureLogger
    attr_reader :messages

    def initialize = @messages = []

    def log(msg) = @messages << msg

    def phase_start(_name) = nil

    def phase_end(_name) = nil
  end

  UploadsStubConfig = Struct.new(
    :episodes_dir, :lingq_config, :lingq_enabled, :youtube_enabled,
    :transcription_language,
    keyword_init: true
  ) do
    def lingq_enabled? = lingq_enabled

    def youtube_enabled? = youtube_enabled
  end

  def setup
    @tmpdir = Dir.mktmpdir("podgen_uploads_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    @logger = CaptureLogger.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- record_lingq_upload ---

  def test_record_lingq_upload_creates_tracking_file
    uploads = build_uploads
    tracking_path = File.join(@tmpdir, "uploads.yml")

    uploads.record_lingq_upload(12345, "test-2026-03-10", 999)

    assert File.exist?(tracking_path)
    data = YAML.load_file(tracking_path)
    assert_equal 999, data["lingq"]["12345"]["test-2026-03-10"]
  end

  def test_record_lingq_upload_appends_to_existing
    uploads = build_uploads
    tracking_path = File.join(@tmpdir, "uploads.yml")

    # Pre-populate with unified format
    File.write(tracking_path, {"lingq" => {"12345" => {"old-ep" => 100}}}.to_yaml)

    uploads.record_lingq_upload(12345, "new-ep", 200)

    data = YAML.load_file(tracking_path)
    assert_equal 100, data["lingq"]["12345"]["old-ep"]
    assert_equal 200, data["lingq"]["12345"]["new-ep"]
  end

  def test_record_lingq_upload_handles_separate_collections
    uploads = build_uploads

    uploads.record_lingq_upload(111, "ep-a", 1)
    uploads.record_lingq_upload(222, "ep-b", 2)

    tracking_path = File.join(@tmpdir, "uploads.yml")
    data = YAML.load_file(tracking_path)
    assert_equal 1, data["lingq"]["111"]["ep-a"]
    assert_equal 2, data["lingq"]["222"]["ep-b"]
  end

  # --- upload_to_lingq guards ---

  def test_lingq_skipped_when_not_enabled
    uploads = build_uploads(lingq_enabled: false)

    uploads.upload_to_lingq(episode: {title: "T"}, transcript: "x",
      audio_path: "/tmp/a.mp3", base_name: "ep")

    assert_empty uploads.warnings
    refute File.exist?(File.join(@tmpdir, "uploads.yml"))
  end

  def test_lingq_dry_run_uploads_nothing
    uploads = build_uploads(dry_run: true)

    uploads.upload_to_lingq(episode: {title: "T"}, transcript: "x",
      audio_path: "/tmp/a.mp3", base_name: "ep")

    assert(@logger.messages.any? { |m| m.include?("[dry-run]") })
    refute File.exist?(File.join(@tmpdir, "uploads.yml"))
  end

  def test_lingq_failure_is_skippable_and_names_exception_class
    uploads = build_uploads

    LingQAgent.stub(:new, ->(**_) { raise "API down" }) do
      uploads.upload_to_lingq(episode: {title: "T"}, transcript: "x",
        audio_path: "/tmp/a.mp3", base_name: "ep")
    end

    assert_equal 1, uploads.warnings.size
    assert_includes uploads.warnings.first, "RuntimeError"
  end

  # Q-82 (P10-5): the lesson is already on LingQ — a re-run of a published
  # episode records it like LingQPublisher does, with no failure reported.
  def test_lingq_lesson_exists_records_lesson_id_without_warning
    uploads = build_uploads
    agent = Object.new
    agent.define_singleton_method(:upload) do |**_|
      raise LingQAgent::LessonExists.new("A lesson with the same URL already exists", lesson_id: 4242)
    end

    LingQAgent.stub(:new, ->(**_) { agent }) do
      uploads.upload_to_lingq(episode: {title: "T"}, transcript: "x",
        audio_path: "/tmp/a.mp3", base_name: "ep-2026-03-10")
    end

    assert_empty uploads.warnings
    data = YAML.load_file(File.join(@tmpdir, "uploads.yml"))
    assert_equal 4242, data["lingq"]["12345"]["ep-2026-03-10"]
    assert_includes @logger.messages, "  LingQ: lesson already exists (4242) — recorded"
    refute(@logger.messages.any? { |m| m.include?("Warning") }, @logger.messages.inspect)
  end

  # CRPR round 1 W1: recording the existing lesson is the same skippable
  # side effect; a failing tracker write must not escape the generate.
  def test_lingq_lesson_exists_with_failing_tracker_write_is_skippable_warning
    uploads = build_uploads
    agent = Object.new
    agent.define_singleton_method(:upload) do |**_|
      raise LingQAgent::LessonExists.new("A lesson with the same URL already exists", lesson_id: 4242)
    end
    tracker = Object.new
    tracker.define_singleton_method(:record) { |*_| raise Errno::EACCES, "uploads.yml" }

    LingQAgent.stub(:new, ->(**_) { agent }) do
      UploadTracker.stub(:for_config, ->(_) { tracker }) do
        uploads.upload_to_lingq(episode: {title: "T"}, transcript: "x",
          audio_path: "/tmp/a.mp3", base_name: "ep-2026-03-10")
      end
    end

    assert_equal 1, uploads.warnings.size
    assert_includes uploads.warnings.first, "Errno::EACCES"
    assert(@logger.messages.any? { |m| m.start_with?("Warning: LingQ upload failed") && m.include?("Errno::EACCES") },
      @logger.messages.inspect)
  end

  # --- upload_to_youtube guards ---

  def test_youtube_skipped_when_not_enabled
    uploads = build_uploads(youtube_enabled: false)

    uploads.upload_to_youtube(episode: {title: "T"}, base_name: "ep", output_path: "/tmp/a.mp3")

    assert(@logger.messages.any? { |m| m.include?("YouTube not configured") })
    assert_empty uploads.warnings
  end

  def test_youtube_missing_cover_is_skippable_warning
    uploads = build_uploads_with_youtube

    # No cover file exists for the episode → video generation cannot run;
    # per the error-severity policy this is a named, skippable warning.
    uploads.upload_to_youtube(episode: {title: "T"}, base_name: "ep", output_path: "/tmp/a.mp3")

    assert_equal 1, uploads.warnings.size
    assert_includes uploads.warnings.first, "YouTube upload failed"
    assert_includes uploads.warnings.first, "No episode cover"
  end

  # P4-0: the upload is recorded right after upload_video succeeds, so a
  # captions failure stays a non-fatal warning without leaving the uploaded
  # video untracked (which made the next publish --youtube upload it again).
  def test_upload_to_youtube_captions_failure_still_records_upload
    base = "ep-2026-03-10"
    # P4-8: the shared routine builds via VideoBuilder, which needs real audio.
    mp3 = File.join(@episodes_dir, "#{base}.mp3")
    File.write(mp3, "x" * 100)
    File.write(File.join(@episodes_dir, "#{base}_cover.jpg"), "jpg")
    File.write(File.join(@episodes_dir, "#{base}_timestamps.json"), "{}")
    uploads = build_uploads_with_youtube
    uploader = Object.new
    uploader.define_singleton_method(:authorize!) {}
    uploader.define_singleton_method(:upload_video) { |_path, **| "vid_c" }
    uploader.define_singleton_method(:upload_captions) { |*, **| raise "captions boom" }
    video_gen = Object.new
    video_gen.define_singleton_method(:generate) { |_a, _i, out| File.write(out, "mp4") && out }
    srt = ->(_ts, out) { File.write(out, "1\n") }

    SubtitleGenerator.stub(:generate_srt, srt) do
      VideoGenerator.stub(:new, ->(**) { video_gen }) do
        YouTubeUploader.stub(:new, ->(**) { uploader }) do
          uploads.upload_to_youtube(episode: {title: "T"}, base_name: base, output_path: mp3)
        end
      end
    end

    data = YAML.load_file(File.join(@tmpdir, "uploads.yml"))
    assert_equal "vid_c", data["youtube"]["default"][base]
    assert_equal ["YouTube upload failed (RuntimeError: captions boom)"], uploads.warnings
    assert_includes @logger.messages,
      "Warning: YouTube upload failed: RuntimeError: captions boom (non-fatal, continuing)"
  end

  # CRPR r2: a lazy refresh failing on a Google 5xx arrives as
  # Google::Auth::AuthorizationError whose message carries the response
  # body; the run log and the warnings (RUN-OUTCOME, notifications) get
  # class names only.
  def test_upload_to_youtube_authorization_error_keeps_response_body_out_of_log_and_warnings
    base = "ep-2026-03-10"
    mp3 = File.join(@episodes_dir, "#{base}.mp3")
    File.write(mp3, "x" * 100)
    File.write(File.join(@episodes_dir, "#{base}_cover.jpg"), "jpg")
    File.write(File.join(@episodes_dir, "#{base}.mp4"), "mp4")
    uploads = build_uploads_with_youtube
    error = begin
      raise Signet::RemoteServerError, "Remote server error.  Server message:\nSECRET-BODY-LINE"
    rescue => cause
      begin
        raise Google::Auth::AuthorizationError, "Unexpected error: #{cause.inspect}"
      rescue => wrapped
        wrapped
      end
    end
    uploader = Object.new
    uploader.define_singleton_method(:upload_video) { |_path, **| raise error }
    video_gen = Object.new
    video_gen.define_singleton_method(:generate) { |_a, _i, out| File.write(out, "mp4") && out }

    VideoGenerator.stub(:new, ->(**) { video_gen }) do
      YouTubeUploader.stub(:new, ->(**) { uploader }) do
        uploads.upload_to_youtube(episode: {title: "T"}, base_name: base, output_path: mp3)
      end
    end

    refute(@logger.messages.any? { |m| m.include?("SECRET-BODY-LINE") }, @logger.messages.inspect)
    refute(uploads.warnings.any? { |w| w.include?("SECRET-BODY-LINE") }, uploads.warnings.inspect)
    assert_equal ["YouTube upload failed (Google::Auth::AuthorizationError (cause Signet::RemoteServerError))"],
      uploads.warnings
  end

  # P4-8: the pipeline delegates to the publisher's one per-episode routine,
  # passing its in-memory metadata and marking its fresh timestamps
  # authoritative (no re-transcription, no second reconcile).
  def test_upload_to_youtube_delegates_to_publisher_upload_episode
    base = "ep-2026-03-10"
    mp3 = File.join(@episodes_dir, "#{base}.mp3")
    uploads = build_uploads_with_youtube
    seen = nil
    fake = Object.new
    fake.define_singleton_method(:upload_episode) do |ep, **kw|
      seen = [ep, kw]
      YouTubePublisher::EpisodeResult.new(status: :uploaded, base: base, video_id: "vid_d", attempted: true)
    end

    YouTubePublisher.stub(:new, ->(**) { fake }) do
      uploads.upload_to_youtube(episode: {title: "T", description: "D"}, base_name: base, output_path: mp3)
    end

    ep, kw = seen
    assert_equal({base_name: base, mp3_path: mp3,
                  transcript_path: File.join(@episodes_dir, "#{base}_transcript.md")}, ep)
    assert_equal({metadata: {title: "T", description: "D"}, timestamps_authoritative: true}, kw)
    assert_empty uploads.warnings
    assert_includes @logger.messages, "Recorded YouTube upload: #{base} → vid_d"
  end

  def test_upload_to_youtube_reuses_existing_mp4
    base = "ep-2026-03-10"
    mp3 = File.join(@episodes_dir, "#{base}.mp3")
    File.write(mp3, "x" * 100)
    File.write(File.join(@episodes_dir, "#{base}_cover.jpg"), "jpg")
    File.write(File.join(@episodes_dir, "#{base}.mp4"), "mp4")
    uploads = build_uploads_with_youtube
    uploaded = []
    uploader = Object.new
    uploader.define_singleton_method(:upload_video) { |path, **| (uploaded << path) && "vid_r" }

    VideoGenerator.stub(:new, ->(**) { flunk "existing mp4 was regenerated" }) do
      YouTubeUploader.stub(:new, ->(**) { uploader }) do
        uploads.upload_to_youtube(episode: {title: "T"}, base_name: base, output_path: mp3)
      end
    end

    assert_equal [File.join(@episodes_dir, "#{base}.mp4")], uploaded
    assert_empty uploads.warnings
  end

  private

  def build_uploads(lingq_enabled: true, youtube_enabled: false, dry_run: false)
    config = UploadsStubConfig.new(
      episodes_dir: @episodes_dir,
      lingq_config: {collection: 12345, token: "tok"},
      lingq_enabled: lingq_enabled,
      youtube_enabled: youtube_enabled,
      transcription_language: "sl"
    )
    PostPipelineUploads.new(config: config, logger: @logger, dry_run: dry_run)
  end

  def build_uploads_with_youtube
    config = UploadsStubConfig.new(
      episodes_dir: @episodes_dir,
      lingq_config: nil,
      lingq_enabled: false,
      youtube_enabled: true,
      transcription_language: "sl"
    )
    config.define_singleton_method(:youtube_config) { {} }
    PostPipelineUploads.new(config: config, logger: @logger, dry_run: false)
  end
end
