# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "sources/rss_source"
require "loggable"

class CapturingLogger
  attr_reader :messages
  def initialize; @messages = []; end
  def log(msg); @messages << msg; end
  def output; @messages.join("\n"); end
end

class TestRSSSource < Minitest::Test
  EMPTY_FEED = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>x</title><link>x</link><description>x</description></channel></rss>
  XML

  def setup
    @logger = CapturingLogger.new
  end

  def test_fetch_episodes_logs_tag_when_present
    feeds = [{ url: "https://example.com/feed.xml", tag: "cortes" }]
    source = build_source(feeds)
    source.fetch_episodes

    assert_match(/Fetching RSS 'cortes' episodes: https:\/\/example\.com\/feed\.xml/, @logger.output)
  end

  def test_fetch_episodes_logs_url_only_when_no_tag
    source = build_source(["https://example.com/feed.xml"])
    source.fetch_episodes

    assert_match(/Fetching RSS episodes: https:\/\/example\.com\/feed\.xml/, @logger.output)
    refute_match(/Fetching RSS '/, @logger.output)
  end

  def test_research_logs_tag_when_present
    feeds = [{ url: "https://example.com/feed.xml", tag: "headlines" }]
    source = build_source(feeds)
    source.research(["Topic"])

    assert_match(/Fetching RSS 'headlines': https:\/\/example\.com\/feed\.xml/, @logger.output)
  end

  private

  def build_source(feeds)
    source = RSSSource.new(feeds: feeds, logger: @logger)
    source.define_singleton_method(:http_get_with_redirects) { |_url, _redirects = nil| EMPTY_FEED }
    source
  end
end
