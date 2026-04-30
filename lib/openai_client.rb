# frozen_string_literal: true

require "openai"

# Shared OpenAI API client initialization.
# Include in classes that call OpenAI API and call init_openai_client
# in initialize to set @openai_client and @openai_model.
module OpenAIClient
  private

  def init_openai_client(env_key: "OPENAI_TRANSLATION_MODEL", default_model: "gpt-5", model_override: nil)
    api_key = ENV.fetch("OPENAI_API_KEY") { raise "OPENAI_API_KEY environment variable is not set" }
    @openai_client = OpenAI::Client.new(api_key: api_key)
    @openai_model = model_override || ENV.fetch(env_key, default_model)
  end
end
