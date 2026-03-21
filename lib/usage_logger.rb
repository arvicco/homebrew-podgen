# frozen_string_literal: true

# Shared Anthropic API usage logging.
# Include in classes that also include Loggable and call log_api_usage
# after each API call to log token counts and cache statistics.
module UsageLogger
  private

  def log_api_usage(label, message, elapsed)
    usage = message.usage
    log("#{label} in #{elapsed}s (#{message.stop_reason})")
    log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
    cache_create = usage.cache_creation_input_tokens || 0
    cache_read = usage.cache_read_input_tokens || 0
    log("  Cache create: #{cache_create} | Cache read: #{cache_read}") if cache_create > 0 || cache_read > 0
  end
end
