# frozen_string_literal: true

require_relative "../test_helper"
require "agents/research_agent"

class TestResearch < Minitest::Test
  def setup
    skip_unless_env("EXA_API_KEY")
    @agent = ResearchAgent.new(results_per_topic: 2)
    @topics = ["AI developer tools", "Ruby on Rails"]
  end

  def test_research_returns_results
    results = @agent.research(@topics)

    assert_kind_of Array, results
    refute_empty results
    results.each do |entry|
      assert entry[:topic], "entry must have :topic"
      assert_kind_of Array, entry[:findings]
      entry[:findings].each do |f|
        assert f[:title], "finding must have :title"
        assert f[:url], "finding must have :url"
        assert f[:summary], "finding must have :summary"
      end
    end
  end

  def test_research_covers_all_topics
    results = @agent.research(@topics)
    result_topics = results.map { |r| r[:topic] }
    @topics.each do |topic|
      assert_includes result_topics, topic
    end
  end
end
