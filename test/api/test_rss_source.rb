# frozen_string_literal: true

require_relative "../test_helper"
require "sources/rss_source"

class TestRSSSource < Minitest::Test
  FEEDS = [
    "https://www.coindesk.com/arc/outboundfeeds/rss/",
    "https://cointelegraph.com/rss",
    "https://cryptoslate.com/feed/"
  ].freeze

  def setup
    @source = RSSSource.new(feeds: FEEDS)
  end

  def test_research_returns_results
    results = @source.research([])

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

  def test_research_returns_findings
    results = @source.research([])
    total = results.sum { |r| r[:findings].length }
    assert total > 0, "Expected at least 1 finding from RSS feeds"
  end
end
