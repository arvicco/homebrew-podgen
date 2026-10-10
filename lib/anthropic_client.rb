# frozen_string_literal: true

require "anthropic"

class StructuredOutputError < StandardError; end

# Raised when the response stopped at max_tokens and the structured output is
# unusable. Deliberately NOT a StructuredOutputError: re-issuing the identical
# request cannot succeed, so retry loops must let it propagate (M1-11).
class TruncatedOutputError < StandardError; end

# Shared Anthropic API client initialization.
# Include in classes that call Claude API and call init_anthropic_client
# in initialize to set @client and @model.
module AnthropicClient
  private

  def init_anthropic_client(env_key: "CLAUDE_MODEL", default_model: "claude-opus-4-7")
    @client = Anthropic::Client.new
    @model = ENV.fetch(env_key, default_model)
  end

  # Extract and validate structured output from an API response.
  # Raises StructuredOutputError when the SDK silently stored an error hash
  # instead of the expected model instance (e.g. JSON parse failure).
  def require_parsed_output!(message, _expected_class = nil)
    parsed = message.parsed_output
    if parsed.nil?
      raise_truncated!(message)
      raise StructuredOutputError,
        "No parsed output (stop_reason: #{message.stop_reason})"
    end
    if parsed.is_a?(Hash) && parsed.key?(:error)
      raise_truncated!(message)
      raise StructuredOutputError,
        "SDK parsing failed: #{parsed[:error]}"
    end
    parsed
  end

  def raise_truncated!(message)
    return unless message.stop_reason.to_s == "max_tokens"

    tokens = message.usage&.output_tokens if message.respond_to?(:usage)
    raise TruncatedOutputError,
      "Output truncated at max_tokens (#{tokens || "?"} output tokens) — " \
      "structured response is incomplete; raise max_tokens for this call"
  end
end
