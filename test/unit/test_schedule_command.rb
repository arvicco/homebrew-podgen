# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "stringio"
require "tempfile"
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

  # ── decode_wait_status ──

  def test_decode_wait_status_nil_returns_nil
    assert_nil PodgenCLI::ScheduleCommand.decode_wait_status(nil)
  end

  def test_decode_wait_status_zero_returns_zero
    assert_equal 0, PodgenCLI::ScheduleCommand.decode_wait_status(0)
  end

  def test_decode_wait_status_256_means_exit_1
    assert_equal 1, PodgenCLI::ScheduleCommand.decode_wait_status(256)
  end

  def test_decode_wait_status_1792_means_exit_7
    assert_equal 7, PodgenCLI::ScheduleCommand.decode_wait_status(1792)
  end

  def test_decode_wait_status_low_byte_means_signal
    # POSIX wait status: low byte nonzero indicates signal kill (SIGKILL=9).
    assert_equal "killed (signal 9)", PodgenCLI::ScheduleCommand.decode_wait_status(9)
  end

  def test_decode_wait_status_negative_means_legacy_signal
    # macOS launchctl historically reports negative values for signal kills.
    assert_equal "killed (signal 15)", PodgenCLI::ScheduleCommand.decode_wait_status(-15)
  end

  # ── show_status decoded display ──

  def test_status_displays_decoded_exit_code_from_raw_256
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "test_pod"], {})
    launchctl_out = %({\t"PID" = 12345;\n\t"LastExitStatus" = 256;\n};\n)
    real_log = Tempfile.new("podgen_log").path
    out_io = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 6 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, real_log do
            cmd.stub :launchctl_list_output, launchctl_out do
              out_io, = capture_io { cmd.run }
            end
          end
        end
      end
    end
    assert_match(/last exit code:\s+1\b/, out_io)
    refute_match(/last exit code:\s+256\b/, out_io)
  end

  def test_status_displays_signal_kill_from_negative_status
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "test_pod"], {})
    launchctl_out = %({\t"LastExitStatus" = -15;\n};\n)
    real_log = Tempfile.new("podgen_log").path
    out_io = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 6 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, real_log do
            cmd.stub :launchctl_list_output, launchctl_out do
              out_io, = capture_io { cmd.run }
            end
          end
        end
      end
    end
    assert_match(/last exit code:\s+killed \(signal 15\)/, out_io)
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

  def test_remove_requires_podcast_name
    code, _, err = run_cli("schedule", "--remove")
    assert_equal 2, code
    assert_includes err, "Usage:"
    assert_includes err, "--remove"
  end

  def test_status_requires_podcast_name
    code, _, err = run_cli("schedule", "--status")
    assert_equal 2, code
    assert_includes err, "Usage:"
    assert_includes err, "--status"
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
    real_log = Tempfile.new("podgen_log").path
    out_io = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 6 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, real_log do
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

  # ── --uploads mode ──

  def test_yt_batch_flag_parses_pod_list
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a,pod_b"], {})
    assert cmd.instance_variable_get(:@uploads)
    assert_equal "pod_a,pod_b", cmd.instance_variable_get(:@uploads_pods)
  end

  def test_yt_batch_mode_default_priority
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a"], {})
    assert_equal :priority, cmd.instance_variable_get(:@uploads_mode)
  end

  def test_yt_batch_parses_mode_round_robin
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a,pod_b", "--mode", "round-robin"], {})
    assert_equal :round_robin, cmd.instance_variable_get(:@uploads_mode)
  end

  def test_yt_batch_label_uses_singleton_name
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a"], {})
    assert_equal "com.podcastagent.uploads", cmd.send(:label)
  end

  def test_yt_batch_per_pod_label_unchanged_when_no_batch_flag
    cmd = PodgenCLI::ScheduleCommand.new(["pod_a"], {})
    assert_equal "com.podcastagent.pod_a", cmd.send(:label)
  end

  def test_yt_batch_install_writes_plist_with_pods_mode_and_time
    cmd = PodgenCLI::ScheduleCommand.new(
      ["--uploads", "pod_a,pod_b", "--time", "14:30", "--mode", "round-robin"],
      {}
    )
    plist = cmd.send(:build_uploads_plist)
    assert_match(/<string>com\.podcastagent\.uploads<\/string>/, plist)
    assert_match(/<string>pod_a,pod_b<\/string>/, plist)
    assert_match(/<string>round-robin<\/string>/, plist)
    assert_match(/<integer>14<\/integer>/, plist)
    assert_match(/<integer>30<\/integer>/, plist)
    assert_match(/run_uploads\.sh/, plist)
  end

  def test_yt_batch_plist_includes_max_when_given
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a", "--max", "6"], {})
    plist = cmd.send(:build_uploads_plist)
    assert_match(/<string>--max<\/string>\s*<string>6<\/string>/m, plist)
  end

  def test_yt_batch_plist_omits_max_when_absent
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a"], {})
    plist = cmd.send(:build_uploads_plist)
    refute_match(/<string>--max<\/string>/, plist)
  end

  def test_yt_batch_parses_max_flag
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a", "--max", "4"], {})
    assert_equal 4, cmd.instance_variable_get(:@max)
  end

  def test_yt_batch_plist_uses_dedicated_log_path
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a"], {})
    plist = cmd.send(:build_uploads_plist)
    # Must NOT share the per-pod scheduler's log file, else status mtime is misleading.
    assert_match(/uploads_stdout\.log/, plist)
    assert_match(/uploads_stderr\.log/, plist)
    refute_match(%r{/launchd_stdout\.log}, plist)
  end

  def test_status_reports_never_run_when_log_missing
    # When job has been scheduled but never run, launchctl reports LastExitStatus=0
    # by default. Without a log file, we should treat it as never-run rather than
    # claiming a successful run.
    cmd = PodgenCLI::ScheduleCommand.new(["--status", "test_pod"], {})
    out = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 6 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, "/this/path/does/not/exist.log" do
            cmd.stub :launchctl_list_output, %({\t"LastExitStatus" = 0;};\n) do
              out, = capture_io { cmd.run }
            end
          end
        end
      end
    end
    assert_match(/last run:\s+never/, out)
    assert_match(/last exit code:\s+n\/a/, out)
  end

  def test_yt_batch_install_rejects_missing_pods
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads"], {})
    code = nil
    _, err = capture_io { code = cmd.run }
    assert_equal 2, code
    assert_includes err, "uploads"
  end

  def test_yt_batch_install_rejects_invalid_pod_names
    # Pod name with XML metacharacters would corrupt the plist.
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a,bad<name>"], {})
    code = nil
    _, err = capture_io { code = cmd.run }
    assert_equal 2, code
    assert_match(/invalid pod name/i, err)
  end

  def test_yt_batch_install_warns_on_launchctl_load_failure
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "pod_a"], {})
    err_out = nil
    cmd.stub :do_launchctl_unload, true do
      cmd.stub :do_launchctl_load, false do
        FileUtils.stub :mkdir_p, true do
          File.stub :write, true do
            File.stub :exist?, false do
              _, err_out = capture_io { cmd.run }
            end
          end
        end
      end
    end
    assert_match(/launchctl load.*fail/i, err_out)
  end

  def test_yt_batch_status_no_install
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "--status"], {})
    out = nil
    cmd.stub :plist_exists?, false do
      out, = capture_io { @code = cmd.run }
    end
    assert_equal 0, @code
    assert_match(/no scheduler installed/i, out)
  end

  def test_yt_batch_status_header_uses_youtube_batch_label
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "--status"], {})
    out = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 14 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, "/nonexistent.log" do
            cmd.stub :plist_program_arguments, ["/bin/bash", "x", "pod_a", "--mode", "priority"] do
              cmd.stub :launchctl_list_output, %({\t"LastExitStatus" = 0;};\n) do
                out, = capture_io { cmd.run }
              end
            end
          end
        end
      end
    end
    refute_match(/^:\s*$/, out, "status header must not be a bare colon")
    assert_match(/^uploads:/, out)
  end

  def test_yt_batch_status_shows_podcasts_mode_no_max
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "--status"], {})
    out = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 10 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, "/nonexistent.log" do
            cmd.stub :plist_program_arguments, ["/bin/bash", "x", "pod_a,pod_b,pod_c", "--mode", "round-robin"] do
              cmd.stub :launchctl_list_output, %({\t"LastExitStatus" = 0;};\n) do
                out, = capture_io { cmd.run }
              end
            end
          end
        end
      end
    end
    assert_match(/podcasts:\s+pod_a, pod_b, pod_c/, out)
    assert_match(/mode:\s+round-robin \(no max\)/, out)
  end

  def test_yt_batch_status_shows_max_when_set
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "--status"], {})
    out = nil
    cmd.stub :plist_exists?, true do
      cmd.stub :plist_hour, 10 do
        cmd.stub :plist_minute, 0 do
          cmd.stub :plist_log_path, "/nonexistent.log" do
            cmd.stub :plist_program_arguments, ["/bin/bash", "x", "pod_a", "--mode", "priority", "--max", "6"] do
              cmd.stub :launchctl_list_output, %({\t"LastExitStatus" = 0;};\n) do
                out, = capture_io { cmd.run }
              end
            end
          end
        end
      end
    end
    assert_match(/mode:\s+priority \(max 6\)/, out)
  end

  def test_yt_batch_remove_unloads_singleton
    cmd = PodgenCLI::ScheduleCommand.new(["--uploads", "--remove"], {})
    actions = []
    cmd.stub :plist_exists?, true do
      cmd.stub :do_launchctl_unload, ->(*) { actions << :unload; true } do
        cmd.stub :do_plist_delete, ->(*) { actions << :delete } do
          capture_io { @code = cmd.run }
        end
      end
    end
    assert_equal 0, @code
    assert_equal [:unload, :delete], actions
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
