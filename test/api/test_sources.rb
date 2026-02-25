# frozen_string_literal: true

require_relative "../test_helper"
require "source_manager"

class TestSources < Minitest::Test
  def setup
    @source_config = {
      "hackernews" => true,
      "rss" => [
        "https://www.coindesk.com/arc/outboundfeeds/rss/",
        "https://cointelegraph.com/rss"
      ]
    }
    @topics = ["Bitcoin ETF", "AI agents"]
    @manager = SourceManager.new(source_config: @source_config)
  end

  def test_merged_results_structure
    results = @manager.research(@topics)

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

  def test_covers_all_topics
    results = @manager.research(@topics)
    result_topics = results.map { |r| r[:topic] }
    @topics.each do |topic|
      assert_includes result_topics, topic
    end
  end

  def test_has_findings
    results = @manager.research(@topics)
    total = results.sum { |r| r[:findings].length }
    assert total > 0, "Expected at least 1 finding across all sources"
  end
end
