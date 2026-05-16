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

  def test_fetch_episodes_transfers_overlay_options_to_episode
    feed_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>x</title><link>x</link><description>x</description>
        <item>
          <title>Ep</title>
          <link>https://example.com/ep</link>
          <description>d</description>
          <enclosure url="https://example.com/ep.mp3" type="audio/mpeg" length="1000"/>
        </item>
      </channel></rss>
    XML

    feeds = [{
      url: "https://example.com/feed.xml",
      font: "Arial",
      font_color: "white",
      font_size: 42,
      width: 500,
      gravity: "south",
      x_offset: 12,
      y_offset: 24,
      base_image: "/abs/bg.png"
    }]
    source = RSSSource.new(feeds: feeds, logger: @logger)
    source.define_singleton_method(:http_get_with_redirects) { |_url, _redirects = nil| feed_xml }

    episode = source.fetch_episodes.first
    assert_equal "Arial", episode[:font]
    assert_equal "white", episode[:font_color]
    assert_equal 42, episode[:font_size]
    assert_equal 500, episode[:width]
    assert_equal "south", episode[:gravity]
    assert_equal 12, episode[:x_offset]
    assert_equal 24, episode[:y_offset]
    assert_equal "/abs/bg.png", episode[:base_image]
  end

  private

  def build_source(feeds)
    source = RSSSource.new(feeds: feeds, logger: @logger)
    source.define_singleton_method(:http_get_with_redirects) { |_url, _redirects = nil| EMPTY_FEED }
    source
  end
end
