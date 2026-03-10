# frozen_string_literal: true

require_relative "retryable"

# Mixin for HTTP API clients that need retry logic with exponential backoff.
# Provides RetriableError, RETRIABLE_CODES, parse_error, and with_http_retries.
# Includes Retryable, so with_retries is also available.
#
# Usage:
#   class MyApiClient
#     include HttpRetryable
#   end
module HttpRetryable
  RETRIABLE_CODES = [429, 503].freeze

  class RetriableError < StandardError; end

  HTTP_EXCEPTIONS = [RetriableError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET].freeze

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
    with_retries(max: max, on: HTTP_EXCEPTIONS, label: label) { yield }
  end

  def self.included(base)
    base.include(Retryable) unless base.ancestors.include?(Retryable)
    base.const_set(:RetriableError, RetriableError) unless base.const_defined?(:RetriableError)
  end
end
