# frozen_string_literal: true

require_relative "../test_helper"
require "sources/claude_web_source"

class TestClaudeWeb < Minitest::Test
  def setup
    skip_unless_env("ANTHROPIC_API_KEY")
    @source = ClaudeWebSource.new
    @topics = ["Bitcoin ETF latest news"]
  end

  def test_research_returns_results
    results = @source.research(@topics)

    assert_kind_of Array, results
    refute_empty results
    results.each do |entry|
      assert entry[:topic], "entry must have :topic"
      assert_kind_of Array, entry[:findings]
      entry[:findings].each do |f|
        assert f[:title], "finding must have :title"
        assert f[:url], "finding must have :url"
      end
    end
  end

  def test_research_covers_topics
    results = @source.research(@topics)
    result_topics = results.map { |r| r[:topic] }
    @topics.each do |topic|
      assert_includes result_topics, topic
    end
  end
end
