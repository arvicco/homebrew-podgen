# frozen_string_literal: true

require "openai"
require_relative "anthropic_client"

# Shared OpenAI API client initialization.
# Include in classes that call OpenAI API and call init_openai_client
# in initialize to set @openai_client and @openai_model.
module OpenAIClient
  private

  def init_openai_client(env_key: "OPENAI_TRANSLATION_MODEL", default_model: "gpt-5", model_override: nil)
    api_key = ENV.fetch("OPENAI_API_KEY") { raise "OPENAI_API_KEY environment variable is not set" }
    # Same per-request bound as every Claude call (P10-1): the SDK default
    # is 600 s with 2 transport retries, inside the agent's own with_retries
    # (P18-4, Q-129).
    @openai_client = OpenAI::Client.new(api_key: api_key, timeout: AnthropicClient::REQUEST_TIMEOUT, max_retries: 1)
    @openai_model = model_override || ENV.fetch(env_key, default_model)
  end
end
