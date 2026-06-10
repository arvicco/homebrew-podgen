# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "fileutils"
require "post_pipeline_uploads"

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
