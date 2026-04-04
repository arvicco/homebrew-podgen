# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "stringio"
require "cli"
require "cli/schedule_command"

class TestScheduleCommand < Minitest::Test
  TEST_LABEL = "com.podcastagent.test_pod"
  TEST_PLIST = File.join(Dir.home, "Library", "LaunchAgents", "#{TEST_LABEL}.plist")

  def setup
    @tmpdir = Dir.mktmpdir("podgen_sched_test")
    build_test_podcast(@tmpdir)
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
    cleanup_launchd
  end

  def cleanup_launchd
    system("launchctl", "unload", TEST_PLIST, err: File::NULL, out: File::NULL)
    File.delete(TEST_PLIST) if File.exist?(TEST_PLIST)
  end

  # ── Defaults ──

  def test_defaults_to_six_am
    cmd = PodgenCLI::ScheduleCommand.new(["test_pod"], {})
    assert_equal 6, cmd.hour
    assert_equal 0, cmd.minute
  end

  # ── --time parsing ──

  def test_accepts_time_flag
    cmd = PodgenCLI::ScheduleCommand.new(["--time", "18:00", "test_pod"], {})
    assert_equal 18, cmd.hour
    assert_equal 0, cmd.minute
  end

  def test_accepts_time_with_minutes
    cmd = PodgenCLI::ScheduleCommand.new(["--time", "09:30", "test_pod"], {})
    assert_equal 9, cmd.hour
    assert_equal 30, cmd.minute
  end

  def test_rejects_invalid_time_format
    code, _, err = run_cli("schedule", "test_pod", "--time", "abc")
    assert_equal 1, code
    assert_includes err, "Invalid time format"
  end

  def test_rejects_hour_above_23
    code, _, err = run_cli("schedule", "test_pod", "--time", "25:00")
    assert_equal 1, code
    assert_includes err, "Invalid time format"
  end

  def test_rejects_minute_above_59
    code, _, err = run_cli("schedule", "test_pod", "--time", "12:60")
    assert_equal 1, code
    assert_includes err, "Invalid time format"
  end

  # ── --publish / --telegram flags ──

  def test_accepts_publish_flag
    cmd = PodgenCLI::ScheduleCommand.new(["--publish", "test_pod"], {})
    assert cmd.publish?
  end

  def test_accepts_telegram_flag
    cmd = PodgenCLI::ScheduleCommand.new(["--telegram", "test_pod"], {})
    assert cmd.telegram?
  end

  def test_accepts_all_flags_combined
    cmd = PodgenCLI::ScheduleCommand.new(["--time", "18:00", "--publish", "--telegram", "test_pod"], {})
    assert_equal 18, cmd.hour
    assert_equal 0, cmd.minute
    assert cmd.publish?
    assert cmd.telegram?
  end

  def test_publish_defaults_to_false
    cmd = PodgenCLI::ScheduleCommand.new(["test_pod"], {})
    refute cmd.publish?
  end

  def test_telegram_defaults_to_false
    cmd = PodgenCLI::ScheduleCommand.new(["test_pod"], {})
    refute cmd.telegram?
  end

  # ── Installer argument building ──

  def test_installer_args_default
    cmd = PodgenCLI::ScheduleCommand.new(["test_pod"], {})
    args = cmd.installer_args
    assert_equal ["test_pod", "6", "0"], args
  end

  def test_installer_args_with_all_flags
    cmd = PodgenCLI::ScheduleCommand.new(["--time", "18:30", "--publish", "--telegram", "test_pod"], {})
    args = cmd.installer_args
    assert_equal ["test_pod", "18", "30", "--publish", "--telegram"], args
  end

  def test_installer_args_publish_only
    cmd = PodgenCLI::ScheduleCommand.new(["--publish", "test_pod"], {})
    args = cmd.installer_args
    assert_equal ["test_pod", "6", "0", "--publish"], args
  end

  # ── --test flag ──

  def test_accepts_test_flag
    cmd = PodgenCLI::ScheduleCommand.new(["--test", "test_pod"], {})
    assert cmd.test?
  end

  def test_test_defaults_to_false
    cmd = PodgenCLI::ScheduleCommand.new(["test_pod"], {})
    refute cmd.test?
  end

  def test_test_fails_without_telegram_env
    ENV.delete("TELEGRAM_BOT_TOKEN")
    ENV.delete("TELEGRAM_CHAT_ID")
    code, _, err = run_cli("schedule", "test_pod", "--test")
    assert_equal 1, code
    assert_includes err, "TELEGRAM_BOT_TOKEN"
  end

  # ── Validation via run ──

  def test_requires_podcast_name
    code, _, err = run_cli("schedule")
    assert_equal 2, code
    assert_includes err, "Usage:"
  end

  def test_rejects_unknown_podcast
    code, _, err = run_cli("schedule", "nonexistent")
    assert_equal 2, code
    assert_includes err, "Unknown podcast"
  end

  def test_rejects_unknown_option
    code, _, err = run_cli("schedule", "test_pod", "--bogus")
    assert_equal 2, code
    assert_includes err, "invalid option"
  end

  private

  def run_cli(*args)
    old_stdout, old_stderr = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    code = PodgenCLI.run(args.flatten)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  def build_test_podcast(dir)
    pod = File.join(dir, "podcasts", "test_pod")
    out = File.join(dir, "output", "test_pod", "episodes")
    FileUtils.mkdir_p([pod, out])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      ## Podcast
      - name: Test Pod
      - type: news

      ## Format
      - Short episodes

      ## Tone
      Casual.

      ## Topics
      - Testing
    MD

    File.write(File.join(pod, "queue.yml"), YAML.dump("topics" => ["testing"]))
  end
end
