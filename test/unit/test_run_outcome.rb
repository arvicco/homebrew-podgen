# frozen_string_literal: true

require_relative "../test_helper"
require "run_outcome"

class TestRunOutcome < Minitest::Test
  def test_line_clean_run_is_ok_without_first
    assert_equal "RUN-OUTCOME status=ok warnings=0 errors=0", RunOutcome.line(code: 0, warnings: [], errors: 0)
  end

  def test_line_warnings_on_success_is_warn_naming_first
    line = RunOutcome.line(code: 0, warnings: ["Language es failed: RuntimeError: x", "other"], errors: 2)
    assert_equal "RUN-OUTCOME status=warn warnings=2 errors=2 first=Language es failed: RuntimeError: x", line
  end

  def test_line_errors_only_on_success_is_warn_naming_first_error
    line = RunOutcome.line(code: 0, warnings: [], errors: 1, first_error: "boom")
    assert_equal "RUN-OUTCOME status=warn warnings=0 errors=1 first=boom", line
  end

  def test_line_nonzero_code_is_error
    line = RunOutcome.line(code: 1, warnings: [], errors: 2, first_error: "RuntimeError: TTS quota")
    assert_equal "RUN-OUTCOME status=error warnings=0 errors=2 first=RuntimeError: TTS quota", line
  end

  def test_line_nonzero_code_names_fatal_error_over_earlier_warnings
    line = RunOutcome.line(code: 1, warnings: ["[SourceManager] Warning: Source 'hn' failed"], errors: 2,
      first_error: "RuntimeError: TTS quota")
    assert_equal "RUN-OUTCOME status=error warnings=1 errors=2 first=RuntimeError: TTS quota", line
  end

  def test_line_nonzero_code_without_error_falls_back_to_first_warning
    assert_equal "RUN-OUTCOME status=error warnings=1 errors=0 first=w",
      RunOutcome.line(code: 1, warnings: ["w"], errors: 0)
  end

  def test_line_first_is_flattened_and_clipped
    line = RunOutcome.line(code: 0, warnings: ["a\nb#{"x" * 500}"], errors: 0)
    first = line[/first=(.*)\z/, 1]
    refute_includes first, "\n"
    assert_operator first.length, :<=, RunOutcome::FIRST_MAX
    assert first.start_with?("a b")
  end

  def test_parse_reads_stamped_line
    parsed = RunOutcome.parse("[2026-10-10 06:00:09] RUN-OUTCOME status=warn warnings=1 errors=0 first=Topic fell back")
    assert_equal({status: "warn", warnings: 1, errors: 0, first: "Topic fell back"}, parsed)
  end

  def test_parse_line_without_first_has_nil_first
    parsed = RunOutcome.parse("RUN-OUTCOME status=ok warnings=0 errors=0")
    assert_equal({status: "ok", warnings: 0, errors: 0, first: nil}, parsed)
  end

  def test_parse_other_line_is_nil
    assert_nil RunOutcome.parse("[2026-10-10 06:00:09] ✓ 1 episode(s) produced")
    assert_nil RunOutcome.parse(nil)
  end

  def test_parse_round_trips_line
    line = RunOutcome.line(code: 1, warnings: ["w"], errors: 3, first_error: "boom")
    assert_equal({status: "error", warnings: 1, errors: 3, first: "boom"}, RunOutcome.parse(line))
  end
end
