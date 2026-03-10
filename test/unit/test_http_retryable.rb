# frozen_string_literal: true

require_relative "../test_helper"
require "http_retryable"
require "json"

class TestHttpRetryable < Minitest::Test
  def setup
    @host = Class.new {
      include HttpRetryable
      def sleep(_seconds); end
    }.new
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

  # --- with_http_retries delegates to with_retries ---

  def test_http_retries_succeeds_without_retry
    result = @host.send(:with_http_retries, "Test") { 42 }
    assert_equal 42, result
  end

  def test_http_retries_retries_on_retriable_error
    attempts = 0
    result = @host.send(:with_http_retries, "Test", max: 2) do
      attempts += 1
      raise HttpRetryable::RetriableError, "rate limited" if attempts < 2
      "ok"
    end

    assert_equal "ok", result
    assert_equal 2, attempts
  end

  def test_http_retries_raises_after_max
    err = assert_raises(RuntimeError) do
      @host.send(:with_http_retries, "MyAPI", max: 1) do
        raise HttpRetryable::RetriableError, "always fails"
      end
    end

    assert_includes err.message, "MyAPI failed after 2 attempts"
  end

  def test_http_retries_does_not_catch_unrelated_errors
    assert_raises(ArgumentError) do
      @host.send(:with_http_retries, "Test") do
        raise ArgumentError, "bad"
      end
    end
  end

  # --- Retryable is included automatically ---

  def test_includes_retryable
    klass = Class.new { include HttpRetryable }
    assert klass.ancestors.include?(Retryable)
  end

  def test_with_retries_available
    assert @host.respond_to?(:with_retries, true)
  end

  private

  def mock_response(body_hash)
    Struct.new(:body).new(body_hash.to_json)
  end
end
