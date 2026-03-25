# frozen_string_literal: true

require_relative "../test_helper"
require "format_helper"

class TestFormatHelper < Minitest::Test
  # --- format_size module method ---

  def test_format_size_bytes
    assert_equal "500 B", FormatHelper.format_size(500)
  end

  def test_format_size_zero
    assert_equal "0 B", FormatHelper.format_size(0)
  end

  def test_format_size_kilobytes
    assert_equal "10 KB", FormatHelper.format_size(10_000)
  end

  def test_format_size_megabytes_default_precision
    assert_equal "1.5 MB", FormatHelper.format_size(1_500_000)
  end

  def test_format_size_megabytes_zero_precision
    assert_equal "2 MB", FormatHelper.format_size(1_500_000, mb_precision: 0)
  end

  def test_format_size_gigabytes
    assert_equal "2.3 GB", FormatHelper.format_size(2_300_000_000)
  end

  def test_format_size_gigabytes_unaffected_by_mb_precision
    assert_equal "2.3 GB", FormatHelper.format_size(2_300_000_000, mb_precision: 0)
  end

  # --- format_duration_mmss module method ---

  def test_format_duration_mmss_basic
    assert_equal "3:05", FormatHelper.format_duration_mmss(185)
  end

  def test_format_duration_mmss_zero
    assert_equal "0:00", FormatHelper.format_duration_mmss(0)
  end

  def test_format_duration_mmss_exact_minute
    assert_equal "10:00", FormatHelper.format_duration_mmss(600)
  end

  def test_format_duration_mmss_large
    assert_equal "65:30", FormatHelper.format_duration_mmss(3930)
  end

  # --- mixin usage ---

  def test_mixin_format_size
    obj = Class.new { include FormatHelper }.new
    assert_equal "1.5 MB", obj.format_size(1_500_000)
    assert_equal "2 MB", obj.format_size(1_500_000, mb_precision: 0)
  end

  def test_mixin_format_duration_mmss
    obj = Class.new { include FormatHelper }.new
    assert_equal "3:05", obj.format_duration_mmss(185)
  end
end
