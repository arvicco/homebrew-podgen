# frozen_string_literal: true

require_relative "../test_helper"
require "cli/unpublish_command"

class TestUnpublishCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_unpublish_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    FileUtils.mkdir_p(@podcast_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"), "# Test\n## Format\nfoo\n## Tone\nbar")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  def test_unpublish_no_podcast_returns_usage
    _, err = capture_io do
      code = PodgenCLI::UnpublishCommand.new([], {}).run
      assert_equal 2, code
    end
    assert_includes err, "Usage:"
  end

  def test_unpublish_missing_env_returns_error
    %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].each { |k| ENV.delete(k) }

    _, err = capture_io do
      code = PodgenCLI::UnpublishCommand.new(["testpod"], {}).run
      assert_equal 2, code
    end
    assert_includes err, "Missing"
  end

  def test_unpublish_builds_correct_rclone_command
    %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].each { |k| ENV[k] ||= "test-#{k}" }

    cmd = PodgenCLI::UnpublishCommand.new(["testpod"], dry_run: true)
    captured_args = nil

    cmd.define_singleton_method(:rclone_available?) { true }
    cmd.define_singleton_method(:run_rclone) do |args, **_|
      captured_args = args
      true
    end

    out, = capture_io { cmd.run }

    assert captured_args.include?("purge")
    assert captured_args.any? { |a| a.include?("testpod/") }
    assert captured_args.include?("--dry-run")
    assert_includes out, "dry-run"
  ensure
    %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].each { |k| ENV.delete(k) if ENV[k]&.start_with?("test-") }
  end

  # --- YouTube unpublish ---

  def test_unpublish_youtube_deletes_tracked_videos
    output_dir = File.join(@tmpdir, "output", "testpod")
    episodes_dir = File.join(output_dir, "episodes")
    FileUtils.mkdir_p(episodes_dir)

    tracker_path = File.join(output_dir, "uploads.yml")
    File.write(tracker_path, {
      "youtube" => {
        "PLtest123" => {
          "ep-2026-01-15" => "vid_aaa",
          "ep-2026-01-16" => "vid_bbb"
        }
      }
    }.to_yaml)

    cmd = PodgenCLI::UnpublishCommand.new(["testpod"], youtube: true)
    deleted_ids = []
    removed_from_playlist = []

    # Stub YouTubeUploader
    stub_uploader = Object.new
    stub_uploader.define_singleton_method(:authorize!) { nil }
    stub_uploader.define_singleton_method(:delete_video) { |id| deleted_ids << id; true }
    stub_uploader.define_singleton_method(:remove_from_playlist) { |vid, pl| removed_from_playlist << [vid, pl]; true }

    cmd.define_singleton_method(:build_youtube_uploader) { stub_uploader }

    out, = capture_io { code = cmd.run; assert_equal 0, code }

    assert_includes deleted_ids, "vid_aaa"
    assert_includes deleted_ids, "vid_bbb"
    assert_includes removed_from_playlist, ["vid_aaa", "PLtest123"]
    assert_includes removed_from_playlist, ["vid_bbb", "PLtest123"]
    assert_includes out, "vid_aaa"
    assert_includes out, "vid_bbb"

    # Tracker should be cleared
    data = YAML.load_file(tracker_path)
    youtube_entries = data.dig("youtube", "PLtest123") || {}
    assert_empty youtube_entries
  end

  def test_unpublish_youtube_dry_run_does_not_delete
    output_dir = File.join(@tmpdir, "output", "testpod")
    episodes_dir = File.join(output_dir, "episodes")
    FileUtils.mkdir_p(episodes_dir)

    tracker_path = File.join(output_dir, "uploads.yml")
    File.write(tracker_path, {
      "youtube" => {
        "PLtest123" => { "ep-2026-01-15" => "vid_aaa" }
      }
    }.to_yaml)

    cmd = PodgenCLI::UnpublishCommand.new(["testpod"], youtube: true, dry_run: true)

    out, = capture_io { code = cmd.run; assert_equal 0, code }

    assert_includes out, "would delete"
    assert_includes out, "vid_aaa"

    # Tracker should be unchanged
    data = YAML.load_file(tracker_path)
    assert_equal "vid_aaa", data.dig("youtube", "PLtest123", "ep-2026-01-15")
  end

  def test_unpublish_youtube_no_tracked_videos
    output_dir = File.join(@tmpdir, "output", "testpod")
    episodes_dir = File.join(output_dir, "episodes")
    FileUtils.mkdir_p(episodes_dir)

    cmd = PodgenCLI::UnpublishCommand.new(["testpod"], youtube: true)

    out, = capture_io { code = cmd.run; assert_equal 0, code }

    assert_includes out, "No YouTube videos"
  end
end
