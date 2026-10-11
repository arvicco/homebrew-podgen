# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"

# P2-0: scripts/prod_guard.sh — PreToolUse hook that blocks code edits and
# branch moves while a production generate holds its run lock.
class TestProdGuardScript < Minitest::Test
  SCRIPT = File.expand_path("../../scripts/prod_guard.sh", __dir__)
  OUTSIDE_WINDOW = "2026-10-11T12:00:00"
  INSIDE_WINDOW = "2026-10-11T16:40:00"

  def setup
    skip "jq missing" unless system("command -v jq >/dev/null 2>&1")
    @cwd = Dir.mktmpdir("prod_guard_test")
    @lock = File.join(@cwd, "output", "podx", "run.lock")
    FileUtils.mkdir_p(File.dirname(@lock))
    File.write(@lock, "")
    @holder = nil
  end

  def teardown
    release_lock
    FileUtils.rm_rf(@cwd)
  end

  # Held by a forked child: an in-process thread doesn't contend on macOS.
  def hold_lock
    reader, writer = IO.pipe
    @holder = fork do
      reader.close
      f = File.open(@lock, File::RDWR)
      f.flock(File::LOCK_EX)
      writer.write("1")
      writer.close
      sleep 30
    end
    writer.close
    reader.read(1)
    reader.close
  end

  def release_lock
    return unless @holder
    Process.kill(:KILL, @holder)
    Process.wait(@holder)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @holder = nil
  end

  def run_guard(tool, input, now: OUTSIDE_WINDOW)
    payload = JSON.generate(tool_name: tool, tool_input: input, cwd: @cwd)
    _out, err, status = Open3.capture3({"PROD_GUARD_NOW" => now}, SCRIPT, stdin_data: payload)
    [status.exitstatus, err]
  end

  def test_edit_under_lib_while_active_yields
    hold_lock
    code, err = run_guard("Edit", {file_path: File.join(@cwd, "lib", "x.rb")})

    assert_equal 2, code
    assert_includes err, "YIELD"
    assert_includes err, "podx"
  end

  def test_edit_under_lib_while_free_allowed
    code, _err = run_guard("Edit", {file_path: File.join(@cwd, "lib", "x.rb")})

    assert_equal 0, code
  end

  def test_write_under_lib_inside_window_yields
    code, err = run_guard("Write", {file_path: File.join(@cwd, "lib", "x.rb")}, now: INSIDE_WINDOW)

    assert_equal 2, code
    assert_includes err, "launchd window"
  end

  def test_edit_under_docs_while_active_allowed
    hold_lock
    code, _err = run_guard("Edit", {file_path: File.join(@cwd, "docs", "BACKLOG.md")})

    assert_equal 0, code
  end

  def test_bash_git_merge_while_active_yields
    hold_lock
    code, err = run_guard("Bash", {command: "git merge x"})

    assert_equal 2, code
    assert_includes err, "YIELD"
  end

  def test_bash_write_into_lib_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "sed -i '' 's/a/b/' lib/x.rb"})

    assert_equal 2, code
  end

  def test_bash_ls_while_active_allowed
    hold_lock
    code, _err = run_guard("Bash", {command: "ls"})

    assert_equal 0, code
  end

  # CRPR Gate 2 W3: branch moves the first pattern missed.
  def test_bash_git_reset_hard_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "git reset --hard HEAD~1"})

    assert_equal 2, code
  end

  def test_bash_git_dash_c_switch_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "git -C /some/dir switch phase-3"})

    assert_equal 2, code
  end

  def test_bash_tee_into_lib_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "echo x | tee lib/x.rb"})

    assert_equal 2, code
  end

  # CRPR Gate 2 NIT 4: read-only work that merely mentions lib/ stays allowed.
  def test_bash_readonly_redirect_mentioning_lib_while_active_allowed
    hold_lock
    code, _err = run_guard("Bash", {command: "grep -rn foo lib/ > /tmp/out 2>/dev/null"})

    assert_equal 0, code
  end

  def test_bash_scp_and_git_stash_list_while_active_allowed
    hold_lock
    code1, _ = run_guard("Bash", {command: "scp lib/x.rb host:/tmp/"})
    code2, _ = run_guard("Bash", {command: "git stash list"})

    assert_equal 0, code1
    assert_equal 0, code2
  end

  def test_edit_under_dot_claude_while_active_yields
    hold_lock
    code, _err = run_guard("Edit", {file_path: File.join(@cwd, ".claude", "settings.json")})

    assert_equal 2, code
  end

  # CRPR Gate 2 NIT 9: the guard fails OPEN on malformed input.
  def test_malformed_json_allowed
    _out, _err, status = Open3.capture3({"PROD_GUARD_NOW" => OUTSIDE_WINDOW}, SCRIPT, stdin_data: "not json")

    assert_equal 0, status.exitstatus
  end

  def test_bad_now_override_allowed
    hold_lock
    code, _err = run_guard("Edit", {file_path: File.join(@cwd, "lib", "x.rb")}, now: "yesterday-ish")

    assert_equal 0, code
  end

  # CRPR Gate 2 round 2 W1: writes through an absolute path (the loop writes
  # heredocs with absolute paths) and tee at command start.
  def test_bash_heredoc_to_absolute_lib_path_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "cat > /Users/vb/Dev/podgen/lib/x.rb <<'EOF'\nputs 1\nEOF"})

    assert_equal 2, code
  end

  def test_bash_tee_at_command_start_into_lib_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "tee -a lib/x.rb < /tmp/in"})

    assert_equal 2, code
  end

  # CRPR Gate 2 round 2 W2: a read-only stash subcommand must not exempt the
  # rest of the command line.
  def test_bash_reset_followed_by_stash_list_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "git reset --hard HEAD~1; git stash list"})

    assert_equal 2, code
  end

  def test_bash_git_dash_c_option_checkout_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "git -c core.hooksPath=/dev/null checkout phase-3"})

    assert_equal 2, code
  end

  # CRPR Gate 2 round 3: rm/mv/cp reached through git, xargs, leading
  # whitespace; mutating stash forms; tee long options; git global options.
  def test_bash_git_rm_under_lib_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "git rm lib/x.rb"})

    assert_equal 2, code
  end

  def test_bash_leading_space_rm_under_lib_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "  rm lib/x.rb"})

    assert_equal 2, code
  end

  def test_bash_mutating_stash_forms_while_active_yield
    hold_lock
    code1, _ = run_guard("Bash", {command: "git stash pop"})
    code2, _ = run_guard("Bash", {command: "git stash -u; git stash list"})

    assert_equal 2, code1
    assert_equal 2, code2
  end

  def test_bash_tee_long_option_into_lib_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "tee --append lib/x.rb < /tmp/in"})

    assert_equal 2, code
  end

  def test_bash_git_global_option_checkout_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "git --no-pager checkout phase-3"})

    assert_equal 2, code
  end

  def test_bash_grep_for_rm_in_lib_while_active_allowed
    hold_lock
    code, _err = run_guard("Bash", {command: "grep -rn rm lib/"})

    assert_equal 0, code
  end

  def test_no_output_dir_allowed
    FileUtils.rm_rf(File.join(@cwd, "output"))
    code, _err = run_guard("Bash", {command: "git merge x"}, now: INSIDE_WINDOW)

    assert_equal 0, code
  end
end
