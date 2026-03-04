# frozen_string_literal: true

# Mixin that provides `with_retries` for exponential-backoff retry loops.
#
# Usage:
#   class MyAgent
#     include Retryable
#
#     def call_api
#       with_retries(max: 3, on: [Net::OpenTimeout, RetriableError]) do
#         # ... API call ...
#       end
#     end
#   end
module Retryable
  private

  # Yields the block, retrying on specified exceptions with exponential backoff.
  #
  # @param max [Integer] Maximum number of retries (default: 3)
  # @param on [Array<Class>] Exception classes to retry on
  # @param label [String] Name for error messages (e.g. "TTSAgent")
  def with_retries(max: 3, on: [StandardError], label: self.class.name&.split("::")&.last)
    retries = 0
    begin
      retries += 1
      yield
    rescue *on => e
      if retries <= max
        sleep_time = 2**retries
        log("#{label} error (attempt #{retries}/#{max}): #{e.message}. Retrying in #{sleep_time}s...") if respond_to?(:log, true)
        sleep(sleep_time)
        retry
      end
      raise "#{label} failed after #{retries} attempts: #{e.message}"
    end
  end
end
