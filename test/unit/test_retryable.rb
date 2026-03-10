# frozen_string_literal: true

require_relative "../test_helper"
require "retryable"

class RetryableTestHost
  include Retryable

  attr_reader :log_messages

  def initialize
    @log_messages = []
  end

  def call_with_retries(**opts, &block)
    with_retries(**opts, &block)
  end

  # Stub sleep to avoid slow tests
  def sleep(_seconds); end

  private

  def log(message)
    @log_messages << message
  end
end

class TestRetryable < Minitest::Test
  def setup
    @host = RetryableTestHost.new
  end

  def test_succeeds_without_retry
    result = @host.call_with_retries(max: 3, on: [RuntimeError]) { 42 }
    assert_equal 42, result
    assert_empty @host.log_messages
  end

  def test_retries_on_matching_exception
    attempts = 0
    result = @host.call_with_retries(max: 3, on: [RuntimeError]) do
      attempts += 1
      raise RuntimeError, "fail" if attempts < 3
      "ok"
    end

    assert_equal "ok", result
    assert_equal 3, attempts
    assert_equal 2, @host.log_messages.length
  end

  def test_raises_after_max_retries
    attempts = 0
    err = assert_raises(RuntimeError) do
      @host.call_with_retries(max: 2, on: [RuntimeError], label: "Test") do
        attempts += 1
        raise RuntimeError, "always fails"
      end
    end

    assert_equal 3, attempts
    assert_includes err.message, "Test failed after 3 attempts"
  end

  def test_does_not_retry_unmatched_exception
    assert_raises(ArgumentError) do
      @host.call_with_retries(max: 3, on: [RuntimeError]) do
        raise ArgumentError, "wrong type"
      end
    end
  end

  def test_retries_on_multiple_exception_classes
    attempts = 0
    @host.call_with_retries(max: 3, on: [RuntimeError, ArgumentError]) do
      attempts += 1
      raise ArgumentError, "arg" if attempts == 1
      raise RuntimeError, "rt" if attempts == 2
      "done"
    end

    assert_equal 3, attempts
  end

  def test_label_defaults_to_class_name
    err = assert_raises(RuntimeError) do
      @host.call_with_retries(max: 0, on: [RuntimeError]) do
        raise RuntimeError, "boom"
      end
    end

    assert_includes err.message, "RetryableTestHost"
  end

  def test_works_without_log_method
    # Object without log method should still work (falls back to stderr)
    host = Object.new
    host.extend(Retryable)

    result = host.send(:with_retries, max: 1, on: [RuntimeError]) { "ok" }
    assert_equal "ok", result
  end

  def test_retry_log_falls_back_to_stderr
    host = Object.new
    host.extend(Retryable)
    host.define_singleton_method(:sleep) { |_| }

    stderr_output = StringIO.new
    original_stderr = $stderr
    $stderr = stderr_output

    begin
      host.send(:with_retries, max: 1, on: [RuntimeError]) do
        raise RuntimeError, "oops" if stderr_output.string.empty?
        "ok"
      end
    ensure
      $stderr = original_stderr
    end

    assert_includes stderr_output.string, "oops"
    assert_includes stderr_output.string, "Retrying"
  end
end
