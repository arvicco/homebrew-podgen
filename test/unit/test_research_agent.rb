# frozen_string_literal: true

require_relative "../test_helper"
require "set"

ENV["EXA_API_KEY"] ||= "test-key"
require "agents/research_agent"

class TestResearchAgent < Minitest::Test
  def test_research_returns_findings
    agent = build_agent
    stub_search(agent, [
      { "title" => "GPT-5", "url" => "https://example.com/1", "summary" => "AI news" },
      { "title" => "Rails 8", "url" => "https://example.com/2", "summary" => "Ruby news" }
    ])

    results = agent.research(["AI news"])
    assert_equal 1, results.length
    assert_equal "AI news", results.first[:topic]
    assert_equal 2, results.first[:findings].length
    assert_equal "GPT-5", results.first[:findings].first[:title]
  end

  def test_research_deduplicates_excluded_urls
    excluded = Set.new(["https://example.com/1"])
    agent = build_agent(exclude_urls: excluded)
    stub_search(agent, [
      { "title" => "Old", "url" => "https://example.com/1", "summary" => "..." },
      { "title" => "New", "url" => "https://example.com/2", "summary" => "..." }
    ])

    results = agent.research(["topic"])
    assert_equal 1, results.first[:findings].length
    assert_equal "New", results.first[:findings].first[:title]
  end

  def test_research_returns_empty_on_exa_error
    agent = build_agent
    agent.instance_variable_set(:@client, MockExaClientWithError.new)

    results = agent.research(["topic"])
    assert_equal 1, results.length
    assert_empty results.first[:findings]
  end

  def test_research_multiple_topics
    agent = build_agent
    stub_search(agent, [{ "title" => "Result", "url" => "https://example.com", "summary" => "..." }])

    results = agent.research(["AI", "Ruby"])
    assert_equal 2, results.length
    assert_equal "AI", results[0][:topic]
    assert_equal "Ruby", results[1][:topic]
  end

  private

  def build_agent(exclude_urls: Set.new)
    ResearchAgent.new(results_per_topic: 5, exclude_urls: exclude_urls)
  end

  def stub_search(agent, results)
    client = MockExaClient.new(results)
    agent.instance_variable_set(:@client, client)
  end

  class MockExaClient
    def initialize(results) = @results = results
    def search(_query, **_params) = MockSearchResult.new(@results)
  end

  class MockExaClientWithError
    def search(_query, **_params)
      raise Exa::Error, "API error"
    end
  end

  class MockSearchResult
    def initialize(results) = @results = results
    def results = @results
  end
end
