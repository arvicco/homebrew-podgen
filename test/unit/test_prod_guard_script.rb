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

  def test_no_output_dir_allowed
    FileUtils.rm_rf(File.join(@cwd, "output"))
    code, _err = run_guard("Bash", {command: "git merge x"}, now: INSIDE_WINDOW)

    assert_equal 0, code
  end
end
