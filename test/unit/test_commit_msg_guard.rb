# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require_relative "../../scripts/commit_msg_guard"

# P25-2: scripts/commit_msg_guard.rb (the commit-msg hook) and
# scripts/install_hooks.sh (its installer).
class TestCommitMsgGuard < Minitest::Test
  GUARD = File.expand_path("../../scripts/commit_msg_guard.rb", __dir__)
  INSTALLER = File.expand_path("../../scripts/install_hooks.sh", __dir__)
  TERMS = %w[my_show placeholder-term].freeze

  ACCEPTED = [
    "feat: add a thing (P25-2)\n\nThe body explains why.\n",
    "fix: packet ids P3-14 and P25-2 are fine\n",
    "Merge pull request #26 from someone/phase-25\n\nPhase 25\n",
    "Merge branch 'phase-25'\n",
    "docs: a duration in code `1:20` stays allowed\n",
    "docs: fenced example\n\n```\nffmpeg -ss 0:01:20 -i in.mp3\n```\n",
    "fix: aspect ratio 16:9 and port 127.0.0.1:8080 are not times\n",
    "feat: UTF-8, ISO-8859-2, CI-2 and R2 bucket are not register ids\n",
    "fix: a night run of the morning batch is fine\n",
    "feat: x (P25-2)\n# Please enter the commit message. Q-12 in a comment is dropped\n",
    "feat: x\n# ------------------------ >8 ------------------------\n+ diff line 10:30 UTC Q-12\n",
    "feat: Co-Authored-By a human\n\nCo-Authored-By: Jane Doe <jane@example.com>\n"
  ].freeze

  REFUSED = {
    "fix: closes Q-218\n" => "private register id 'Q-218'",
    "fix: x\n\nSee I-25 for the background.\n" => "private register id 'I-25'",
    "fix: x per R22-03\n" => "private register id 'R22-03'",
    "fix: runs at 16:30 now\n" => "clock time '16:30'",
    "fix: x\n\nlast seen 9:05:12 in the log\n" => "clock time '9:05:12'",
    "fix: x\n\nthe job fires at `09:30 UTC`\n" => "clock time with a zone '09:30 UTC'",
    "fix: fired 15:30 CST\n" => "clock time with a zone '15:30 CST'",
    "fix: x\n\noffset -06:00 in the test\n" => "clock time '06:00'",
    "fix: ran overnight\n" => "day-part 'overnight'",
    "fix: seen This Morning\n" => "day-part 'This Morning'",
    "fix: will rerun tonight\n" => "day-part 'tonight'",
    "fix: done this evening\n" => "day-part 'this evening'",
    "feat: x\n\nCo-Authored-By: Claude Opus <noreply@example.com>\n" => "assistant attribution",
    "feat: x\n\nGenerated with some tool\n" => "assistant attribution",
    "feat: x\n\nClaude-Session: abc\n" => "assistant attribution",
    "feat: new episode of My_Show\n" => "listed term 'my_show'",
    "Merge branch 'placeholder-term-fix'\n" => "listed term 'placeholder-term'"
  }.freeze

  def test_violations_accepted_messages_pass
    ACCEPTED.each do |msg|
      assert_equal [], CommitMsgGuard.violations(msg, terms: TERMS), msg
    end
  end

  def test_violations_refused_messages_name_the_finding
    REFUSED.each do |msg, reason|
      found = CommitMsgGuard.violations(msg, terms: TERMS)
      assert(found.any? { it.start_with?(reason) }, "#{msg.inspect}: #{found.inspect}")
    end
  end

  def test_violations_zoned_time_is_reported_once
    found = CommitMsgGuard.violations("fix: at 10:30 UTC\n")
    assert_equal ["clock time with a zone '10:30 UTC'"], found
  end

  def test_violations_without_term_list_runs_generic_checks_only
    assert_equal [], CommitMsgGuard.violations("feat: new episode of my_show\n")
  end

  def test_load_terms_skips_blank_and_comment_lines
    Tempfile.create("terms") do |f|
      f.write("# private names\n\n  my_show  \nplaceholder-term\n")
      f.flush
      assert_equal TERMS, CommitMsgGuard.load_terms(f.path)
    end
    assert_equal [], CommitMsgGuard.load_terms(File.join(Dir.tmpdir, "no-such-terms-file"))
  end

  def test_terms_path_env_wins_over_repository_file
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".docs"))
      file = File.join(root, ".docs", "public-terms.txt")
      File.write(file, "my_show\n")
      assert_equal "/x/terms.txt", CommitMsgGuard.terms_path(env: {"PODGEN_PUBLIC_TERMS" => "/x/terms.txt"}, roots: [root])
      assert_equal file, CommitMsgGuard.terms_path(env: {}, roots: ["/nonexistent", root])
      assert_nil CommitMsgGuard.terms_path(env: {}, roots: ["/nonexistent"])
    end
  end

  def test_main_exit_status_and_reasons_with_env_term_list
    Dir.mktmpdir do |dir|
      terms = File.join(dir, "terms.txt")
      File.write(terms, "placeholder-term\n")
      ok = File.join(dir, "ok")
      File.write(ok, "feat: fine (P25-2)\n")
      bad = File.join(dir, "bad")
      File.write(bad, "feat: placeholder-term at 16:30\n")
      env = {"PODGEN_PUBLIC_TERMS" => terms}

      _, err, status = Open3.capture3(env, "ruby", GUARD, ok, chdir: dir)
      assert_equal 0, status.exitstatus, err
      _, err, status = Open3.capture3(env, "ruby", GUARD, bad, chdir: dir)
      assert_equal 1, status.exitstatus
      assert_includes err, "listed term 'placeholder-term'"
      assert_includes err, "clock time '16:30'"
    end
  end

  # --- install_hooks.sh, in a throwaway repository ---

  def test_install_hooks_installs_idempotently_and_refuses_a_foreign_hook
    in_tmp_repo do |repo, env|
      hook = File.join(repo, ".git", "hooks", "commit-msg")
      _, err, status = Open3.capture3(env, "sh", INSTALLER, chdir: repo)
      assert status.success?, err
      assert File.executable?(hook)
      first = File.read(hook)
      _, err, status = Open3.capture3(env, "sh", INSTALLER, chdir: repo)
      assert status.success?, err
      assert_equal first, File.read(hook)

      File.write(hook, "#!/bin/sh\nexit 0\n")
      _, err, status = Open3.capture3(env, "sh", INSTALLER, chdir: repo)
      assert_equal 1, status.exitstatus
      assert_includes err, "--force"
      assert_equal "#!/bin/sh\nexit 0\n", File.read(hook)
      _, err, status = Open3.capture3(env, "sh", INSTALLER, "--force", chdir: repo)
      assert status.success?, err
      assert_equal first, File.read(hook)
    end
  end

  def test_install_hooks_from_a_worktree_writes_the_common_hook_that_refuses
    in_tmp_repo do |repo, env|
      git = ->(*args, dir: repo) {
        out, err, status = Open3.capture3(env, "git", *args, chdir: dir)
        assert status.success?, err
        out
      }
      FileUtils.mkdir_p(File.join(repo, "scripts"))
      FileUtils.cp(GUARD, File.join(repo, "scripts", "commit_msg_guard.rb"))
      File.write(File.join(repo, "a.txt"), "a\n")
      git.call("add", ".")
      git.call("commit", "-q", "--no-verify", "-m", "init")
      tree = File.join(File.dirname(repo), "wt")
      git.call("worktree", "add", "-q", tree)

      _, err, status = Open3.capture3(env, "sh", INSTALLER, chdir: tree)
      assert status.success?, err
      assert File.executable?(File.join(repo, ".git", "hooks", "commit-msg"))

      File.write(File.join(tree, "b.txt"), "b\n")
      git.call("add", ".", dir: tree)
      _, err, status = Open3.capture3(env, "git", "commit", "-q", "-m", "fix: closes Q-1", chdir: tree)
      refute status.success?
      assert_includes err, "private register id 'Q-1'"
      git.call("commit", "-q", "-m", "fix: a clean message (P25-2)", dir: tree)
    end
  end

  private

  # A fresh repository under a tmp dir; env clears any GIT_* the gate runs under.
  def in_tmp_repo
    Dir.mktmpdir("hooks_test") do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      env = {"GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "PODGEN_PUBLIC_TERMS" => nil,
             "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.com",
             "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.com",
             "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1"}
      _, err, status = Open3.capture3(env, "git", "init", "-q", "-b", "main", repo)
      assert status.success?, err
      yield repo, env
    end
  end
end
