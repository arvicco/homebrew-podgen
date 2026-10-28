# frozen_string_literal: true

require "anthropic"
require_relative "claude_models"

class StructuredOutputError < StandardError; end

# Raised when the response stopped at max_tokens and the structured output is
# unusable. Deliberately NOT a StructuredOutputError: re-issuing the identical
# request cannot succeed, so retry loops must let it propagate (P1-11).
class TruncatedOutputError < StandardError; end

# Raised by AnthropicClient.text_of when a response carries no text block.
class NoTextBlockError < StandardError; end

# Shared Anthropic API client initialization.
# Include in classes that call Claude API and call init_anthropic_client
# in initialize to set @client and @model.
module AnthropicClient
  # First text block of a response. Thinking-default models put a thinking
  # block first, so `content.first.text` is unsafe (P1-0, hazard H1).
  # Fakes without a `type` but with `text` are accepted.
  def self.text_of(message)
    blocks = Array(message.content)
    block = blocks.find { |b| b.respond_to?(:type) && b.type.to_s == "text" } ||
      blocks.find { |b| !b.respond_to?(:type) && b.respond_to?(:text) }
    unless block
      reason = message.respond_to?(:stop_reason) ? message.stop_reason : "?"
      raise NoTextBlockError, "no text block in response (stop_reason: #{reason})"
    end
    block.text
  end

  # Request params carrying the role's effort level (P5-1): empty when the
  # registry resolves nil, so the API default applies. Structured-output
  # callers pass their other output_config keys (format:) to merge beside
  # effort (P6-0); the hash is fresh per call because the SDK rewrites
  # output_config[:format] in place.
  def self.effort_params(role, **output_config)
    effort = ClaudeModels.effort(role)
    output_config[:effort] = effort.to_sym if effort
    output_config.empty? ? {} : {output_config: output_config}
  end

  private

  # REQUEST_TIMEOUT is the intended bound for one HTTP request (the SDK
  # default is 10 min, and with its internal retries a dead network cost
  # hours — P1-13). Caveat found 2026-10-16 (Q-87): anthropic 1.21.0's
  # messages.create merges its own 600 s default unless the call passes
  # request_options, so today only calls that pass them (the reviewer's
  # retry) are actually bound by this value. Longest observed calls: script
  # ~90 s, enrichment ~80 s, reconciliation ~55 s.
  REQUEST_TIMEOUT = 300

  def init_anthropic_client(role:)
    @client = Anthropic::Client.new(timeout: REQUEST_TIMEOUT)
    @model = ClaudeModels.for(role)
    @effort_params = AnthropicClient.effort_params(role)
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
