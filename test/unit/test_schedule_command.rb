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

  # ── --remove / --status flag parsing ──

  def test_accepts_remove_flag
    cmd = PodgenCLI::ScheduleCommand.new(["--remove", "test_pod"], {})
    assert cmd.remove?
  end

  def test_remove_defaults_to_false
    cmd = PodgenCLI::ScheduleCommand.new(["test_pod"], {})
    refute cmd.remove?
  end

  def test_accepts_status_flag
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "test_pod"], {})
    assert cmd.status?
  end

  def test_status_defaults_to_false
    cmd = PodgenCLI::ScheduleCommand.new(["test_pod"], {})
    refute cmd.status?
  end

  # ── Mutual exclusion ──

  def test_remove_and_status_are_mutually_exclusive
    code, _, err = run_cli("schedule", "test_pod", "--remove", "--status")
    assert_equal 1, code
    assert_match(/mutually exclusive/i, err)
  end

  # ── launchctl output parsers (pure) ──

  def test_parse_last_exit_status_zero
    out = %({\t"LastExitStatus" = 0;};\n)
    assert_equal 0, PodgenCLI::ScheduleCommand.parse_last_exit_status(out)
  end

  def test_parse_last_exit_status_nonzero
    out = %({\t"LastExitStatus" = -15;};\n)
    assert_equal(-15, PodgenCLI::ScheduleCommand.parse_last_exit_status(out))
  end

  def test_parse_last_exit_status_missing
    assert_nil PodgenCLI::ScheduleCommand.parse_last_exit_status(%({"Label" = "x";};))
  end

  def test_parse_pid_present
    out = %({\t"PID" = 12345;\n\t"LastExitStatus" = 0;};\n)
    assert_equal 12345, PodgenCLI::ScheduleCommand.parse_pid(out)
  end

  def test_parse_pid_missing
    assert_nil PodgenCLI::ScheduleCommand.parse_pid(%({"Label" = "x";};))
  end

  # ── --remove behavior ──

  def test_remove_reports_when_no_scheduler_installed
    cmd = PodgenCLI::ScheduleCommand.new(["--remove", "test_pod"], {})
    err_io = nil
    code = nil
    cmd.stub :plist_exists?, false do
      _, err_io = capture_io { code = cmd.run }
    end
    assert_equal 1, code
    assert_match(/no scheduler installed/i, err_io)
  end

  def test_remove_unloads_and_deletes_plist
    cmd = PodgenCLI::ScheduleCommand.new(["--remove", "test_pod"], {})
    actions = []
    code = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :do_launchctl_unload, ->(*) { actions << :unload; true } do
        cmd.stub :do_plist_delete, ->(*) { actions << :delete } do
          capture_io { code = cmd.run }
        end
      end
    end
    assert_equal 0, code
    assert_equal [:unload, :delete], actions
  end

  def test_remove_does_not_require_podcast_to_exist
    # Podcast dir doesn't exist — --remove should proceed to plist check,
    # not error out with "Unknown podcast".
    cmd = PodgenCLI::ScheduleCommand.new(["--remove", "nonexistent_pod"], {})
    err_io = nil
    cmd.stub :plist_exists?, false do
      _, err_io = capture_io { cmd.run }
    end
    refute_match(/Unknown podcast/, err_io)
  end

  # ── --status behavior ──

  def test_status_reports_not_scheduled_when_plist_missing
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "test_pod"], {})
    out_io = nil
    code = nil
    cmd.stub :plist_exists?, false do
      out_io, = capture_io { code = cmd.run }
    end
    assert_equal 0, code
    assert_match(/no scheduler installed/i, out_io)
  end

  def test_status_does_not_require_podcast_to_exist
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "nonexistent_pod"], {})
    err_io = nil
    cmd.stub :plist_exists?, false do
      _, err_io = capture_io { cmd.run }
    end
    refute_match(/Unknown podcast/, err_io)
  end

  def test_status_reports_running_pid_and_exit_code
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "test_pod"], {})
    launchctl_out = %({\t"Label" = "com.podcastagent.test_pod";\n\t"PID" = 12345;\n\t"LastExitStatus" = 0;\n};\n)
    out_io = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 6 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, "/nonexistent.log" do
            cmd.stub :launchctl_list_output, launchctl_out do
              out_io, = capture_io { cmd.run }
            end
          end
        end
      end
    end
    assert_match(/running:\s+yes \(PID 12345\)/, out_io)
    assert_match(/last exit code:\s+0/, out_io)
    assert_match(/scheduled:\s+06:00 daily/, out_io)
  end

  def test_status_reports_not_loaded_when_launchctl_returns_nil
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "test_pod"], {})
    out_io = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 6 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, "/nonexistent.log" do
            cmd.stub :launchctl_list_output, nil do
              out_io, = capture_io { cmd.run }
            end
          end
        end
      end
    end
    assert_match(/loaded:\s+no/, out_io)
    assert_match(/running:\s+no/, out_io)
    assert_match(/last exit code:\s+n\/a/, out_io)
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
