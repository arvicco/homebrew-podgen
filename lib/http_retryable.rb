# frozen_string_literal: true

# Mixin for HTTP API clients that need retry logic with exponential backoff.
# Provides RetriableError, RETRIABLE_CODES, and parse_error.
#
# Usage:
#   class MyApiClient
#     include HttpRetryable
#   end
module HttpRetryable
  RETRIABLE_CODES = [429, 503].freeze

  class RetriableError < StandardError; end

  # Parses an HTTP error response body, extracting a human-readable message.
  # Handles ElevenLabs (detail), Google (error), and LingQ (detail/message) formats.
  def parse_error(response)
    parsed = JSON.parse(response.body)
    if parsed.is_a?(Hash)
      detail = parsed["detail"]
      if detail.is_a?(Hash)
        "#{detail['code']}: #{detail['message']}"
      elsif detail
        detail.to_s
      elsif parsed["error"].is_a?(Hash)
        "#{parsed['error']['code']}: #{parsed['error']['message']}"
      elsif parsed["message"]
        parsed["message"].to_s
      else
        parsed.to_s
      end
    else
      parsed.to_s
    end
  rescue JSON::ParserError
    response.body[0..200]
  end

  def with_http_retries(label, max: 2)
    retries = 0
    begin
      retries += 1
      yield
    rescue RetriableError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
      if retries <= max
        sleep_time = 2**retries
        msg = "Retry #{retries}/#{max} in #{sleep_time}s: #{e.message}"
        $stderr.puts defined?(Tell::Colors) ? Tell::Colors.status(msg) : msg
        sleep(sleep_time)
        retry
      else
        raise "#{label} failed after #{max} retries: #{e.message}"
      end
    end
  end

  def self.included(base)
    base.const_set(:RetriableError, RetriableError) unless base.const_defined?(:RetriableError)
  end
end
