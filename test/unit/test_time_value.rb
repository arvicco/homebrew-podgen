# frozen_string_literal: true

require_relative "../test_helper"
require "time_value"

class TestTimeValue < Minitest::Test
  # --- Parsing plain numbers (relative) ---

  def test_parse_integer
    tv = TimeValue.parse(30)
    assert_in_delta 30.0, tv
    refute tv.absolute?
  end

  def test_parse_float
    tv = TimeValue.parse(30.5)
    assert_in_delta 30.5, tv
    refute tv.absolute?
  end

  def test_parse_string_integer
    tv = TimeValue.parse("30")
    assert_in_delta 30.0, tv
    refute tv.absolute?
  end

  def test_parse_string_float
    tv = TimeValue.parse("30.5")
    assert_in_delta 30.5, tv
    refute tv.absolute?
  end

  # --- Parsing min:sec format (absolute) ---

  def test_parse_minsec_1_20
    tv = TimeValue.parse("1:20")
    assert_in_delta 80.0, tv
    assert tv.absolute?
  end

  def test_parse_minsec_01_20
    tv = TimeValue.parse("01:20")
    assert_in_delta 80.0, tv
    assert tv.absolute?
  end

  def test_parse_minsec_0_45
    tv = TimeValue.parse("0:45")
    assert_in_delta 45.0, tv
    assert tv.absolute?
  end

  def test_parse_minsec_11_20
    tv = TimeValue.parse("11:20")
    assert_in_delta 680.0, tv
    assert tv.absolute?
  end

  def test_parse_minsec_5_00
    tv = TimeValue.parse("5:00")
    assert_in_delta 300.0, tv
    assert tv.absolute?
  end

  def test_parse_minsec_single_digit_seconds
    tv = TimeValue.parse("2:5")
    assert_in_delta 125.0, tv
    assert tv.absolute?
  end

  # --- Nil / empty handling ---

  def test_parse_nil
    assert_nil TimeValue.parse(nil)
  end

  def test_parse_empty_string
    assert_nil TimeValue.parse("")
  end

  def test_parse_whitespace_only
    assert_nil TimeValue.parse("   ")
  end

  # --- Idempotent parse ---

  def test_parse_returns_same_time_value
    tv = TimeValue.parse("1:20")
    assert_same tv, TimeValue.parse(tv)
  end

  # --- Float delegation ---

  def test_comparison_greater_than
    tv = TimeValue.parse("30")
    assert tv > 0
    assert tv > 29.9
    refute tv > 30.0
  end

  def test_arithmetic_subtraction
    tv = TimeValue.parse("30")
    result = 100 - tv
    assert_in_delta 70.0, result
  end

  def test_arithmetic_addition
    tv = TimeValue.parse("30")
    result = tv + 10
    assert_in_delta 40.0, result
  end

  def test_round
    tv = TimeValue.parse("30.567")
    assert_in_delta 30.6, tv.round(1)
  end

  def test_to_f
    tv = TimeValue.parse("1:20")
    assert_in_delta 80.0, tv.to_f
  end

  def test_to_s
    tv = TimeValue.parse("30")
    assert_equal "30.0", tv.to_s
  end

  def test_zero_comparison
    tv = TimeValue.parse("0")
    refute tv > 0
  end
end
