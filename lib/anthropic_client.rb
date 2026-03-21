# frozen_string_literal: true

require "anthropic"

# Shared Anthropic API client initialization.
# Include in classes that call Claude API and call init_anthropic_client
# in initialize to set @client and @model.
module AnthropicClient
  private

  def init_anthropic_client(env_key: "CLAUDE_MODEL", default_model: "claude-opus-4-6")
    @client = Anthropic::Client.new
    @model = ENV.fetch(env_key, default_model)
  end
end
