# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/description_agent"

class TestDescriptionAgent < Minitest::Test
  # --- clean_title ---

  def test_clean_title_returns_cleaned
    agent = build_agent("Lačni medved")
    result = agent.clean_title(title: "PRAVLJICA ZA OTROKE: Lačni medved")
    assert_equal "Lačni medved", result
  end

  def test_clean_title_empty_returns_original
    agent = build_agent("anything")
    assert_equal "", agent.clean_title(title: "")
    assert_equal nil, agent.clean_title(title: nil)
  end

  def test_clean_title_on_api_error_returns_original
    agent = build_agent_with_error
    result = agent.clean_title(title: "Some Title")
    assert_equal "Some Title", result
  end

  def test_clean_title_empty_result_returns_original
    agent = build_agent("")
    result = agent.clean_title(title: "Original Title")
    assert_equal "Original Title", result
  end

  # --- clean ---

  def test_clean_returns_cleaned_description
    agent = build_agent("A bear goes on an adventure.")
    result = agent.clean(title: "Lačni medved", description: "A bear goes on an adventure. Subscribe! #kids")
    assert_equal "A bear goes on an adventure.", result
  end

  def test_clean_empty_description_returns_original
    agent = build_agent("anything")
    assert_equal "", agent.clean(title: "T", description: "")
    assert_equal nil, agent.clean(title: "T", description: nil)
  end

  def test_clean_on_api_error_returns_original
    agent = build_agent_with_error
    result = agent.clean(title: "T", description: "Original desc")
    assert_equal "Original desc", result
  end

  def test_clean_empty_result_returns_original
    agent = build_agent("")
    result = agent.clean(title: "T", description: "Original desc")
    assert_equal "Original desc", result
  end

  # --- generate_title ---

  def test_generate_title_returns_generated_title
    agent = build_agent("Szczepan i smok")
    result = agent.generate_title(transcript: "Dawno temu żył sobie chłopiec imieniem Szczepan...", language: "Polish")
    assert_equal "Szczepan i smok", result
  end

  def test_generate_title_empty_transcript_returns_nil
    agent = build_agent("anything")
    assert_nil agent.generate_title(transcript: "", language: "Polish")
    assert_nil agent.generate_title(transcript: nil, language: "Polish")
  end

  def test_generate_title_on_api_error_returns_nil
    agent = build_agent_with_error
    assert_nil agent.generate_title(transcript: "Some text", language: "Polish")
  end

  def test_generate_title_empty_result_returns_nil
    agent = build_agent("")
    assert_nil agent.generate_title(transcript: "Some text", language: "Polish")
  end

  # --- generate ---

  def test_generate_returns_description
    agent = build_agent("A story about a hungry bear.")
    result = agent.generate(title: "Lačni medved", transcript: "Nekoč je živel medved...")
    assert_equal "A story about a hungry bear.", result
  end

  def test_generate_empty_transcript_returns_empty
    agent = build_agent("anything")
    assert_equal "", agent.generate(title: "T", transcript: "")
    assert_equal "", agent.generate(title: "T", transcript: nil)
  end

  def test_generate_on_api_error_returns_empty
    agent = build_agent_with_error
    result = agent.generate(title: "T", transcript: "Some transcript")
    assert_equal "", result
  end

  def test_generate_truncates_long_transcript
    agent = build_agent("Short description")
    client = agent.instance_variable_get(:@client)

    long_transcript = "x" * 5000
    agent.generate(title: "T", transcript: long_transcript)

    user_msg = client.last_call[:messages].first[:content]
    # TRANSCRIPT_LIMIT is 2000
    assert user_msg.length < 5000
  end

  # --- model selection ---

  def test_default_model_is_haiku
    ENV.delete("CLAUDE_DESCRIPTION_MODEL")
    ENV.delete("CLAUDE_WEB_MODEL")
    agent = DescriptionAgent.new
    assert_equal "claude-haiku-4-5-20251001", agent.instance_variable_get(:@model)
  end

  def test_claude_description_model_env_overrides_default
    ENV["CLAUDE_DESCRIPTION_MODEL"] = "claude-sonnet-4-6"
    agent = DescriptionAgent.new
    assert_equal "claude-sonnet-4-6", agent.instance_variable_get(:@model)
  ensure
    ENV.delete("CLAUDE_DESCRIPTION_MODEL")
  end

  def test_claude_web_model_does_not_affect_description_agent
    ENV.delete("CLAUDE_DESCRIPTION_MODEL")
    ENV["CLAUDE_WEB_MODEL"] = "claude-sonnet-4-6"
    agent = DescriptionAgent.new
    assert_equal "claude-haiku-4-5-20251001", agent.instance_variable_get(:@model)
  ensure
    ENV.delete("CLAUDE_WEB_MODEL")
  end

  private

  def build_agent(response_text)
    agent = DescriptionAgent.new
    client = MockTextClient.new(response_text)
    agent.instance_variable_set(:@client, client)
    agent
  end

  def build_agent_with_error
    agent = DescriptionAgent.new
    client = MockTextClient.new(nil, error: RuntimeError.new("API down"))
    agent.instance_variable_set(:@client, client)
    agent
  end

  class MockTextClient
    attr_reader :calls

    def initialize(text, error: nil)
      @text = text
      @error = error
      @calls = []
    end

    def messages = self
    def last_call = @calls.last

    def create(**kw)
      @calls << kw
      raise @error if @error
      MockTextMsg.new(@text)
    end
  end

  class MockTextMsg
    def initialize(text) = @text = text
    def stop_reason = "end_turn"
    def usage = MockUsage.new
    def content = [MockBlock.new(@text)]
  end

  MockBlock = Struct.new(:text)

  class MockUsage
    def input_tokens = 100
    def output_tokens = 30
    def cache_creation_input_tokens = 0
    def cache_read_input_tokens = 0
  end
end
