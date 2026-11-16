# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

# P25-1: the repository is public. Scans every tracked file for a few kinds
# of machine- or account-specific data: a home directory path, a LingQ-style
# 7–8 digit id, and a clock time written as a schedule. A new instance fails
# the gate; placeholders and recorded third-party fixtures are allowed.
class TestTrackedTreeHygiene < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  HOME_PATH_RE = %r{/(?:Users|home)/(?!<)[A-Za-z][\w.-]*/}

  # A bare 7–8 digit number (not part of a hash, version, word or decimal).
  LONG_ID_RE = /(?<![\w.])\d{7,8}(?!\w|\.\d)/
  YYYYMMDD_RE = /\A(?:19|20)\d\d(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\z/
  # Documented placeholders, and a public podcast-host URL path in a
  # source test.
  ID_ALLOWED = %w[1234567 7654321 81353291].freeze
  # Recorded third-party responses and checksums, not account data.
  ID_EXEMPT_PATHS = %r{\A(?:test/fixtures/|Gemfile\.lock\z|Formula/)}

  CLOCK = /(?<![\d:])(?:[01]?\d|2[0-3]):[0-5]\d(?![\d:])/
  # A clock literal assigned to a name: `START = "HH:MM"`.
  CLOCK_ASSIGNMENT_RE = /\b\w+\s*=\s*["'](?:[01]?\d|2[0-3]):[0-5]\d["']/
  # A clock on a line about scheduling. Documented defaults
  # (`default: 06:00`) are option help, not a schedule.
  CODE_SCHEDULE_WORDS = /launchd|schedul|batch|window|cron|daily|yield|--time/i
  README_SCHEDULE_WORDS = /launchd|batch|window|yield|uploads\.lock|--uploads|--status-check/i
  DEFAULT_CLOCK = /default:?\s*`?(?:[01]?\d|2[0-3]):[0-5]\d`?/i
  SCHEDULE_PATHS = %r{\A(?:lib|scripts|bin)/}

  def tracked_files
    out, _err, status = Open3.capture3("git", "ls-files", "-z", chdir: ROOT)
    skip "not a git checkout" unless status.success?
    out.split("\0").select { |p| File.file?(File.join(ROOT, p)) }
  end

  # [path, line number, line] for every line of every tracked text file.
  def tracked_lines
    tracked_files.flat_map do |path|
      data = File.binread(File.join(ROOT, path))
      next [] if data.include?("\0")

      text = data.force_encoding(Encoding::UTF_8)
      next [] unless text.valid_encoding?

      text.each_line.with_index(1).map { |line, n| [path, n, line] }
    end
  end

  def hits(lines)
    lines.map { |path, n, line| "#{path}:#{n}: #{line.strip[0, 120]}" }
  end

  def test_tracked_files_contain_no_home_path
    found = tracked_lines.select { |_, _, line| line.match?(HOME_PATH_RE) }

    assert_empty hits(found), "home directory path in tracked files"
  end

  def test_tracked_files_contain_no_lingq_style_id
    found = tracked_lines.reject { |path, _, _| path.match?(ID_EXEMPT_PATHS) }.select do |_, _, line|
      line.scan(LONG_ID_RE).any? { |id| !ID_ALLOWED.include?(id) && !id.match?(YYYYMMDD_RE) }
    end

    assert_empty hits(found), "7–8 digit id in tracked files (use a placeholder from ID_ALLOWED)"
  end

  def test_code_assigns_no_clock_time_as_a_schedule
    found = tracked_lines.select { |path, _, _| path.match?(SCHEDULE_PATHS) }.select do |_, _, line|
      line.match?(CLOCK_ASSIGNMENT_RE) || schedule_clock?(line, CODE_SCHEDULE_WORDS)
    end

    assert_empty hits(found), "schedule clock time in lib/ scripts/ bin/ (read schedules from the plists)"
  end

  def test_readme_names_no_schedule_clock_time
    found = tracked_lines.select { |path, _, _| path == "README.md" }.select do |_, _, line|
      schedule_clock?(line, README_SCHEDULE_WORDS)
    end

    assert_empty hits(found), "schedule clock time in README.md (use HH:MM)"
  end

  # The checks themselves: each pattern catches its kind and passes the
  # legitimate neighbours.
  def test_patterns_catch_instances_and_pass_legitimate_text
    assert_match HOME_PATH_RE, "cat > /Users/someone/project/lib/x.rb"
    refute_match HOME_PATH_RE, "a /Users/<name>/ placeholder"
    assert_equal ["4455334"], "editor/4455334".scan(LONG_ID_RE)
    assert_empty "sha256 9f86d081884c7d65 v1.2345678 3.14159265".scan(LONG_ID_RE)
    assert_match CLOCK_ASSIGNMENT_RE, %(START = "08:15")
    assert schedule_clock?("# runs in the 08:10–08:55 launchd window", CODE_SCHEDULE_WORDS)
    refute schedule_clock?(%(opts.on("--time HH:MM", "UTC time (default: 06:00)")), CODE_SCHEDULE_WORDS)
    refute schedule_clock?("timeout 10:00 of audio", CODE_SCHEDULE_WORDS)
    refute schedule_clock?("[2026-10-10 08:15:01] batch begin", CODE_SCHEDULE_WORDS)
  end

  def schedule_clock?(line, words)
    line.match?(words) && line.gsub(DEFAULT_CLOCK, "").match?(CLOCK)
  end
end
