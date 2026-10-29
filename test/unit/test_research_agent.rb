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

  def test_research_exa_error_records_run_warning
    agent = build_agent
    agent.instance_variable_set(:@client, MockExaClientWithError.new)
    logger = with_run_logger { agent.research(["topic"]) }

    assert_equal 1, logger.logged_warnings.size
    assert_match(/Warning: Failed to research 'topic'/, logger.logged_warnings.first)
  end

  # --- Q-99 (P11-3): exa-ai raises its own classes only from HTTP responses;
  # a timeout or a failed connection arrives as Faraday's. ---

  def test_research_timeout_on_one_topic_skips_it_with_one_warning_others_proceed
    agent = build_agent
    agent.define_singleton_method(:sleep) { |_| }
    agent.instance_variable_set(:@client, FlakyExaClient.new("B" => -> { raise Faraday::TimeoutError, "read timeout" }))

    results = nil
    logger = with_run_logger { results = agent.research(%w[A B C]) }

    assert_equal %w[A B C], results.map { |r| r[:topic] }
    refute_empty results[0][:findings]
    assert_empty results[1][:findings]
    refute_empty results[2][:findings]
    assert_equal 1, logger.logged_warnings.size
    assert_match(/Failed to research 'B'.*Faraday::TimeoutError/, logger.logged_warnings.first)
  end

  def test_research_connection_failed_is_retried_then_succeeds
    agent = build_agent
    agent.define_singleton_method(:sleep) { |_| }
    failures = 2
    client = FlakyExaClient.new("A" => -> { raise Faraday::ConnectionFailed, "getaddrinfo" if (failures -= 1) >= 0 })
    agent.instance_variable_set(:@client, client)

    results = agent.research(["A"])

    refute_empty results.first[:findings]
    assert_equal 3, client.calls["A"]
  end

  def test_research_rate_limit_exhausted_skips_topic_with_warning
    agent = build_agent
    agent.define_singleton_method(:sleep) { |_| }
    client = FlakyExaClient.new("A" => -> { raise Exa::TooManyRequests, "429" })
    agent.instance_variable_set(:@client, client)

    results = nil
    logger = with_run_logger { results = agent.research(["A"]) }

    assert_empty results.first[:findings]
    assert_equal ResearchAgent::MAX_RETRIES + 1, client.calls["A"]
    assert_equal 1, logger.logged_warnings.size
  end

  def test_research_multiple_topics
    agent = build_agent
    stub_search(agent, [{ "title" => "Result", "url" => "https://example.com", "summary" => "..." }])

    results = agent.research(["AI", "Ruby"])
    assert_equal 2, results.length
    assert_equal "AI", results[0][:topic]
    assert_equal "Ruby", results[1][:topic]
  end

  def test_research_empty_topics_returns_empty
    agent = build_agent
    results = agent.research([])
    assert_empty results
  end

  def test_initialization_sets_results_per_topic
    agent = ResearchAgent.new(results_per_topic: 10)
    assert_equal 10, agent.instance_variable_get(:@results_per_topic)
  end

  def test_initialization_raises_without_api_key
    original = ENV["EXA_API_KEY"]
    ENV.delete("EXA_API_KEY")
    assert_raises(RuntimeError) { ResearchAgent.new }
  ensure
    ENV["EXA_API_KEY"] = original
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

  def with_run_logger
    Dir.mktmpdir do |dir|
      PodcastAgent::Logger.new(log_path: File.join(dir, "r.log"), verbosity: :quiet).tap do |l|
        PodcastAgent.with_logger(l) { yield }
      end
    end
  end

  # exa-ai raises a subclass of Exa::Error from an HTTP error response (here a
  # 401); never the bare base class.
  class MockExaClientWithError
    def search(_query, **_params)
      raise Exa::Unauthorized, "API error"
    end
  end

  # Per-query behaviour: a callable runs before each search of that query
  # (it may raise); every query returns one result. Counts calls per query.
  class FlakyExaClient
    attr_reader :calls

    def initialize(behaviour)
      @behaviour = behaviour
      @calls = Hash.new(0)
    end

    def search(query, **_params)
      @calls[query] += 1
      @behaviour[query]&.call
      MockSearchResult.new([{ "title" => "T #{query}", "url" => "https://example.com/#{query}", "summary" => "s" }])
    end
  end

  class MockSearchResult
    def initialize(results) = @results = results
    def results = @results
  end
end
