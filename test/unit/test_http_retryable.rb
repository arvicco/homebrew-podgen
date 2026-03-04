# frozen_string_literal: true

require_relative "../test_helper"
require "http_retryable"
require "json"

class TestHttpRetryable < Minitest::Test
  def setup
    @host = Class.new { include HttpRetryable }.new
  end

  # --- parse_error ---

  def test_parse_error_elevenlabs_detail_hash
    response = mock_response({ "detail" => { "code" => "rate_limit", "message" => "Too many requests" } })
    assert_equal "rate_limit: Too many requests", @host.parse_error(response)
  end

  def test_parse_error_elevenlabs_detail_string
    response = mock_response({ "detail" => "Something went wrong" })
    assert_equal "Something went wrong", @host.parse_error(response)
  end

  def test_parse_error_google_error_hash
    response = mock_response({ "error" => { "code" => 403, "message" => "Forbidden" } })
    assert_equal "403: Forbidden", @host.parse_error(response)
  end

  def test_parse_error_lingq_message
    response = mock_response({ "message" => "Invalid token" })
    assert_equal "Invalid token", @host.parse_error(response)
  end

  def test_parse_error_fallback_to_string
    response = mock_response({ "unknown" => "data" })
    assert_includes @host.parse_error(response), "unknown"
  end

  def test_parse_error_invalid_json
    response = Struct.new(:body).new("not json{{{")
    assert_equal "not json{{{", @host.parse_error(response)
  end

  # --- Constants ---

  def test_retriable_codes
    assert_includes HttpRetryable::RETRIABLE_CODES, 429
    assert_includes HttpRetryable::RETRIABLE_CODES, 503
  end

  def test_retriable_error_class
    assert HttpRetryable::RetriableError < StandardError
  end

  def test_included_sets_retriable_error_on_host
    klass = Class.new { include HttpRetryable }
    assert_equal HttpRetryable::RetriableError, klass::RetriableError
  end

  private

  def mock_response(body_hash)
    Struct.new(:body).new(body_hash.to_json)
  end
end
