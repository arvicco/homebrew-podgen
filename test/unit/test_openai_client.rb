# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../../lib/openai_client"

# P18-4 (Q-129): the OpenAI translation client carries the same per-request
# bound as every Claude call (P10-1) — the SDK default of 600 s × 3 attempts
# inside the agent's own with_retries could hold the scheduled run ~2 h.
class TestOpenAIClient < Minitest::Test
  def setup
    @saved_key = ENV["OPENAI_API_KEY"]
    ENV["OPENAI_API_KEY"] = "test-placeholder"
  end

  def teardown
    ENV["OPENAI_API_KEY"] = @saved_key
  end

  def test_init_openai_client_bounded_timeout_and_one_transport_retry
    captured = nil
    OpenAI::Client.stub(:new, ->(**kw) {
      captured = kw
      Object.new
    }) do
      h = Class.new {
        include OpenAIClient

        public :init_openai_client
      }.new
      h.init_openai_client
    end
    assert_equal 300, captured[:timeout]
    assert_equal 1, captured[:max_retries]
    assert_equal AnthropicClient::REQUEST_TIMEOUT, captured[:timeout], "one bound, from one place"
  end
end
