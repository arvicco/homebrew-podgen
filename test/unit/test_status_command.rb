# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "yaml"
require "cli"
require "cli/status_command"

class TestStatusCommand < Minitest::Test
  TODAY = Date.new(2026, 10, 11)
  JSON_KEYS = %w[podcast verdict newest age_days reasons].sort.freeze

  def setup
    @tmpdir = Dir.mktmpdir("podgen_status")
    @plist_dir = File.join(@tmpdir, "LaunchAgents")
    FileUtils.mkdir_p(@plist_dir)
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- verdicts ---

  def test_run_fresh_podcast_reports_ok_with_exit_zero
    make_pod("alpha", dates: %w[2026-10-07 2026-10-08 2026-10-09 2026-10-10])
    out, code = run_status
    assert_equal 0, code
    assert_match(/alpha\s+OK\s+newest 2026-10-10 \(1d old\)/, out)
  end

  def test_run_stale_podcast_reports_old_with_exit_one
    make_pod("alpha", dates: %w[2026-09-01 2026-09-02 2026-09-03 2026-09-04])
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+OLD\s+.*2026-09-04.*37 days old/, out)
  end

  def test_run_freshness_off_reports_ok_even_when_old
    make_pod("alpha", dates: %w[2025-01-01 2025-01-02 2025-01-03], freshness_off: true)
    out, code = run_status
    assert_equal 0, code
    assert_match(/alpha\s+OK\s+\(freshness off\)/, out)
  end

  def test_run_latest_log_ending_in_error_reports_warn_naming_line
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01] START research",
      "[2026-10-10 06:00:09] ERROR TTS failed: quota exceeded"], mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*ERROR TTS failed: quota exceeded/, out)
  end

  def test_run_warning_line_in_latest_log_reports_warn
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01] Warning: cover missing",
      "[2026-10-10 06:00:09] END done"], mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*Warning: cover missing/, out)
  end

  def test_run_repeated_warning_across_runs_reports_warn_once
    make_pod("alpha", dates: fresh_dates)
    3.times do |i|
      write_log("alpha", "a-2026-10-0#{7 + i}.log",
        ["[2026-10-0#{7 + i} 06:00:01] Warning: Twitter credits depleted (#{402 + i})",
          "[2026-10-0#{7 + i} 06:00:09] END done"], mtime: Time.new(2026, 10, 7 + i, 6))
    end
    out, code = run_status
    assert_equal 1, code
    assert_equal 1, out.scan("credits depleted").size, out
    assert_match(/alpha\s+WARN\s+.*repeated in last 3 runs/, out)
  end

  def test_run_warning_in_only_some_runs_is_not_repeated
    make_pod("alpha", dates: fresh_dates)
    [["07", "all fine"], ["08", "all fine"], ["09", "all fine"]].each do |d, line|
      write_log("alpha", "a-2026-10-#{d}.log", ["[x] #{line}", "[x] END"], mtime: Time.new(2026, 10, d.to_i, 6))
    end
    write_log("alpha", "a-2026-10-06.log", ["[x] Warning: flaky", "[x] END"], mtime: Time.new(2026, 10, 6, 6))
    out, code = run_status
    assert_equal 0, code, out
  end

  def test_run_indented_reviewer_findings_are_not_warnings
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01] Script review",
      "[2026-10-10 06:00:02]   WARNING: [COVERAGE] The research includes CFTC proposals",
      "[2026-10-10 06:00:02]   WARNING: [NATURAL_FLOW] 'First, Meanwhile' reads oddly",
      "[2026-10-10 06:00:09] \u2713 Episode ready"], mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 0, code, out
    assert_match(/alpha\s+OK\s+newest 2026-10-10/, out)
  end

  def test_run_unindented_warning_line_reports_warn
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01]   WARNING: [COVERAGE] minor gap",
      "[2026-10-10 06:00:05] WARNING: Response truncated at max_tokens and salvage failed",
      "[2026-10-10 06:00:09] \u2713 Episode ready"], mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*WARNING: Response truncated at max_tokens/, out)
    refute_includes out, "COVERAGE"
  end

  def test_run_repeated_agent_warning_across_runs_reports_warn
    make_pod("alpha", dates: fresh_dates)
    3.times do |i|
      write_log("alpha", "a-2026-10-0#{7 + i}.log",
        ["[2026-10-0#{7 + i} 06:00:01] [TweetAgent] Warning: credits depleted",
          "[2026-10-0#{7 + i} 06:00:09] \u2713 Episode ready"], mtime: Time.new(2026, 10, 7 + i, 6))
    end
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*repeated in last 3 runs: \[TweetAgent\] Warning: credits depleted/, out)
  end

  # --- pre-generated episodes (freshness_lead_days) ---

  def test_run_newest_one_day_ahead_reports_ok_scheduled
    make_pod("alpha", dates: %w[2026-10-09 2026-10-10 2026-10-11 2026-10-12])
    out, code = run_status
    assert_equal 0, code, out
    assert_match(/alpha\s+OK\s+newest 2026-10-12 \(scheduled \+1d\)/, out)
  end

  def test_run_newest_ten_days_ahead_reports_warn
    make_pod("alpha", dates: %w[2026-10-19 2026-10-20 2026-10-21])
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*2026-10-21 is dated in the future \(10 days ahead\)/, out)
  end

  def test_run_lead_days_zero_warns_on_one_day_ahead
    make_pod("alpha", dates: %w[2026-10-10 2026-10-11 2026-10-12], extra: "- freshness_lead_days: 0\n")
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*dated in the future \(1 days ahead\)/, out)
  end

  def test_run_json_scheduled_episode_keeps_key_set
    make_pod("alpha", dates: %w[2026-10-10 2026-10-11 2026-10-12])
    rows = JSON.parse(run_status("--json").first)
    assert_equal JSON_KEYS, rows.first.keys.sort
    assert_equal "OK", rows.first["verdict"]
    assert_equal(-1, rows.first["age_days"])
  end

  def test_run_missing_history_reports_warn
    make_pod("alpha", dates: nil)
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+no history/, out)
  end

  # --- ordering, scheduling, hint ---

  def test_run_scheduled_podcasts_listed_first
    make_pod("alpha", dates: fresh_dates)
    make_pod("zeta", dates: fresh_dates)
    File.write(File.join(@plist_dir, "com.podcastagent.zeta.plist"), "<plist/>")
    out, = run_status
    assert_operator out.index("zeta"), :<, out.index("alpha")
  end

  def test_run_prints_install_hint_when_status_check_not_scheduled
    make_pod("alpha", dates: fresh_dates)
    out, = run_status
    assert_includes out, "schedule --status-check"
  end

  def test_run_omits_install_hint_when_status_check_scheduled
    make_pod("alpha", dates: fresh_dates)
    File.write(File.join(@plist_dir, "com.podcastagent.status.plist"), "<plist/>")
    out, = run_status
    refute_includes out, "schedule --status-check"
  end

  def test_run_install_hint_flag_prints_only_the_command
    make_pod("alpha", dates: fresh_dates)
    out, code = run_status("--install-hint")
    assert_equal 0, code
    assert_equal 1, out.lines.size
    assert_match(%r{bin/podgen schedule --status-check}, out)
  end

  # --- --json (frozen shape, CLAUDE.md rule 5) ---

  def test_run_json_key_set_is_pinned
    make_pod("alpha", dates: fresh_dates)
    make_pod("beta", dates: %w[2026-01-01 2026-01-02 2026-01-03])
    out, code = run_status("--json")
    rows = JSON.parse(out)
    assert_equal 1, code
    assert_equal 2, rows.size
    rows.each { |r| assert_equal JSON_KEYS, r.keys.sort }
    ok = rows.find { |r| r["podcast"] == "alpha" }
    assert_equal "OK", ok["verdict"]
    assert_equal "2026-10-10", ok["newest"]
    assert_equal 1, ok["age_days"]
    assert_kind_of Array, ok["reasons"]
    assert_equal "OLD", rows.find { |r| r["podcast"] == "beta" }["verdict"]
  end

  def test_run_json_with_unknown_age_uses_nulls
    make_pod("alpha", dates: nil)
    rows = JSON.parse(run_status("--json").first)
    assert_nil rows.first["newest"]
    assert_nil rows.first["age_days"]
  end

  def test_run_single_podcast_argument_limits_output
    make_pod("alpha", dates: fresh_dates)
    make_pod("beta", dates: fresh_dates)
    rows = JSON.parse(run_status("--json", "beta").first)
    assert_equal ["beta"], rows.map { |r| r["podcast"] }
  end

  def test_run_unknown_podcast_exits_two
    make_pod("alpha", dates: fresh_dates)
    code = nil
    capture_io { code = status_command(["nope"]).run }
    assert_equal 2, code
  end

  def test_run_never_writes_under_plist_dir
    make_pod("alpha", dates: fresh_dates)
    run_status
    assert_empty Dir.children(@plist_dir)
  end

  def test_commands_registers_status
    assert PodgenCLI::COMMANDS.key?("status")
    refute PodgenCLI.owner_action?("status", [], {})
  end

  private

  def fresh_dates = %w[2026-10-07 2026-10-08 2026-10-09 2026-10-10]

  def status_command(args)
    PodgenCLI::StatusCommand.new(args, {}, plist_dir: @plist_dir, today: TODAY)
  end

  def run_status(*args)
    code = nil
    out, = capture_io { code = status_command(args).run }
    [out, code]
  end

  def make_pod(name, dates:, freshness_off: false, extra: "")
    dir = File.join(@tmpdir, "podcasts", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "guidelines.md"),
      "## Podcast\n- name: #{name}\n#{"- freshness: off\n" if freshness_off}#{extra}\n## Topics\n- x\n")
    return unless dates

    out = File.join(@tmpdir, "output", name)
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "history.yml"),
      dates.map { |d| {"date" => d, "title" => "t", "topics" => []} }.to_yaml)
  end

  def write_log(pod, file, lines, mtime:)
    dir = File.join(@tmpdir, "logs", pod)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, file)
    File.write(path, lines.join("\n") + "\n")
    File.utime(mtime, mtime, path)
  end
end
