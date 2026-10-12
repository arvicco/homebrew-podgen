# frozen_string_literal: true

require_relative "../test_helper"
require "claude_models"

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
    assert_equal ClaudeModels.for(:topic), client.last_call[:model]
  end

  # P3-1: per-topic HN keyword queries ride alongside the string array.
  def test_generate_keeps_string_array_when_hn_queries_present
    agent = build_agent("Guidelines")
    stub_client(agent, [["AI agents in hospitals October 2026", "AI agents healthcare"], "Ruby updates"])

    assert_equal ["AI agents in hospitals October 2026", "Ruby updates"], agent.generate
  end

  def test_hn_queries_maps_topic_to_keywords_and_tolerates_missing
    agent = build_agent("Guidelines")
    stub_client(agent, [["Bitcoin startup funding rounds October 2026", "Bitcoin startup funding"], ["Ruby updates", "   "], "Rust news"])

    agent.generate

    expected = {
      "Bitcoin startup funding rounds October 2026" => "Bitcoin startup funding",
      "Ruby updates" => nil,
      "Rust news" => nil
    }
    assert_equal expected, agent.hn_queries
  end

  def test_hn_queries_capped_at_four_words
    agent = build_agent("Guidelines")
    stub_client(agent, [["topic", "OpenAI GPT xAI Grok Meta Llama"]])

    agent.generate

    assert_equal({ "topic" => "OpenAI GPT xAI Grok" }, agent.hn_queries)
  end

  def test_hn_queries_empty_before_generate
    assert_equal({}, build_agent("Guidelines").hn_queries)
  end

  def test_system_prompt_asks_for_hn_query_keywords
    agent = build_agent("Guidelines")
    client = stub_client(agent, ["q1"])

    agent.generate
    instructions = client.last_call[:system].first[:text]
    assert_match(/hn_query/, instructions)
    assert_match(/2.4 defining keywords/, instructions)
    assert_match(/proper nouns first/, instructions)
  end

  def test_schema_declares_optional_hn_query
    fields = TopicQuery.fields
    assert fields.dig(:query, :required)
    assert fields.key?(:hn_query)
    refute fields.dig(:hn_query, :required)
    assert TopicQuery.new(query: "x").hn_query.nil?
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

  MockTopicQuery = Struct.new(:query, :hn_query)

  class MockTopicList
    attr_reader :queries
    # Each item is a query string, or [query, hn_query].
    def initialize(items)
      @queries = items.map { |q| MockTopicQuery.new(*Array(q)) }
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
