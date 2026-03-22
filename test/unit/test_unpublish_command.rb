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
end
