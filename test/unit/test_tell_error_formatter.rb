# frozen_string_literal: true

require_relative "../test_helper"
require "tell/error_formatter"

class ErrorFormatterHost
  include Tell::ErrorFormatter
end

class TestTellErrorFormatter < Minitest::Test
  def setup
    @fmt = ErrorFormatterHost.new
  end

  def test_friendly_error_overloaded_529
    err = RuntimeError.new('status: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}')
    assert_equal "API overloaded (try again)", @fmt.friendly_error(err)
  end

  def test_friendly_error_overloaded_json
    err = RuntimeError.new('{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}')
    assert_equal "API overloaded (try again)", @fmt.friendly_error(err)
  end

  def test_friendly_error_rate_limit_429
    err = RuntimeError.new('status: 429 rate limited')
    assert_equal "rate limited (try again)", @fmt.friendly_error(err)
  end

  def test_friendly_error_rate_limit_json
    err = RuntimeError.new('{"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}')
    assert_equal "rate limited (try again)", @fmt.friendly_error(err)
  end

  def test_friendly_error_http_status_with_message
    err = RuntimeError.new('status: 500 {"type":"error","error":{"type":"server_error","message":"Internal server error"}}')
    assert_equal "HTTP 500: Internal server error", @fmt.friendly_error(err)
  end

  def test_friendly_error_truncates_long_messages
    long_msg = "x" * 100
    err = RuntimeError.new(long_msg)
    result = @fmt.friendly_error(err)
    assert_equal 80, result.length
    assert result.end_with?("...")
  end

  def test_friendly_error_short_message_unchanged
    err = RuntimeError.new("Short error")
    assert_equal "Short error", @fmt.friendly_error(err)
  end

  def test_friendly_error_exactly_80_chars_unchanged
    msg = "x" * 80
    err = RuntimeError.new(msg)
    assert_equal msg, @fmt.friendly_error(err)
  end
end
