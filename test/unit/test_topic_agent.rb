# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/topic_agent"

class TestTopicAgent < Minitest::Test
  def test_generate_returns_query_strings
    agent = build_agent("Tech podcast guidelines")
    stub_client(agent, ["AI news", "Ruby updates"])

    assert_equal ["AI news", "Ruby updates"], agent.generate
  end

  def test_prompt_includes_date
    agent = build_agent("Guidelines")
    client = stub_client(agent, ["q1"])

    agent.generate
    user_msg = client.last_call[:messages].first[:content]
    assert_match(/\d{4}-\d{2}-\d{2}/, user_msg)
  end

  def test_prompt_includes_day_of_week
    agent = build_agent("Guidelines")
    client = stub_client(agent, ["q1"])

    agent.generate
    user_msg = client.last_call[:messages].first[:content]
    today_day = Date.today.strftime("%A")
    assert_includes user_msg, today_day
  end

  def test_prompt_includes_recent_topics
    agent = build_agent("Guidelines", recent_topics: "AI, blockchain")
    client = stub_client(agent, ["q1"])

    agent.generate
    user_msg = client.last_call[:messages].first[:content]
    assert_includes user_msg, "AI, blockchain"
    assert_includes user_msg, "already covered"
  end

  def test_prompt_omits_recent_topics_when_nil
    agent = build_agent("Guidelines")
    client = stub_client(agent, ["q1"])

    agent.generate
    user_msg = client.last_call[:messages].first[:content]
    refute_includes user_msg, "already covered"
  end

  def test_prompt_omits_recent_topics_when_empty
    agent = build_agent("Guidelines", recent_topics: "")
    client = stub_client(agent, ["q1"])

    agent.generate
    user_msg = client.last_call[:messages].first[:content]
    refute_includes user_msg, "already covered"
  end

  def test_system_prompt_includes_guidelines_with_cache_control
    agent = build_agent("My podcast about tech")
    client = stub_client(agent, ["q1"])

    agent.generate
    system = client.last_call[:system]
    cached_block = system.find { |s| s[:cache_control] }
    assert_equal "My podcast about tech", cached_block[:text]
    assert_equal({ type: "ephemeral" }, cached_block[:cache_control])
  end

  def test_raises_on_nil_parsed_output
    agent = build_agent("Guidelines")
    stub_client(agent, nil)

    err = assert_raises(RuntimeError) { agent.generate }
    assert_includes err.message, "No parsed output"
  end

  def test_uses_model_from_env
    agent = build_agent("Guidelines")
    client = stub_client(agent, ["q1"])

    agent.generate
    assert_equal ENV.fetch("CLAUDE_MODEL", "claude-opus-4-7"), client.last_call[:model]
  end

  private

  def build_agent(guidelines, recent_topics: nil)
    agent = TopicAgent.new(guidelines: guidelines, recent_topics: recent_topics)
    agent.define_singleton_method(:sleep) { |_| }
    agent
  end

  def stub_client(agent, query_strings)
    output = query_strings ? MockTopicList.new(query_strings) : nil
    client = MockClient.new(output)
    agent.instance_variable_set(:@client, client)
    client
  end

  MockTopicQuery = Struct.new(:query)

  class MockTopicList
    attr_reader :queries
    def initialize(strings)
      @queries = strings.map { |q| MockTopicQuery.new(q) }
    end
  end

  class MockClient
    attr_reader :calls
    def initialize(output) = (@output = output; @calls = [])
    def messages = self
    def last_call = @calls.last
    def create(**kw) = (@calls << kw; MockMsg.new(@output))
  end

  class MockMsg
    def initialize(output) = @output = output
    def parsed_output = @output
    def stop_reason = "end_turn"
    def usage = MockUsage.new
  end

  class MockUsage
    def input_tokens = 100
    def output_tokens = 50
    def cache_creation_input_tokens = 0
    def cache_read_input_tokens = 0
  end
end
