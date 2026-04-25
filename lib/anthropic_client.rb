# frozen_string_literal: true

require "anthropic"

class StructuredOutputError < StandardError; end

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
      raise StructuredOutputError,
        "No parsed output (stop_reason: #{message.stop_reason})"
    end
    if parsed.is_a?(Hash) && parsed.key?(:error)
      raise StructuredOutputError,
        "SDK parsing failed: #{parsed[:error]}"
    end
    parsed
  end
end
