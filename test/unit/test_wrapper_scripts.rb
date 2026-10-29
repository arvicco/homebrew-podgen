# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "cli/status_command"

# P10-6 (I-10): the launchd wrappers hold the Mac awake (caffeinate -is)
# for the job's lifetime, and run plainly where caffeinate is absent. The
# scripts run from a copy in a tmp project dir with stub `bundle` and
# `caffeinate` on a PATH of stubs only: no real podgen, no .env, no HOME.
class TestWrapperScripts < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir("podgen_wrappers")
    FileUtils.mkdir_p(File.join(@dir, "scripts"))
    %w[run.sh run_uploads.sh].each { |s| FileUtils.cp(File.join(ROOT, "scripts", s), File.join(@dir, "scripts", s)) }
    @bin = File.join(@dir, "stubbin")
    FileUtils.mkdir_p(@bin)
    %w[dirname date].each { |tool| File.symlink(`/usr/bin/which #{tool}`.strip, File.join(@bin, tool)) }
    @log = File.join(@dir, "calls.log")
    stub("bundle", %(echo "bundle $* awake=${STUB_AWAKE:-none}" >> "#{@log}"\nexit "${STUB_EXIT:-0}"))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_run_sh_generate_runs_under_caffeinate
    stub_caffeinate
    _out, _err, status = run_script("run.sh", "fiabe")

    assert status.success?
    assert_equal ["bundle exec ruby bin/podgen --quiet generate fiabe awake=-is"], calls
  end

  def test_run_sh_publish_runs_under_caffeinate_too
    stub_caffeinate
    run_script("run.sh", "fiabe", "--publish")

    assert_equal ["bundle exec ruby bin/podgen --quiet generate fiabe awake=-is",
      "bundle exec ruby bin/podgen publish fiabe awake=-is"], calls
  end

  def test_run_sh_without_caffeinate_still_runs
    _out, _err, status = run_script("run.sh", "fiabe")

    assert status.success?
    assert_equal ["bundle exec ruby bin/podgen --quiet generate fiabe awake=none"], calls
  end

  def test_run_sh_keeps_the_generate_exit_code
    stub_caffeinate
    _out, err, status = run_script("run.sh", "fiabe", "--publish", env: {"STUB_EXIT" => "3"})

    assert_equal 3, status.exitstatus
    assert_includes err, "Generate failed with exit code 3"
    assert_equal 1, calls.size, "no publish after a failed generate"
  end

  def test_run_uploads_sh_runs_under_caffeinate_and_keeps_exit_code
    stub_caffeinate
    _out, _err, status = run_script("run_uploads.sh", "bajke,fiabe", "--max", "6", env: {"STUB_EXIT" => "2"})

    assert_equal 2, status.exitstatus
    assert_equal ["bundle exec ruby bin/podgen --quiet uploads bajke,fiabe --max 6 awake=-is"], calls
  end

  def test_run_uploads_sh_without_caffeinate_still_runs
    _out, _err, status = run_script("run_uploads.sh", "bajke")

    assert status.success?
    assert_equal ["bundle exec ruby bin/podgen --quiet uploads bajke awake=none"], calls
  end

  def test_run_uploads_sh_begin_marker_on_stdout_matches_the_status_reader
    out, err, = run_script("run_uploads.sh", "bajke,fiabe")

    marker = out.lines.first.to_s.chomp
    assert_match PodgenCLI::StatusCommand::UPLOAD_MARKER_RE, marker
    assert_includes marker, "podgen uploads bajke,fiabe begin"
    assert_match PodgenCLI::StatusCommand::UPLOAD_MARKER_RE, err.lines.first.to_s, "stderr keeps its marker"
  end

  private

  def stub(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  def stub_caffeinate
    stub("caffeinate", %(export STUB_AWAKE="$1"\nshift\nexec "$@"))
  end

  def run_script(script, *args, env: {})
    full_env = {"PATH" => @bin, "HOME" => @dir}.merge(env)
    Open3.capture3(full_env, "/bin/bash", File.join(@dir, "scripts", script), *args, unsetenv_others: true)
  end

  def calls
    File.exist?(@log) ? File.readlines(@log, chomp: true) : []
  end
end
