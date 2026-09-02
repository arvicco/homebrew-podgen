# frozen_string_literal: true

require_relative "../test_helper"
require "snip_interval"

class TestSnipInterval < Minitest::Test
  # --- Parsing: range formats ---

  def test_parse_seconds_range
    si = SnipInterval.parse("20-30")
    assert_equal 1, si.intervals.length
    assert_in_delta 20.0, si.intervals[0].from
    assert_in_delta 30.0, si.intervals[0].to
  end

  def test_parse_minsec_range
    si = SnipInterval.parse("1:20-2:30")
    assert_in_delta 80.0, si.intervals[0].from
    assert_in_delta 150.0, si.intervals[0].to
  end

  def test_parse_mixed_range
    si = SnipInterval.parse("80-2:30")
    assert_in_delta 80.0, si.intervals[0].from
    assert_in_delta 150.0, si.intervals[0].to
  end

  # --- Parsing: offset format ---

  def test_parse_offset
    si = SnipInterval.parse("1:20+30")
    assert_in_delta 80.0, si.intervals[0].from
    assert_in_delta 110.0, si.intervals[0].to
  end

  def test_parse_offset_minsec_duration
    si = SnipInterval.parse("1:00+1:30")
    assert_in_delta 60.0, si.intervals[0].from
    assert_in_delta 150.0, si.intervals[0].to
  end

  # --- Parsing: open-ended ---

  def test_parse_open_ended
    si = SnipInterval.parse("1:20-end")
    assert_in_delta 80.0, si.intervals[0].from
    assert_nil si.intervals[0].to
  end

  def test_parse_open_ended_case_insensitive
    si = SnipInterval.parse("100-END")
    assert_in_delta 100.0, si.intervals[0].from
    assert_nil si.intervals[0].to
  end

  # --- Parsing: multiple intervals ---

  def test_parse_multiple
    si = SnipInterval.parse("1:20-2:30,3:40+33,455-520")
    assert_equal 3, si.intervals.length
    assert_in_delta 80.0, si.intervals[0].from
    assert_in_delta 150.0, si.intervals[0].to
    assert_in_delta 220.0, si.intervals[1].from
    assert_in_delta 253.0, si.intervals[1].to
    assert_in_delta 455.0, si.intervals[2].from
    assert_in_delta 520.0, si.intervals[2].to
  end

  # --- Parsing: nil / empty / idempotent ---

  def test_parse_nil
    assert_nil SnipInterval.parse(nil)
  end

  def test_parse_empty
    assert_nil SnipInterval.parse("")
  end

  def test_parse_whitespace
    assert_nil SnipInterval.parse("   ")
  end

  def test_parse_idempotent
    si = SnipInterval.parse("10-20")
    assert_same si, SnipInterval.parse(si)
  end

  # --- Parsing: invalid input ---

  def test_parse_invalid_raises
    assert_raises(ArgumentError) { SnipInterval.parse("abc") }
  end

  def test_parse_single_number_raises
    assert_raises(ArgumentError) { SnipInterval.parse("42") }
  end

  # --- keep_segments: middle snip ---

  def test_keep_segments_middle_snip
    si = SnipInterval.parse("10-20")
    keeps = si.keep_segments(30)
    assert_equal 2, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 10.0, keeps[0].to
    assert_in_delta 20.0, keeps[1].from
    assert_in_delta 30.0, keeps[1].to
  end

  # --- keep_segments: from start ---

  def test_keep_segments_from_start
    si = SnipInterval.parse("0-10")
    keeps = si.keep_segments(30)
    assert_equal 1, keeps.length
    assert_in_delta 10.0, keeps[0].from
    assert_in_delta 30.0, keeps[0].to
  end

  # --- keep_segments: to end ---

  def test_keep_segments_to_end
    si = SnipInterval.parse("20-end")
    keeps = si.keep_segments(30)
    assert_equal 1, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 20.0, keeps[0].to
  end

  # --- keep_segments: multiple ---

  def test_keep_segments_multiple
    si = SnipInterval.parse("5-10,20-25")
    keeps = si.keep_segments(30)
    assert_equal 3, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 5.0, keeps[0].to
    assert_in_delta 10.0, keeps[1].from
    assert_in_delta 20.0, keeps[1].to
    assert_in_delta 25.0, keeps[2].from
    assert_in_delta 30.0, keeps[2].to
  end

  # --- keep_segments: overlapping merge ---

  def test_keep_segments_overlapping_merge
    si = SnipInterval.parse("5-15,10-20")
    keeps = si.keep_segments(30)
    assert_equal 2, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 5.0, keeps[0].to
    assert_in_delta 20.0, keeps[1].from
    assert_in_delta 30.0, keeps[1].to
  end

  # --- keep_segments: adjacent merge ---

  def test_keep_segments_adjacent_merge
    si = SnipInterval.parse("5-10,10-15")
    keeps = si.keep_segments(30)
    assert_equal 2, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 5.0, keeps[0].to
    assert_in_delta 15.0, keeps[1].from
    assert_in_delta 30.0, keeps[1].to
  end

  # --- keep_segments: unsorted ---

  def test_keep_segments_unsorted
    si = SnipInterval.parse("20-25,5-10")
    keeps = si.keep_segments(30)
    assert_equal 3, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 5.0, keeps[0].to
    assert_in_delta 10.0, keeps[1].from
    assert_in_delta 20.0, keeps[1].to
    assert_in_delta 25.0, keeps[2].from
    assert_in_delta 30.0, keeps[2].to
  end

  # --- keep_segments: entire file ---

  def test_keep_segments_entire_file
    si = SnipInterval.parse("0-end")
    keeps = si.keep_segments(30)
    assert_equal 0, keeps.length
  end

  # --- keep_segments: beyond duration clamp ---

  def test_keep_segments_beyond_duration_clamp
    si = SnipInterval.parse("10-999")
    keeps = si.keep_segments(30)
    assert_equal 1, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 10.0, keeps[0].to
  end

  # --- add method ---

  def test_add_folds_in_intervals
    si = SnipInterval.parse("10-20")
    si.add(0, 5)
    keeps = si.keep_segments(30)
    assert_equal 2, keeps.length
    assert_in_delta 5.0, keeps[0].from
    assert_in_delta 10.0, keeps[0].to
    assert_in_delta 20.0, keeps[1].from
    assert_in_delta 30.0, keeps[1].to
  end

  # --- to_s ---

  def test_to_s_single
    si = SnipInterval.parse("1:20-2:30")
    assert_equal "1:20-2:30", si.to_s
  end

  def test_to_s_open_ended
    si = SnipInterval.parse("80-end")
    assert_equal "1:20-end", si.to_s
  end

  def test_to_s_multiple
    si = SnipInterval.parse("10-20,1:00-1:30")
    assert_equal "10-20, 1:00-1:30", si.to_s
  end

  def test_to_s_seconds_only
    si = SnipInterval.parse("5-30")
    assert_equal "5-30", si.to_s
  end

  # --- empty ---

  def test_empty_has_no_intervals
    si = SnipInterval.empty
    assert_empty si.intervals
  end

  def test_empty_keep_segments_returns_full_range
    si = SnipInterval.empty
    keeps = si.keep_segments(100)
    assert_equal 1, keeps.length
    assert_in_delta 0.0, keeps[0].from
    assert_in_delta 100.0, keeps[0].to
  end

  def test_empty_supports_add
    si = SnipInterval.empty
    si.add(0, 10)
    si.add(90, 100)
    keeps = si.keep_segments(100)
    assert_equal 1, keeps.length
    assert_in_delta 10.0, keeps[0].from
    assert_in_delta 90.0, keeps[0].to
  end

  # --- parse_timestamp (characterization, private) ---

  def test_parse_timestamp_minsec
    assert_in_delta 80.0, empty_si.send(:parse_timestamp, "1:20")
  end

  def test_parse_timestamp_plain_seconds
    assert_in_delta 80.0, empty_si.send(:parse_timestamp, "80")
  end

  def test_parse_timestamp_minsec_fractional
    assert_in_delta 62.5, empty_si.send(:parse_timestamp, "1:2.5")
  end

  def test_parse_timestamp_zero
    assert_in_delta 0.0, empty_si.send(:parse_timestamp, "0:00")
  end

  def test_parse_timestamp_garbage_raises
    assert_raises(ArgumentError) { empty_si.send(:parse_timestamp, "abc") }
  end

  def test_parse_timestamp_three_digit_seconds_raises
    # "1:200" fails the m:ss regex (max 2 second digits) and then
    # Float("1:200") raises — pinned as ArgumentError.
    assert_raises(ArgumentError) { empty_si.send(:parse_timestamp, "1:200") }
  end

  # --- merge_intervals (characterization, private; caller pre-sorts) ---

  def test_merge_intervals_overlapping_merged
    merged = empty_si.send(:merge_intervals, [iv(0, 10), iv(5, 15)])
    assert_equal 1, merged.length
    assert_in_delta 0.0, merged[0].from
    assert_in_delta 15.0, merged[0].to
  end

  def test_merge_intervals_adjacent_merged
    merged = empty_si.send(:merge_intervals, [iv(0, 10), iv(10, 20)])
    assert_equal 1, merged.length
    assert_in_delta 0.0, merged[0].from
    assert_in_delta 20.0, merged[0].to
  end

  def test_merge_intervals_disjoint_kept_separate
    merged = empty_si.send(:merge_intervals, [iv(0, 5), iv(10, 15)])
    assert_equal 2, merged.length
    assert_in_delta 5.0, merged[0].to
    assert_in_delta 10.0, merged[1].from
  end

  def test_merge_intervals_empty_returns_empty
    assert_equal [], empty_si.send(:merge_intervals, [])
  end

  def test_merge_intervals_unsorted_input_swallows_earlier_interval
    # Characterization: merge_intervals assumes sorted input (keep_segments
    # sorts before calling). Given unsorted input, the second interval's
    # from (0) is <= the first's to (15), so it is merged away entirely —
    # the earlier [0,5] interval is silently lost.
    merged = empty_si.send(:merge_intervals, [iv(10, 15), iv(0, 5)])
    assert_equal 1, merged.length
    assert_in_delta 10.0, merged[0].from
    assert_in_delta 15.0, merged[0].to
  end

  private

  def empty_si
    SnipInterval.empty
  end

  def iv(from, to)
    SnipInterval::Interval.new(from.to_f, to.to_f)
  end
end
