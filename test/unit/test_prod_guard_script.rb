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

  def test_bash_mutating_stash_forms_while_active_yields
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

  # CRPR Gate 2 round 4: xargs/sudo with options, compound command
  # positions, unlisted tree- or branch-rewriting git subcommands, and the
  # probe shapes that had no pinned test.
  def test_bash_xargs_with_options_rm_under_lib_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "find /tmp -name x | xargs -0 rm lib/x.rb"})

    assert_equal 2, code
  end

  def test_bash_rm_after_then_while_active_yields
    hold_lock
    code, _err = run_guard("Bash", {command: "if [ -f lib/x ]; then rm lib/x.rb; fi"})

    assert_equal 2, code
  end

  def test_bash_git_tree_rewriting_subcommands_while_active_yields
    hold_lock
    codes = ["git apply /tmp/p.diff", "git clean -fd lib/", "git branch -f phase-2 HEAD~1", "git commit --amend --no-edit"].map { |c| run_guard("Bash", {command: c}).first }

    assert_equal [2, 2, 2, 2], codes
  end

  def test_bash_git_update_ref_reviewed_marker_while_active_allowed
    hold_lock
    code, _err = run_guard("Bash", {command: "git update-ref refs/cr/reviewed HEAD"})

    assert_equal 0, code
  end

  def test_bash_readonly_stash_with_global_option_while_active_allowed
    hold_lock
    code, _err = run_guard("Bash", {command: "git --no-pager stash list"})

    assert_equal 0, code
  end

  def test_bash_probe_shapes_while_active_yields
    hold_lock
    codes = ["/bin/rm lib/x.rb", "echo $(rm lib/x.rb)", "tee /tmp/a lib/x.rb", "git -P reset --hard", "git stash show; git stash drop", "echo x >| lib/x.rb"].map { |c| run_guard("Bash", {command: c}).first }

    assert_equal [2, 2, 2, 2, 2, 2], codes
  end

  # CRPR Gate 2 round 5: heredoc bodies (commit messages) are not scanned;
  # ordinary loop commands stay allowed; more tree/branch rewrites block.
  def test_bash_commit_heredoc_mentioning_guarded_words_while_active_allowed
    hold_lock
    msg = "git commit -q -F - <<'EOF'\nfix: guard covers git apply, rm lib/x\n\nbranch -f and commit --amend now block.\nEOF"
    code, _err = run_guard("Bash", {command: msg})

    assert_equal 0, code
  end

  def test_bash_ordinary_loop_commands_while_active_allowed
    hold_lock
    cmds = [
      "bundle exec rake gate > log 2>&1; echo exit=$?",
      "git branch --show-current",
      "git cherry 6d869e4 origin/phase-1",
      "ruby -e 'p({\"a\" => \"lib/x\"})'",
      "echo pseudo rm lib/x.rb",
      "sed -n '1,5p' lib/x.rb"
    ]
    codes = cmds.map { |c| run_guard("Bash", {command: c}).first }

    assert_equal [0, 0, 0, 0, 0, 0], codes
  end

  def test_bash_more_tree_and_branch_rewrites_while_active_yields
    hold_lock
    cmds = [
      "git revert --no-edit HEAD~1",
      "git branch --delete phase-2",
      "git update-ref HEAD HEAD~1",
      "git update-ref -d refs/heads/x",
      "git am /tmp/x.mbox",
      "git checkout-index -f -a",
      "sed -E -i '' 's/a/b/' lib/x.rb",
      "X=1 rm lib/x.rb",
      "{ rm lib/x.rb; }",
      "/usr/bin/tee lib/x.rb",
      "env FOO=1 rm lib/x.rb"
    ]
    codes = cmds.map { |c| run_guard("Bash", {command: c}).first }

    assert_equal Array.new(cmds.size, 2), codes
  end

  def test_no_output_dir_allowed
    FileUtils.rm_rf(File.join(@cwd, "output"))
    code, _err = run_guard("Bash", {command: "git merge x"}, now: INSIDE_WINDOW)

    assert_equal 0, code
  end
end
