# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "yaml"
require "cli"
require "cli/status_command"

class TestStatusCommand < Minitest::Test
  TODAY = Date.new(2026, 10, 11)
  JSON_KEYS = %w[podcast verdict newest age_days reasons announcements uploads].sort.freeze

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

  # --- RUN-OUTCOME line (P7-0) ---

  def test_run_outcome_line_with_warnings_reports_warn_with_first_warning
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01] ERROR Language es failed: RuntimeError: x",
      "[2026-10-10 06:00:08] ⚠ 1 episode(s) produced (with warnings)",
      "[2026-10-10 06:00:08]   - Language es failed: RuntimeError: x",
      "[2026-10-10 06:00:09] RUN-OUTCOME status=warn warnings=1 errors=1 first=Language es failed: RuntimeError: x"],
      mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+a-2026-10-10\.log: Language es failed: RuntimeError: x/, out)
  end

  def test_run_outcome_line_with_error_status_reports_run_failed
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01] ERROR RuntimeError: TTS quota",
      "[2026-10-10 06:00:09] RUN-OUTCOME status=error warnings=0 errors=2 first=RuntimeError: TTS quota"],
      mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+a-2026-10-10\.log: run failed: RuntimeError: TTS quota/, out)
  end

  def test_run_outcome_line_ok_reports_ok
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01] ✓ 1 episode(s) produced",
      "[2026-10-10 06:00:09] RUN-OUTCOME status=ok warnings=0 errors=0"], mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 0, code, out
  end

  def test_run_outcome_line_ok_still_scans_for_uncounted_warning_lines
    make_pod("alpha", dates: fresh_dates)
    write_log("alpha", "a-2026-10-10.log", ["[2026-10-10 06:00:01] Warning: cover missing",
      "[2026-10-10 06:00:09] RUN-OUTCOME status=ok warnings=0 errors=0"], mtime: Time.new(2026, 10, 10, 6))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*Warning: cover missing/, out)
  end

  # --- publish stderr (launchd_stderr.log, P3-2) ---

  def test_run_twitter_warning_in_three_publishes_reports_warn_with_count_and_since
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-08 2026-10-09 2026-10-10], CREDITS))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*publish warning in last 3 publishes \(since 2026-10-08\): .*credits depleted/, out)
  end

  def test_run_twitter_warning_in_two_publishes_is_ok
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-09 2026-10-10], CREDITS))
    out, code = run_status
    assert_equal 0, code, out
  end

  def test_run_clean_latest_publish_breaks_the_streak
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-07 2026-10-08 2026-10-09], CREDITS) + publishes(%w[2026-10-10], nil))
    out, code = run_status
    assert_equal 0, code, out
  end

  def test_run_generate_errors_between_publishes_do_not_break_the_streak
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-07 2026-10-08], CREDITS) +
      ["[2026-10-09 19:19:21] ERROR RuntimeError: ScriptAgent failed after 4 attempts: Connection error.",
        "/x/lib/retryable.rb:35:in 'Retryable#with_retries'", "Generate failed with exit code 1"] +
      publishes(%w[2026-10-10], CREDITS))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*last 3 publishes \(since 2026-10-07\)/, out)
  end

  def test_run_contiguous_rclone_lines_form_one_publish
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(%w[2026-10-08 2026-10-09 2026-10-10].flat_map { |d|
      [rclone_line(d), "#{d.tr("-", "/")} 16:52:09 NOTICE: second rclone line", CREDITS]
    })
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*last 3 publishes/, out)
  end

  def test_run_clean_publishes_on_adjacent_lines_stay_separate
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-04 2026-10-05 2026-10-06], nil) +
      publishes(%w[2026-10-07 2026-10-08 2026-10-09], CREDITS))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*last 3 publishes \(since 2026-10-07\)/, out)
  end

  def test_run_twitter_warning_not_attributed_to_podcast_without_twitter_section
    make_pod("beta", dates: fresh_dates)
    File.write(File.join(@plist_dir, "com.podcastagent.beta.plist"), "<plist/>")
    write_publish_log(publishes(%w[2026-10-08 2026-10-09 2026-10-10], CREDITS))
    out, code = run_status
    assert_equal 0, code, out
  end

  def test_run_other_publish_warning_attributed_to_scheduled_podcast_only
    make_pod("alpha", dates: fresh_dates)
    make_pod("beta", dates: fresh_dates)
    File.write(File.join(@plist_dir, "com.podcastagent.beta.plist"), "<plist/>")
    write_publish_log(publishes(%w[2026-10-08 2026-10-09 2026-10-10], "Warning: site/feed regen failed: IOError: x"))
    out, code = run_status
    assert_equal 1, code
    assert_match(/beta\s+WARN\s+.*regen failed/, out)
    assert_match(/alpha\s+OK/, out)
  end

  def test_run_marked_publishes_attribute_warnings_by_podcast
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    make_pod("beta", dates: fresh_dates, sections: TWITTER)
    File.write(File.join(@plist_dir, "com.podcastagent.beta.plist"), "<plist/>")
    write_publish_log(%w[2026-10-08 2026-10-09 2026-10-10].flat_map { |d|
      marked_publish("alpha", d, CREDITS) + marked_publish("beta", d, nil)
    })
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*publish warning in last 3 publishes \(since 2026-10-08\): .*credits depleted/, out)
    assert_match(/beta\s+OK/, out)
  end

  def test_run_marked_publish_warning_belongs_to_named_podcast_regardless_of_content
    make_pod("alpha", dates: fresh_dates)
    write_publish_log(%w[2026-10-08 2026-10-09 2026-10-10].flat_map { |d| marked_publish("alpha", d, CREDITS) })
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*last 3 publishes/, out)
  end

  def test_run_generate_warning_between_marked_publishes_not_counted
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    File.write(File.join(@plist_dir, "com.podcastagent.alpha.plist"), "<plist/>")
    write_publish_log(%w[2026-10-08 2026-10-09 2026-10-10].flat_map { |d|
      ["Warning: guidelines.md: unknown section ## Foo"] + marked_publish("alpha", d, nil)
    } + ["Warning: guidelines.md: unknown section ## Foo"])
    out, code = run_status
    assert_equal 0, code, out
    refute_match(/guidelines/, out)
  end

  def test_run_streak_counts_across_legacy_and_marked_publishes
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-07 2026-10-08], CREDITS) +
      %w[2026-10-09 2026-10-10].flat_map { |d| marked_publish("alpha", d, CREDITS) })
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*last 4 publishes \(since 2026-10-07\)/, out)
  end

  def test_run_legacy_latest_superseded_by_later_marked_publish_not_reported
    # Once run.sh marks publishes, unnamed entries stop growing; a stale legacy
    # streak must not stay frozen as "latest" for a podcast with no named entry.
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-07 2026-10-08 2026-10-09], CREDITS) +
      marked_publish("beta", "2026-10-10", nil))
    out, code = run_status
    assert_equal 0, code, out
    refute_match(/credits depleted/, out)
  end

  def test_run_legacy_latest_still_reported_when_it_is_the_last_entry
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    write_publish_log(publishes(%w[2026-10-07 2026-10-08 2026-10-09], CREDITS))
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*last 3 publishes \(since 2026-10-07\)/, out)
  end

  def test_run_mismatched_end_marker_does_not_close_named_entry
    make_pod("alpha", dates: fresh_dates)
    write_publish_log(%w[2026-10-08 2026-10-09 2026-10-10].flat_map { |d|
      stamp = "#{d.tr("-", "/")} 16:52:00"
      ["#{stamp} podgen publish alpha begin", "#{stamp} podgen publish beta end exit=0",
        CREDITS, "#{stamp} podgen publish alpha end exit=0"]
    })
    entries = publish_entries
    assert_equal %w[alpha alpha alpha], entries.map { it[:podcast] }
    assert(entries.all? { it[:warnings].values == [CREDITS] })
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*last 3 publishes/, out)
  end

  def test_parse_orphan_named_entry_closes_on_generate_line
    write_publish_log(["2026/10/09 16:52:00 podgen publish alpha begin",
      "[2026-10-10 07:00:01] ERROR RuntimeError: boom",
      "Warning: guidelines.md: unknown section ## Foo"])
    entries = publish_entries
    assert_equal [["alpha", {}]], entries.map { [it[:podcast], it[:warnings]] }
  end

  def test_parse_orphan_named_entry_closes_on_dated_line_of_a_later_day
    write_publish_log(["2026/10/09 16:52:00 podgen publish alpha begin",
      rclone_line("2026-10-10"), "Warning: guidelines.md: unknown section ## Foo"])
    entries = publish_entries
    assert_equal [["alpha", "2026-10-09", []], [nil, "2026-10-10", ["Warning: guidelines.md: unknown section ## Foo"]]],
      entries.map { [it[:podcast], it[:date], it[:warnings].values] }
  end

  def test_parse_named_entry_keeps_same_day_dated_lines
    write_publish_log(marked_publish("alpha", "2026-10-09", CREDITS))
    entries = publish_entries
    assert_equal [["alpha", [CREDITS]]], entries.map { [it[:podcast], it[:warnings].values] }
  end

  def test_run_publish_log_path_is_injectable
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    path = File.join(@tmpdir, "elsewhere.log")
    File.write(path, publishes(%w[2026-10-08 2026-10-09 2026-10-10], CREDITS).join("\n"))
    code = nil
    out, = capture_io { code = PodgenCLI::StatusCommand.new([], {}, plist_dir: @plist_dir, today: TODAY, publish_log: path).run }
    assert_equal 1, code
    assert_match(/credits depleted/, out)
  end

  # --- announcement progress (Twitter, P3-2) ---

  def test_run_announcements_stalled_reports_warn_with_last_tweet_date
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    make_episodes("alpha", %w[alpha-2026-08-19 alpha-2026-10-09 alpha-2026-10-10])
    write_tracker("alpha", %w[alpha-2026-08-19])
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*announcements stalled since 2026-08-19/, out)
    row = JSON.parse(run_status("--json").first).first
    assert_equal({"last_tweeted" => "2026-08-19", "newest_episode" => "2026-10-10", "stalled" => true}, row["announcements"])
  end

  def test_run_recent_tweet_within_since_is_ok
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    make_episodes("alpha", %w[alpha-2026-10-05 alpha-2026-10-10])
    write_tracker("alpha", %w[alpha-2026-10-05])
    out, code = run_status
    assert_equal 0, code, out
    row = JSON.parse(run_status("--json").first).first
    assert_equal false, row["announcements"]["stalled"]
  end

  def test_run_announcements_ignore_languages_not_announced
    make_pod("alpha", dates: fresh_dates, extra: "- language:\n  - en\n  - es\n", sections: TWITTER)
    make_episodes("alpha", %w[alpha-2026-10-01 alpha-2026-10-10-es])
    write_tracker("alpha", %w[alpha-2026-10-01])
    out, code = run_status
    assert_equal 0, code, out
    assert_equal "2026-10-01", JSON.parse(run_status("--json").first).first["announcements"]["newest_episode"]
  end

  def test_run_never_tweeted_brand_new_show_is_ok
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    make_episodes("alpha", %w[alpha-2026-10-09 alpha-2026-10-10])
    out, code = run_status
    assert_equal 0, code, out
    assert_nil JSON.parse(run_status("--json").first).first["announcements"]["last_tweeted"]
  end

  def test_run_never_tweeted_with_episode_older_than_since_reports_warn
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    make_episodes("alpha", %w[alpha-2026-10-01 alpha-2026-10-10])
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*announcements never posted/, out)
  end

  def test_run_without_twitter_section_skips_announcement_check
    make_pod("alpha", dates: fresh_dates)
    make_episodes("alpha", %w[alpha-2026-08-19 alpha-2026-10-10])
    write_tracker("alpha", %w[alpha-2026-08-19])
    out, code = run_status
    assert_equal 0, code, out
    assert_nil JSON.parse(run_status("--json").first).first["announcements"]
  end

  def test_run_never_creates_tracker_file
    make_pod("alpha", dates: fresh_dates, sections: TWITTER)
    make_episodes("alpha", %w[alpha-2026-10-10])
    File.write(File.join(@tmpdir, "output", "alpha", "lingq_uploads.yml"), {"c1" => {"alpha-2026-10-10" => 1}}.to_yaml)
    run_status
    refute File.exist?(File.join(@tmpdir, "output", "alpha", "uploads.yml"))
  end

  # --- upload progress per platform (P7-1) ---

  def test_run_youtube_uploads_ten_days_behind_reports_warn
    make_pod("alpha", dates: fresh_dates, sections: YOUTUBE)
    make_episodes("alpha", %w[alpha-2026-09-30 alpha-2026-10-10])
    write_uploads("alpha", "youtube" => {"PL1" => {"alpha-2026-09-30" => "v1"}})
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*youtube uploads stalled since 2026-09-30 \(newest episode 2026-10-10\)/, out)
    row = JSON.parse(run_status("--json").first).first
    assert_equal({"youtube" => {"last_uploaded" => "2026-09-30", "newest_episode" => "2026-10-10", "stalled" => true}},
      row["uploads"])
  end

  def test_run_lingq_uploads_ten_days_behind_reports_warn
    make_pod("alpha", dates: fresh_dates, sections: LINGQ)
    make_episodes("alpha", %w[alpha-2026-09-30 alpha-2026-10-10])
    write_uploads("alpha", "lingq" => {"123" => {"alpha-2026-09-30" => 11}})
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*lingq uploads stalled since 2026-09-30/, out)
  end

  def test_run_uploads_within_since_window_are_ok
    make_pod("alpha", dates: fresh_dates, sections: YOUTUBE + LINGQ)
    make_episodes("alpha", %w[alpha-2026-10-05 alpha-2026-10-10])
    write_uploads("alpha", "youtube" => {"PL1" => {"alpha-2026-10-05" => "v1"}},
      "lingq" => {"123" => {"alpha-2026-10-10" => 11}})
    out, code = run_status
    assert_equal 0, code, out
  end

  def test_run_uploads_counted_per_configured_group_only
    make_pod("alpha", dates: fresh_dates, sections: YOUTUBE)
    make_episodes("alpha", %w[alpha-2026-09-30 alpha-2026-10-10])
    write_uploads("alpha", "youtube" => {"OTHER" => {"alpha-2026-10-10" => "v9"}, "PL1" => {"alpha-2026-09-30" => "v1"}})
    out, code = run_status
    assert_equal 1, code
    assert_match(/youtube uploads stalled since 2026-09-30/, out)
  end

  def test_run_youtube_never_uploaded_with_old_episode_reports_warn
    make_pod("alpha", dates: fresh_dates, sections: YOUTUBE)
    make_episodes("alpha", %w[alpha-2026-09-20 alpha-2026-10-10])
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+WARN\s+.*youtube uploads never made \(newest episode 2026-10-10\)/, out)
  end

  def test_run_no_upload_platform_configured_skips_check
    make_pod("alpha", dates: fresh_dates)
    make_episodes("alpha", %w[alpha-2026-08-01 alpha-2026-10-10])
    write_uploads("alpha", "youtube" => {"PL1" => {"alpha-2026-08-01" => "v1"}})
    out, code = run_status
    assert_equal 0, code, out
    assert_nil JSON.parse(run_status("--json").first).first["uploads"]
  end

  def test_run_uploads_stderr_not_authorized_reports_one_warn_line
    make_pod("alpha", dates: fresh_dates, sections: YOUTUBE)
    write_uploads_log(["  ✗ alpha-2026-10-10 skipped: YouTube not authorized: token file /x/y.json empty (0 bytes)",
      "  ✗ alpha-2026-10-09 skipped: YouTube not authorized: token file /x/y.json empty (0 bytes)"])
    out, code = run_status
    assert_equal 1, code
    assert_equal 1, out.scan("YouTube not authorized").size, out
    assert_match(/alpha\s+WARN\s+.*uploads_stderr\.log: YouTube not authorized/, out)
    refute_includes out, "/x/y.json"
  end

  def test_run_uploads_stderr_quota_exceeded_reports_warn_without_body
    make_pod("alpha", dates: fresh_dates, sections: YOUTUBE)
    write_uploads_log(["  ✗ alpha-2026-10-10 failed: uploadLimitExceeded: The user has exceeded the number " \
      "of videos they may upload. https://example.invalid/x"])
    out, code = run_status
    assert_equal 1, code
    assert_match(/uploads_stderr\.log: YouTube upload quota exceeded/, out)
    refute_includes out, "https://"
  end

  def test_run_uploads_stderr_older_than_since_is_ignored
    make_pod("alpha", dates: fresh_dates, sections: YOUTUBE)
    write_uploads_log(["  ✗ alpha-2026-09-01 skipped: YouTube not authorized: x"], mtime: Time.new(2026, 9, 1, 12))
    out, code = run_status
    assert_equal 0, code, out
  end

  def test_run_uploads_stderr_ignored_for_podcast_without_youtube
    make_pod("alpha", dates: fresh_dates)
    write_uploads_log(["  ✗ beta-2026-10-10 skipped: YouTube not authorized: x"])
    out, code = run_status
    assert_equal 0, code, out
  end

  # --- dormant shows and configured cadence (P3-4) ---

  def test_run_single_day_show_long_ago_reports_ok_with_dormant_note
    # ruby_world shape: four episodes on one date, months old.
    make_pod("alpha", dates: %w[2026-02-19 2026-02-19 2026-02-19 2026-02-19])
    out, code = run_status
    assert_equal 0, code, out
    assert_match(/alpha\s+OK\s+newest 2026-02-19 \(234d old; dormant — no cadence\)/, out)
  end

  def test_run_single_day_show_yesterday_reports_plain_ok
    make_pod("alpha", dates: %w[2026-10-10])
    out, code = run_status
    assert_equal 0, code, out
    assert_match(/alpha\s+OK\s+newest 2026-10-10 \(1d old\)$/, out)
  end

  def test_run_configured_cadence_reports_old
    make_pod("alpha", dates: %w[2026-10-01], extra: "- cadence_days: 2\n")
    out, code = run_status
    assert_equal 1, code
    assert_match(/alpha\s+OLD\s+.*newest episode 2026-10-01 is 10 days old \(cadence 2d configured, threshold 4d\)/, out)
  end

  def test_run_invalid_cadence_days_is_ignored
    make_pod("alpha", dates: %w[2026-10-01], extra: "- cadence_days: often\n")
    out, code = run_status
    assert_equal 0, code, out
    assert_match(/alpha\s+OK\s+newest 2026-10-01 \(10d old\)$/, out)
  end

  def test_run_json_dormant_show_keeps_key_set
    make_pod("alpha", dates: %w[2026-02-19])
    rows = JSON.parse(run_status("--json").first)
    assert_equal JSON_KEYS, rows.first.keys.sort
    assert_includes rows.first["reasons"], "newest 2026-02-19 (234d old; dormant — no cadence)"
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

  def publish_entries = status_command([]).send(:publish_entries)

  def run_status(*args)
    code = nil
    out, = capture_io { code = status_command(args).run }
    [out, code]
  end

  def make_pod(name, dates:, freshness_off: false, extra: "", sections: "")
    dir = File.join(@tmpdir, "podcasts", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "guidelines.md"),
      "## Podcast\n- name: #{name}\n#{"- freshness: off\n" if freshness_off}#{extra}\n## Topics\n- x\n#{sections}")
    return unless dates

    out = File.join(@tmpdir, "output", name)
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "history.yml"),
      dates.map { |d| {"date" => d, "title" => "t", "topics" => []} }.to_yaml)
  end

  TWITTER = "\n## Twitter\n- since: 5\n- languages: en\n"
  CREDITS = "Warning: Twitter posting failed: RuntimeError: Twitter post failed after 3 attempts: " \
    "Payment Required: credits depleted (non-fatal)"

  def rclone_line(date) = "#{date.tr("-", "/")} 16:52:04 NOTICE: Config file \"/x/rclone.conf\" not found - using defaults"

  # Shared launchd stderr (scripts/run.sh output): one rclone line per publish.
  def write_publish_log(lines)
    FileUtils.mkdir_p(File.join(@tmpdir, "logs"))
    File.write(File.join(@tmpdir, "logs", "launchd_stderr.log"), lines.join("\n") + "\n")
  end

  def publishes(dates, warning)
    dates.flat_map { |d| [rclone_line(d), *warning] }
  end

  # scripts/run.sh brackets each publish with dated begin/end markers.
  def marked_publish(name, date, warning)
    stamp = "#{date.tr("-", "/")} 16:52:00"
    ["#{stamp} podgen publish #{name} begin", rclone_line(date), *warning,
      "#{stamp.sub("16:52:00", "16:53:00")} podgen publish #{name} end exit=0"]
  end

  def make_episodes(pod, basenames)
    dir = File.join(@tmpdir, "output", pod, "episodes")
    FileUtils.mkdir_p(dir)
    basenames.each do |b|
      File.write(File.join(dir, "#{b}.mp3"), "")
      File.write(File.join(dir, "#{b}_script.md"), "# t\n")
    end
  end

  def write_tracker(pod, basenames)
    dir = File.join(@tmpdir, "output", pod)
    FileUtils.mkdir_p(dir)
    posts = basenames.to_h { |b| [b, "id-#{b}"] }
    File.write(File.join(dir, "uploads.yml"), {"twitter" => {"posts" => posts}}.to_yaml)
  end

  YOUTUBE = "\n## YouTube\n- playlist: PL1\n"
  LINGQ = "\n## LingQ\n- collection: 123\n"

  def write_uploads(pod, data)
    dir = File.join(@tmpdir, "output", pod)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "uploads.yml"), data.to_yaml)
  end

  # Shared stderr of the scheduled upload batch (scripts/run_upl*.sh).
  def write_uploads_log(lines, mtime: Time.new(2026, 10, 10, 17))
    FileUtils.mkdir_p(File.join(@tmpdir, "logs"))
    path = File.join(@tmpdir, "logs", "uploads_stderr.log")
    File.write(path, lines.join("\n") + "\n")
    File.utime(mtime, mtime, path)
  end

  def write_log(pod, file, lines, mtime:)
    dir = File.join(@tmpdir, "logs", pod)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, file)
    File.write(path, lines.join("\n") + "\n")
    File.utime(mtime, mtime, path)
  end
end
